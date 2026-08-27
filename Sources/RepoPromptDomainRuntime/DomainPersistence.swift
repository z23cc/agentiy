import AgentryCoreBridge
import Darwin
import Foundation
import os

struct DomainPendingSave: Codable, Sendable, Equatable {
    let operationID: UUID
    let documentDigest: String
}

struct DomainWorkingJournal: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let fileURL: URL
    let revisions: DomainRevisionState
    let savedDigest: String
    let workingDocument: Data?
    let contextRevisions: [UUID: DomainRevisionState]
    let contextDigests: [UUID: String]
    let contextTombstones: [UUID: UInt64]
    let operations: [DomainRecordedOperation]
    let pendingSave: DomainPendingSave?
    let updatedAt: Date

    init(
        workspaceID: UUID,
        fileURL: URL,
        revisions: DomainRevisionState,
        savedDigest: String,
        workingDocument: Data?,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        pendingSave: DomainPendingSave? = nil,
        updatedAt: Date
    ) {
        version = Self.schemaVersion
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.revisions = revisions
        self.savedDigest = savedDigest
        self.workingDocument = workingDocument
        self.contextRevisions = contextRevisions
        self.contextDigests = contextDigests
        self.contextTombstones = contextTombstones
        self.operations = operations
        self.pendingSave = pendingSave
        self.updatedAt = updatedAt
    }
}

struct DomainSavedRevisionRecord: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let savedRevision: UInt64
    let documentDigest: String
    let operationID: UUID
    let updatedAt: Date
}

struct DomainDeletionTombstone: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let fileURL: URL
    let operation: DomainRecordedOperation
    let deletedAt: Date
}

struct DomainFileMetadata: Equatable {
    let exists: Bool
    let byteCount: UInt64
    let modificationNanoseconds: Int64
    let fileSystemNumber: UInt64
    let fileNumber: UInt64

    static let missing = DomainFileMetadata(
        exists: false,
        byteCount: 0,
        modificationNanoseconds: 0,
        fileSystemNumber: 0,
        fileNumber: 0
    )
}

enum DomainExternalDocumentProbe {
    case unchanged(DomainFileMetadata)
    case changed(DomainWorkspaceDocument, DomainFileMetadata)
    case missing(DomainFileMetadata)
    case invalid(DomainFileMetadata)
    case cancelled
}

struct DomainPersistenceBootstrap {
    struct Workspace {
        let document: DomainWorkspaceDocument
        let savedDigest: String
        let revisions: DomainRevisionState
        let contextRevisions: [UUID: DomainRevisionState]
        let contextTombstones: [UUID: UInt64]
        let operations: [DomainRecordedOperation]
        let health: DomainAuthorityHealth
        let fileMetadata: DomainFileMetadata
    }

    struct UnavailableWorkspace {
        let workspaceID: UUID
        let fileURL: URL
        let reason: String
        let fileMetadata: DomainFileMetadata
    }

    let workspaces: [Workspace]
    let unavailableWorkspaces: [UnavailableWorkspace]
    let deletedOperations: [DomainRecordedOperation]
    let deletedWorkspaceIDs: Set<UUID>
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
}

struct DomainPersistenceWorkspaceRefresh {
    let workspace: DomainPersistenceBootstrap.Workspace?
    let workspaceIsDeleted: Bool
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
}

struct DomainPersistenceWorkingCommit {
    let journal: DomainWorkingJournal
    let catalogRevision: UInt64
}

struct DomainPersistenceSavedCommit {
    let journal: DomainWorkingJournal
    let catalogRevision: UInt64
    let revisionSidecarMissing: Bool
}

struct DomainPersistenceDeleteCommit {
    let catalogRevision: UInt64
    let tombstone: DomainDeletionTombstone
    let artifactCleanupWarnings: [String]
}

enum DomainPersistenceError: Error, Equatable {
    case stateConflict(expected: UInt64, actual: UInt64)
    case externalDocumentConflict
    case futureJournal(Int)
    case corruptJournal
    case operationIDCollision
    case invalidWorkspaceDocument
    case writeFailed(String)
    case lockTimedOut
    case cancelled
    case mutationPermitInvalid
    case workspaceOutsideMutationScope
}

package struct DomainPersistenceDataSnapshot: Sendable {
    package let data: Data?
    package let digest: String?

    package init(data: Data?) {
        self.data = data
        digest = data.map(DomainContentDigest.sha256)
    }
}

private final class DomainBlockingCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    func cancel() {
        state.withLock { $0 = true }
    }

    func check() throws {
        if state.withLock({ $0 }) {
            throw DomainPersistenceError.cancelled
        }
    }
}

private enum DomainBlockingIO {
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable (DomainBlockingCancellation) throws -> T
    ) async throws -> T {
        let cancellation = DomainBlockingCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try cancellation.check()
                        try continuation.resume(returning: operation(cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

package struct DomainPersistenceCoordinator {
    package static let maximumWorkspaceProjectionCheckpointBytes = 128 * 1024 * 1024
    private static let maximumWorkspaceCatalogBytes = 128 * 1024 * 1024

    #if DEBUG
        private static let catalogReplacementTestHooks = OSAllocatedUnfairLock(
            initialState: [String: @Sendable () throws -> Void]()
        )
        private static let catalogDirectorySyncTestHooks = OSAllocatedUnfairLock(
            initialState: [String: @Sendable () throws -> Void]()
        )

        package static func setCatalogReplacementTestHook(
            for catalogURL: URL,
            _ hook: (@Sendable () throws -> Void)?
        ) {
            catalogReplacementTestHooks.withLock { hooks in
                hooks[catalogURL.standardizedFileURL.path] = hook
            }
        }

        private static func takeCatalogReplacementTestHook(
            for catalogURL: URL
        ) -> (@Sendable () throws -> Void)? {
            catalogReplacementTestHooks.withLock { hooks in
                hooks.removeValue(forKey: catalogURL.standardizedFileURL.path)
            }
        }

        package static func setCatalogDirectorySyncTestHook(
            for catalogURL: URL,
            _ hook: (@Sendable () throws -> Void)?
        ) {
            catalogDirectorySyncTestHooks.withLock { hooks in
                hooks[catalogURL.standardizedFileURL.path] = hook
            }
        }

        private static func takeCatalogDirectorySyncTestHook(
            for catalogURL: URL
        ) -> (@Sendable () throws -> Void)? {
            catalogDirectorySyncTestHooks.withLock { hooks in
                hooks.removeValue(forKey: catalogURL.standardizedFileURL.path)
            }
        }
    #endif

    struct RuntimeWorkspaceCatalog: Codable, Equatable, Sendable {
        static let schemaVersion = 1

        struct Entry: Codable, Equatable, Sendable {
            let workspaceID: UUID
            let fileURL: URL
        }

        let version: Int
        let revision: UInt64
        let entries: [Entry]
        let deletions: [DomainDeletionTombstone]?
        let updatedAt: Date

        init(
            version: Int,
            revision: UInt64,
            entries: [Entry],
            deletions: [DomainDeletionTombstone] = [],
            updatedAt: Date
        ) {
            self.version = version
            self.revision = revision
            self.entries = entries
            self.deletions = deletions
            self.updatedAt = updatedAt
        }
    }

    private enum RawJournalSnapshot: Sendable {
        case absent
        case present(digest: String, bytes: Data)

        var digest: String? {
            switch self {
            case .absent: nil
            case let .present(digest, _): digest
            }
        }
    }

    private enum RawCatalogSnapshot: Sendable {
        case absent
        case present(digest: String, bytes: Data)

        var digest: String? {
            switch self {
            case .absent: nil
            case let .present(digest, _): digest
            }
        }
    }

    private struct ValidatedCatalogSnapshot: Sendable {
        let raw: RawCatalogSnapshot
        let validation: DomainWorkspaceCatalogValidation
    }

    private struct CatalogWriteReceipt: Sendable {
        let raw: RawCatalogSnapshot
        let directorySyncWarning: String?
    }

    private enum OptionalMetadataSnapshot: Sendable {
        case absent
        case present(Data)
        case oversized
    }

    private struct ValidatedJournalSnapshot: Sendable {
        let raw: RawJournalSnapshot
        let effectiveJournal: DomainWorkingJournal
        let effectiveValidation: DomainWorkspaceWorkingJournalValidation
    }

    private struct PreparedJournalCandidate: Sendable {
        let journal: DomainWorkingJournal
        let canonicalBytes: Data
        let contentDigest: String
    }

    private struct LegacyWorkspaceIndexEntry: Codable {
        let id: UUID
        let name: String
        let customStoragePath: URL?
        let isSystemWorkspace: Bool
        let isHiddenInMenus: Bool
    }

    private struct RuntimePolicyDocument: Codable {
        static let schemaVersion = 1
        let version: Int
        let profileIdentifier: String
        let legacyDefaultsPreserved: Bool
        let rollbackDirectoryName: String
        let migratedAt: Date
    }

    private struct RollbackManifest: Codable {
        static let schemaVersion = 1
        struct Artifact: Codable {
            let relativePath: String
            let digest: String
        }

        let version: Int
        let profileIdentifier: String
        let runtimeID: UUID
        let runtimeGeneration: UInt64
        let createdAt: Date
        let artifacts: [Artifact]
        let legacyDefaultKeys: [String]
    }

    private let configuration: DomainRuntimeConfiguration
    private let identity: DomainRuntimeIdentity
    private let workspaceAuthorityScope: DomainWorkspaceAuthorityLeaseScope?
    private let workspaceMutationPermitRegistry: DomainWorkspaceMutationPermitRegistry?
    private let coreService: AgentryCoreService
    private let cancellation: DomainBlockingCancellation?

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        workspaceAuthorityScope: DomainWorkspaceAuthorityLeaseScope? = nil,
        workspaceMutationPermitRegistry: DomainWorkspaceMutationPermitRegistry? = nil,
        coreService: AgentryCoreService = .shared
    ) {
        self.configuration = configuration
        self.identity = identity
        self.workspaceAuthorityScope = workspaceAuthorityScope
        self.workspaceMutationPermitRegistry = workspaceMutationPermitRegistry
        self.coreService = coreService
        cancellation = nil
    }

    private init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        workspaceAuthorityScope: DomainWorkspaceAuthorityLeaseScope?,
        workspaceMutationPermitRegistry: DomainWorkspaceMutationPermitRegistry?,
        coreService: AgentryCoreService,
        cancellation: DomainBlockingCancellation
    ) {
        self.configuration = configuration
        self.identity = identity
        self.workspaceAuthorityScope = workspaceAuthorityScope
        self.workspaceMutationPermitRegistry = workspaceMutationPermitRegistry
        self.coreService = coreService
        self.cancellation = cancellation
    }

    private var fileManager: FileManager {
        .default
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    private func blockingWorker(_ cancellation: DomainBlockingCancellation) -> Self {
        Self(
            configuration: configuration,
            identity: identity,
            workspaceAuthorityScope: workspaceAuthorityScope,
            workspaceMutationPermitRegistry: workspaceMutationPermitRegistry,
            coreService: coreService,
            cancellation: cancellation
        )
    }

    private func prepareJournalValidator() async throws -> DomainWorkspaceRustJournal.PreparedValidator {
        try await DomainWorkspaceRustJournal.prepare(coreService: coreService)
    }

    private func validateMutationPermit(
        _ permit: DomainWorkspaceMutationPermit,
        document: DomainWorkspaceDocument
    ) async throws {
        try validateMutationScope(permit, document: document)
    }

    private func validateMutationScope(
        _ permit: DomainWorkspaceMutationPermit,
        document: DomainWorkspaceDocument
    ) throws {
        try validateMutationPermitScope(permit)
        guard let workspaceAuthorityScope,
              workspaceAuthorityScope.containsWorkspaceDocument(document.fileURL)
        else {
            throw DomainPersistenceError.workspaceOutsideMutationScope
        }
    }

    private func validateMutationPermitScope(
        _ permit: DomainWorkspaceMutationPermit
    ) throws {
        guard let workspaceAuthorityScope,
              let workspaceMutationPermitRegistry
        else {
            throw DomainPersistenceError.mutationPermitInvalid
        }
        do {
            try workspaceMutationPermitRegistry.validate(
                permit,
                expectedStorageScopeDigest: workspaceAuthorityScope.storageScopeDigest
            )
        } catch {
            throw DomainPersistenceError.mutationPermitInvalid
        }
    }

    private func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try DomainPersistenceLock.withLock(
            at: url,
            cancellation: cancellation,
            body
        )
    }

    private var workspaceRoot: URL {
        configuration.workspaceStorageDirectory
    }

    private var runtimeRoot: URL {
        let safe = configuration.profileIdentifier
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
            .prefix(48)
        let digest = DomainContentDigest.sha256(Data(configuration.profileIdentifier.utf8)).prefix(12)
        return configuration.storageDirectory
            .appendingPathComponent("DomainRuntime", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("\(safe)-\(digest)", isDirectory: true)
    }

    private var journalDirectory: URL { runtimeRoot.appendingPathComponent("working-journals", isDirectory: true) }
    private var revisionDirectory: URL { runtimeRoot.appendingPathComponent("revisions", isDirectory: true) }
    private var deletionDirectory: URL { runtimeRoot.appendingPathComponent("deletion-tombstones", isDirectory: true) }
    private var lockDirectory: URL { runtimeRoot.appendingPathComponent("locks", isDirectory: true) }
    private var settingsDirectory: URL { runtimeRoot.appendingPathComponent("settings", isDirectory: true) }
    private var rollbackRoot: URL { runtimeRoot.appendingPathComponent("rollback", isDirectory: true) }
    private var workspaceProjectionCheckpointRoot: URL {
        (workspaceAuthorityScope?.canonicalWorkspaceStorageDirectory ?? workspaceRoot)
            .appendingPathComponent(".agentry-domain-runtime", isDirectory: true)
    }
    private var workspaceProjectionCheckpointURL: URL {
        workspaceProjectionCheckpointRoot
            .appendingPathComponent("workspace-projection", isDirectory: true)
            .appendingPathComponent("checkpoint-v1.json")
    }
    private var workspaceProjectionCheckpointLockURL: URL {
        workspaceProjectionCheckpointRoot
            .appendingPathComponent("locks", isDirectory: true)
            .appendingPathComponent("workspace-projection-checkpoint-v1.lock")
    }
    private var policyURL: URL { settingsDirectory.appendingPathComponent("runtime-policy.json") }
    private var protectedMutationPolicyURL: URL {
        settingsDirectory.appendingPathComponent("protected-mutations.json")
    }
    private var protectedMutationPolicyLockURL: URL {
        lockDirectory.appendingPathComponent("protected-mutations.lock")
    }
    private var protectedMutationJournalURL: URL {
        settingsDirectory.appendingPathComponent("protected-mutation-journal.json")
    }
    private var protectedMutationJournalLockURL: URL {
        lockDirectory.appendingPathComponent("protected-mutation-journal.lock")
    }
    private var agentSessionMetadataURL: URL {
        settingsDirectory.appendingPathComponent("agent-sessions.json")
    }
    private var agentSessionMetadataLockURL: URL {
        lockDirectory.appendingPathComponent("agent-sessions.lock")
    }
    private var directSettingsURL: URL {
        settingsDirectory.appendingPathComponent("direct-settings.json")
    }
    private var directSettingsLockURL: URL {
        lockDirectory.appendingPathComponent("direct-settings.lock")
    }
    private var agentWorktreeBindingsURL: URL {
        settingsDirectory.appendingPathComponent("agent-worktree-bindings.json")
    }
    private var agentWorktreeBindingsLockURL: URL {
        lockDirectory.appendingPathComponent("agent-worktree-bindings.lock")
    }
    private var legacyAgentSessionMetadataURL: URL {
        configuration.storageDirectory
            .appendingPathComponent("DomainRuntime", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }
    private var catalogURL: URL { runtimeRoot.appendingPathComponent("workspace-catalog.json") }
    private var indexURL: URL { workspaceRoot.appendingPathComponent("workspacesIndex.json") }

    private func journalURL(_ workspaceID: UUID) -> URL {
        journalDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func revisionURL(_ workspaceID: UUID) -> URL {
        revisionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func deletionURL(_ workspaceID: UUID) -> URL {
        deletionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func lockURL(_ workspaceID: UUID) -> URL {
        lockDirectory.appendingPathComponent("workspace-\(workspaceID.uuidString).lock")
    }

    func bootstrap(
        permit: DomainWorkspaceMutationPermit? = nil
    ) async -> DomainPersistenceBootstrap {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).bootstrapBlocking(
                    validator: validator,
                    permit: permit
                )
            }
        } catch {
            let reason: String = if error as? DomainPersistenceError == .cancelled {
                "bootstrap_cancelled"
            } else {
                "working_journal_rust_unavailable"
            }
            return DomainPersistenceBootstrap(
                workspaces: [],
                unavailableWorkspaces: [],
                deletedOperations: [],
                deletedWorkspaceIDs: [],
                health: .degradedReadOnly(reason: reason),
                catalogRevision: 0
            )
        }
    }

    package func loadWorkspaceProjectionCheckpointData() async throws -> Data? {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.workspaceProjectionCheckpointURL.path) else {
                return nil
            }
            let handle = try FileHandle(forReadingFrom: worker.workspaceProjectionCheckpointURL)
            defer { try? handle.close() }
            let descriptorSize = try handle.seekToEnd()
            guard descriptorSize <= UInt64(Self.maximumWorkspaceProjectionCheckpointBytes) else {
                throw DomainPersistenceError.writeFailed("workspace_projection_checkpoint_too_large")
            }
            try handle.seek(toOffset: 0)
            var data = Data()
            data.reserveCapacity(Int(descriptorSize))
            let chunkSize = 64 * 1024
            while true {
                try cancellation.check()
                let remaining = Self.maximumWorkspaceProjectionCheckpointBytes - data.count
                let nextReadLimit = min(chunkSize, remaining + 1)
                guard let chunk = try handle.read(upToCount: nextReadLimit), !chunk.isEmpty else { break }
                data.append(chunk)
                guard data.count <= Self.maximumWorkspaceProjectionCheckpointBytes else {
                    throw DomainPersistenceError.writeFailed("workspace_projection_checkpoint_too_large")
                }
            }
            return data
        }
    }

    package func persistWorkspaceProjectionCheckpointData(
        _ data: Data,
        permit: DomainWorkspaceMutationPermit
    ) async throws {
        try validateMutationPermitScope(permit)
        guard data.count <= Self.maximumWorkspaceProjectionCheckpointBytes else {
            throw DomainPersistenceError.writeFailed("workspace_projection_checkpoint_too_large")
        }
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.validateMutationPermitScope(permit)
            try worker.withLock(at: worker.workspaceProjectionCheckpointLockURL) {
                try cancellation.check()
                try worker.validateMutationPermitScope(permit)
                try DomainPersistenceLock.atomicWrite(
                    data,
                    to: worker.workspaceProjectionCheckpointURL
                )
            }
        }
    }

    package func loadProtectedMutationPolicyData() async throws -> Data? {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.protectedMutationPolicyURL.path) else {
                return nil
            }
            return try Data(contentsOf: worker.protectedMutationPolicyURL)
        }
    }

    package func compareAndSwapProtectedMutationPolicyData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.protectedMutationPolicyLockURL) {
                try cancellation.check()
                let currentData = try? Data(contentsOf: worker.protectedMutationPolicyURL)
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.protectedMutationPolicyURL)
            }
        }
    }

    package func loadProtectedMutationJournalData() async throws -> Data? {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.protectedMutationJournalURL.path) else {
                return nil
            }
            return try Data(contentsOf: worker.protectedMutationJournalURL)
        }
    }

    package func compareAndSwapProtectedMutationJournalData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.protectedMutationJournalLockURL) {
                try cancellation.check()
                let currentData = try? Data(contentsOf: worker.protectedMutationJournalURL)
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.protectedMutationJournalURL)
            }
        }
    }

    package func loadDirectSettingsData() async throws -> DomainPersistenceDataSnapshot {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            let data = worker.fileManager.fileExists(atPath: worker.directSettingsURL.path)
                ? try Data(contentsOf: worker.directSettingsURL)
                : nil
            return DomainPersistenceDataSnapshot(data: data)
        }
    }

    package func compareAndSwapDirectSettingsData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.directSettingsLockURL) {
                try cancellation.check()
                let currentData = worker.fileManager.fileExists(atPath: worker.directSettingsURL.path)
                    ? try Data(contentsOf: worker.directSettingsURL)
                    : nil
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.directSettingsURL)
            }
        }
    }

    package func loadAgentWorktreeBindingsData() async throws -> DomainPersistenceDataSnapshot {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            let data = worker.fileManager.fileExists(atPath: worker.agentWorktreeBindingsURL.path)
                ? try Data(contentsOf: worker.agentWorktreeBindingsURL)
                : nil
            return DomainPersistenceDataSnapshot(data: data)
        }
    }

    package func compareAndSwapAgentWorktreeBindingsData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.agentWorktreeBindingsLockURL) {
                try cancellation.check()
                let currentData = worker.fileManager.fileExists(atPath: worker.agentWorktreeBindingsURL.path)
                    ? try Data(contentsOf: worker.agentWorktreeBindingsURL)
                    : nil
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.agentWorktreeBindingsURL)
            }
        }
    }

    package func loadAgentSessionMetadataData() async throws -> DomainPersistenceDataSnapshot {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            let data = worker.fileManager.fileExists(atPath: worker.agentSessionMetadataURL.path)
                ? try Data(contentsOf: worker.agentSessionMetadataURL)
                : nil
            return DomainPersistenceDataSnapshot(data: data)
        }
    }

    package func loadLegacyAgentSessionMetadataData() async throws -> DomainPersistenceDataSnapshot {
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            let data = worker.fileManager.fileExists(atPath: worker.legacyAgentSessionMetadataURL.path)
                ? try Data(contentsOf: worker.legacyAgentSessionMetadataURL)
                : nil
            return DomainPersistenceDataSnapshot(data: data)
        }
    }

    package func compareAndSwapAgentSessionMetadataData(
        expectedDigest: String?,
        data: Data
    ) async throws {
        try await DomainBlockingIO.run { cancellation in
            let worker = blockingWorker(cancellation)
            try cancellation.check()
            try worker.withLock(at: worker.agentSessionMetadataLockURL) {
                try cancellation.check()
                let currentData = worker.fileManager.fileExists(atPath: worker.agentSessionMetadataURL.path)
                    ? try Data(contentsOf: worker.agentSessionMetadataURL)
                    : nil
                let currentDigest = currentData.map(DomainContentDigest.sha256)
                guard currentDigest == expectedDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
                try DomainPersistenceLock.atomicWrite(data, to: worker.agentSessionMetadataURL)
            }
        }
    }

    func persistCreated(
        document: DomainWorkspaceDocument,
        expectedCatalogRevision: UInt64?,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceSavedCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistCreatedBlocking(
                validator: validator,
                document: document,
                expectedCatalogRevision: expectedCatalogRevision,
                operationID: operationID,
                contextRevisions: contextRevisions,
                operation: operation,
                now: now,
                permit: permit
            )
        }
    }

    func repairRecoveredCreate(
        document: DomainWorkspaceDocument,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> UInt64 {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).withExistingWorkspaceLocks(
                document: document,
                validator: validator,
                now: now,
                permit: permit
            ) { revision in
                revision
            }
        }
    }

    func persistUnchanged(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceWorkingCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistUnchangedBlocking(
                validator: validator,
                document: document,
                expectedRevision: expectedRevision,
                operation: operation,
                now: now,
                permit: permit
            )
        }
    }

    func persistWorking(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceWorkingCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistWorkingBlocking(
                validator: validator,
                document: document,
                expectedRevision: expectedRevision,
                newRevision: newRevision,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now,
                permit: permit
            )
        }
    }

    func persistSaved(
        document: DomainWorkspaceDocument,
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceSavedCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistSavedBlocking(
                validator: validator,
                document: document,
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now,
                permit: permit
            )
        }
    }

    func persistExternalReload(
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceSavedCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistExternalReloadBlocking(
                validator: validator,
                document: document,
                expectedRevision: expectedRevision,
                newRevision: newRevision,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now,
                permit: permit
            )
        }
    }

    func persistConflictRebase(
        document: DomainWorkspaceDocument,
        externalSavedDigest: String,
        expectedRevisions: DomainRevisionState,
        newRevisions: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceWorkingCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistConflictRebaseBlocking(
                validator: validator,
                document: document,
                externalSavedDigest: externalSavedDigest,
                expectedRevisions: expectedRevisions,
                newRevisions: newRevisions,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                now: now,
                permit: permit
            )
        }
    }

    func persistDeleted(
        document: DomainWorkspaceDocument,
        expectedWorkspaceRevision: UInt64,
        expectedCatalogRevision: UInt64?,
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) async throws -> DomainPersistenceDeleteCommit {
        try await validateMutationPermit(permit, document: document)
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try blockingWorker(cancellation).persistDeletedBlocking(
                validator: validator,
                document: document,
                expectedWorkspaceRevision: expectedWorkspaceRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                operation: operation,
                now: now,
                permit: permit
            )
        }
    }

    func currentCatalogRevision() async throws -> UInt64? {
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard let bytes = try worker.readCatalogBytes() else { return nil }
            return try validator.validateCatalog(bytes).catalog.revision
        }
    }

    func externalDocument(
        for snapshot: DomainWorkspaceSnapshot,
        savedDigest: String,
        knownMetadata: DomainFileMetadata
    ) async -> DomainExternalDocumentProbe {
        do {
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return blockingWorker(cancellation).externalDocumentBlocking(
                    for: snapshot,
                    savedDigest: savedDigest,
                    knownMetadata: knownMetadata
                )
            }
        } catch DomainPersistenceError.cancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .invalid(knownMetadata)
        }
    }

    func reloadWorkspace(
        workspaceID: UUID,
        fileURL: URL
    ) async -> DomainPersistenceBootstrap.Workspace? {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).loadWorkspace(
                    workspaceID: workspaceID,
                    fileURL: fileURL,
                    validator: validator
                )?.workspace
            }
        } catch {
            return nil
        }
    }

    func refreshWorkspace(
        workspaceID: UUID,
        fallbackFileURL: URL
    ) async -> DomainPersistenceWorkspaceRefresh? {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).refreshWorkspaceBlocking(
                    workspaceID: workspaceID,
                    fallbackFileURL: fallbackFileURL,
                    validator: validator
                )
            }
        } catch DomainPersistenceError.cancelled {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                workspaceIsDeleted: false,
                health: .degradedReadOnly(reason: "workspace_catalog_probe_failed"),
                catalogRevision: 0
            )
        }
    }

    private func refreshWorkspaceBlocking(
        workspaceID: UUID,
        fallbackFileURL: URL,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> DomainPersistenceWorkspaceRefresh {
        guard let catalogData = try readCatalogBytes() else {
            return DomainPersistenceWorkspaceRefresh(
                workspace: try loadWorkspace(
                    workspaceID: workspaceID,
                    fileURL: fallbackFileURL,
                    validator: validator
                )?.workspace,
                workspaceIsDeleted: false,
                health: .writable,
                catalogRevision: 0
            )
        }
        let validation: DomainWorkspaceCatalogValidation
        do {
            validation = try validator.validateCatalog(catalogData)
        } catch {
            if isJournalInfrastructureFailure(error) {
                throw error
            }
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                workspaceIsDeleted: false,
                health: .degradedReadOnly(reason: catalogDegradedReason(error)),
                catalogRevision: 0
            )
        }
        let catalog = validation.catalog
        let isDeleted = (catalog.deletions ?? []).contains { $0.workspaceID == workspaceID }
        let fileURL = catalog.entries.first(where: { $0.workspaceID == workspaceID })?.fileURL
            ?? fallbackFileURL
        let workspace: DomainPersistenceBootstrap.Workspace? = if isDeleted {
            nil
        } else {
            try loadWorkspace(
                workspaceID: workspaceID,
                fileURL: fileURL,
                validator: validator
            )?.workspace
        }
        return DomainPersistenceWorkspaceRefresh(
            workspace: workspace,
            workspaceIsDeleted: isDeleted,
            health: .writable,
            catalogRevision: catalog.revision
        )
    }

    private func bootstrapBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        permit: DomainWorkspaceMutationPermit?
    ) throws -> DomainPersistenceBootstrap {
        if let permit {
            try recoverInterruptedCreates(validator: validator, permit: permit)
        }
        var globalHealth: DomainAuthorityHealth = .writable
        let catalog: RuntimeWorkspaceCatalog?
        do {
            if let data = try readCatalogBytes() {
                catalog = try validator.validateCatalog(data).catalog
            } else {
                catalog = nil
            }
        } catch {
            if isJournalInfrastructureFailure(error) {
                throw error
            }
            catalog = nil
            globalHealth = .degradedReadOnly(reason: catalogDegradedReason(error))
        }

        let authoritativeTombstones = catalog?.deletions ?? []
        var sidecarTombstonesByWorkspaceID = [UUID: DomainDeletionTombstone]()
        for authoritative in authoritativeTombstones {
            switch try readOptionalMetadataSnapshot(at: deletionURL(authoritative.workspaceID)) {
            case .absent:
                continue
            case .oversized:
                try validator.requireRuntimeAvailability()
            case let .present(data):
                do {
                    let sidecar = try validator.validateDeletionTombstone(data).tombstone
                    if deletionSidecar(sidecar, matches: authoritative) {
                        sidecarTombstonesByWorkspaceID[authoritative.workspaceID] = sidecar
                    }
                } catch {
                    if isJournalInfrastructureFailure(error) {
                        throw error
                    }
                }
            }
        }
        // The catalog alone is deletion authority. A bounded exact-identity sidecar may replace
        // only the cleanup diagnostic of an already-authoritative tombstone.
        let deletionTombstones = authoritativeTombstones.map { authoritative in
            sidecarTombstonesByWorkspaceID[authoritative.workspaceID] ?? authoritative
        }.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
        let deletedIDs = Set(deletionTombstones.map(\.workspaceID))

        let entries: [RuntimeWorkspaceCatalog.Entry]
        if let catalog {
            entries = catalog.entries.filter { !deletedIDs.contains($0.workspaceID) }
        } else {
            do {
                entries = try legacyCatalogEntries().filter { !deletedIDs.contains($0.workspaceID) }
            } catch {
                return DomainPersistenceBootstrap(
                    workspaces: [],
                    unavailableWorkspaces: [],
                    deletedOperations: deletionTombstones.map(\.operation),
                    deletedWorkspaceIDs: deletedIDs,
                    health: .degradedReadOnly(reason: "workspace_index_decode_failed"),
                    catalogRevision: 0
                )
            }
        }

        var loaded: [DomainPersistenceBootstrap.Workspace] = []
        var unavailable: [DomainPersistenceBootstrap.UnavailableWorkspace] = []
        var loadedIDs = Set<UUID>()
        let entriesByWorkspaceID = Dictionary(grouping: entries, by: \.workspaceID)
        let duplicateWorkspaceIDs = Set(entriesByWorkspaceID.compactMap { workspaceID, matchingEntries in
            matchingEntries.count > 1 ? workspaceID : nil
        })
        if !duplicateWorkspaceIDs.isEmpty {
            globalHealth = .degradedReadOnly(reason: "duplicate_workspace_catalog_id")
        }
        for entry in entries {
            guard loadedIDs.insert(entry.workspaceID).inserted else { continue }
            if duplicateWorkspaceIDs.contains(entry.workspaceID) {
                unavailable.append(.init(
                    workspaceID: entry.workspaceID,
                    fileURL: entry.fileURL,
                    reason: "duplicate_workspace_catalog_id",
                    fileMetadata: fileMetadata(at: entry.fileURL)
                ))
            } else if let result = try loadWorkspace(
                workspaceID: entry.workspaceID,
                fileURL: entry.fileURL,
                validator: validator
            ) {
                loaded.append(result.workspace)
            } else {
                unavailable.append(.init(
                    workspaceID: entry.workspaceID,
                    fileURL: entry.fileURL,
                    reason: "workspace_document_unavailable",
                    fileMetadata: fileMetadata(at: entry.fileURL)
                ))
            }
        }

        return DomainPersistenceBootstrap(
            workspaces: loaded,
            unavailableWorkspaces: unavailable,
            deletedOperations: deletionTombstones.map(\.operation),
            deletedWorkspaceIDs: deletedIDs,
            health: globalHealth,
            catalogRevision: catalog?.revision ?? 0
        )
    }

    /// Discovers bounded runtime-owned journals, but delegates every recovery decision and catalog
    /// candidate to the Rust create transaction. Read-only bootstrap never exposes catalog-absent
    /// journals; only lease-backed reconciliation can publish them through exact catalog CAS.
    private func recoverInterruptedCreates(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        permit: DomainWorkspaceMutationPermit
    ) throws {
        try validateMutationPermitScope(permit)
        guard try readCatalogBytes() != nil else { return }
        let journalURLs = (try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for journalURL in journalURLs where journalURL.pathExtension == "json" {
            try cancellation?.check()
            try validateMutationPermitScope(permit)
            guard let workspaceID = UUID(
                uuidString: journalURL.deletingPathExtension().lastPathComponent
            ) else { continue }
            let validation: DomainWorkspaceWorkingJournalValidation
            switch loadJournal(workspaceID: workspaceID, validator: validator) {
            case let .success(candidate?):
                validation = candidate
            case .success(nil):
                continue
            case let .failure(error):
                if isJournalInfrastructureFailure(error) { throw error }
                continue
            }
            guard let documentBytes = try boundedWorkspaceDocumentBytes(
                at: validation.journal.fileURL
            ),
                let document = try? DomainWorkspaceDocument.decode(
                    documentBytes: documentBytes,
                    fileURL: validation.journal.fileURL
                ),
                document.workspaceID == workspaceID
            else { continue }
            do {
                _ = try withExistingWorkspaceLocks(
                    document: document,
                    validator: validator,
                    now: Date(),
                    permit: permit
                ) { $0 }
            } catch let error as DomainPersistenceError {
                switch error {
                case .stateConflict,
                     .corruptJournal,
                     .futureJournal,
                     .externalDocumentConflict,
                     .operationIDCollision,
                     .invalidWorkspaceDocument:
                    continue
                case .cancelled,
                     .lockTimedOut,
                     .mutationPermitInvalid,
                     .workspaceOutsideMutationScope,
                     .writeFailed:
                    throw error
                }
            }
        }
    }

    private func deletionSidecar(
        _ sidecar: DomainDeletionTombstone,
        matches authoritative: DomainDeletionTombstone
    ) -> Bool {
        sidecar.version == authoritative.version
            && sidecar.workspaceID == authoritative.workspaceID
            && sidecar.fileURL.standardizedFileURL == authoritative.fileURL.standardizedFileURL
            && sidecar.deletedAt == authoritative.deletedAt
            && sidecar.operation.operationID == authoritative.operation.operationID
            && sidecar.operation.fingerprint == authoritative.operation.fingerprint
            && sidecar.operation.recordedAt == authoritative.operation.recordedAt
            && sidecar.operation.disposition == authoritative.operation.disposition
            && sidecar.operation.before == authoritative.operation.before
            && sidecar.operation.after == authoritative.operation.after
            && sidecar.operation.catalogRevision == authoritative.operation.catalogRevision
            && sidecar.operation.resultingDigest == authoritative.operation.resultingDigest
            && sidecar.operation.errorCode == authoritative.operation.errorCode
            && deletionSidecarDiagnostic(
                sidecar.operation.diagnostic,
                matches: authoritative.operation.diagnostic
            )
    }

    private func deletionSidecarDiagnostic(
        _ sidecar: String?,
        matches authoritative: String?
    ) -> Bool {
        guard sidecar != authoritative else { return true }
        guard let sidecar,
              sidecar.hasPrefix("artifact_cleanup_incomplete: ")
        else { return false }
        return sidecar.count > "artifact_cleanup_incomplete: ".count
    }

    private func legacyCatalogEntries() throws -> [RuntimeWorkspaceCatalog.Entry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        return try decoder.decode([LegacyWorkspaceIndexEntry].self, from: Data(contentsOf: indexURL)).map { entry in
            let fileURL = entry.customStoragePath?.appendingPathComponent("workspace.json")
                ?? workspaceRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: entry.name, id: entry.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            return RuntimeWorkspaceCatalog.Entry(workspaceID: entry.id, fileURL: fileURL)
        }
    }

    private func isJournalInfrastructureFailure(_ error: Error) -> Bool {
        guard let persistenceError = error as? DomainPersistenceError else { return true }
        switch persistenceError {
        case .cancelled, .writeFailed("working_journal_rust_unavailable"):
            return true
        default:
            return false
        }
    }

    private func catalogDegradedReason(_ error: Error) -> String {
        guard let persistenceError = error as? DomainPersistenceError else {
            return "workspace_catalog_decode_failed"
        }
        return switch persistenceError {
        case .futureJournal:
            "future_workspace_catalog"
        case .writeFailed("workspace_catalog_too_large"):
            "workspace_catalog_too_large"
        default:
            "workspace_catalog_decode_failed"
        }
    }

    private func journalDegradedReason(_ error: Error) -> String {
        guard let persistenceError = error as? DomainPersistenceError else {
            return "working_journal_decode_failed"
        }
        switch persistenceError {
        case .futureJournal:
            return "future_working_journal"
        case .writeFailed("working_journal_too_large"):
            return "working_journal_too_large"
        default:
            return "working_journal_decode_failed"
        }
    }

    private func loadWorkspace(
        workspaceID: UUID,
        fileURL: URL,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> (workspace: DomainPersistenceBootstrap.Workspace, degradedReason: String?)? {
        let observedMetadata = fileMetadata(at: fileURL)
        let savedBytes = try? Data(contentsOf: fileURL)
        let savedBytesDigest = savedBytes.map(DomainContentDigest.sha256)
        let savedDocument = savedBytes.flatMap {
            decodeWorkspaceDocument($0, fileURL: fileURL, expectedWorkspaceID: workspaceID)
        }
        /// Metadata is only a trusted "no external change" fast-path baseline when the
        /// on-disk bytes still match the journal's saved digest. Otherwise the first
        /// external-document probe must fall back to a full read + digest comparison,
        /// or an edit made while the runtime was down would be masked forever.
        func trustedMetadata(matching savedDigest: String) -> DomainFileMetadata {
            savedBytesDigest == savedDigest ? observedMetadata : .missing
        }
        func degradedSavedWorkspace(
            reason: String,
            journal: DomainWorkingJournal? = nil
        ) -> (workspace: DomainPersistenceBootstrap.Workspace, degradedReason: String?)? {
            guard let savedDocument else { return nil }
            let savedRevision = journal?.revisions.savedRevision ?? 0
            let revisions = DomainRevisionState(
                workingRevision: savedRevision,
                savedRevision: savedRevision,
                dirtyRevision: nil
            )
            return (.init(
                document: savedDocument,
                savedDigest: savedDocument.contentDigest,
                revisions: revisions,
                contextRevisions: Dictionary(uniqueKeysWithValues: savedDocument.metadata.contexts.map {
                    ($0.identity.contextID, revisions)
                }),
                contextTombstones: journal?.contextTombstones ?? [:],
                operations: journal?.operations ?? [],
                health: .degradedReadOnly(reason: reason),
                fileMetadata: observedMetadata
            ), reason)
        }

        switch loadJournal(
            workspaceID: workspaceID,
            validator: validator
        ) {
        case let .success(validation?):
            let journal = validation.journal
            guard journal.workspaceID == workspaceID,
                  journal.fileURL.standardizedFileURL == fileURL.standardizedFileURL
            else {
                return degradedSavedWorkspace(reason: "working_journal_identity_mismatch")
            }
            guard journal.version <= DomainWorkingJournal.schemaVersion else {
                return degradedSavedWorkspace(reason: "future_working_journal")
            }
            do {
                if let recovered = try resolvedPendingSave(
                    validation,
                    expectedWorkspaceID: workspaceID,
                    validator: validator
                ) {
                    let recoveredJournal = recovered.validation.journal
                    return (.init(
                        document: recovered.document,
                        savedDigest: recoveredJournal.savedDigest,
                        revisions: recoveredJournal.revisions,
                        contextRevisions: recoveredJournal.contextRevisions,
                        contextTombstones: recoveredJournal.contextTombstones,
                        operations: recoveredJournal.operations,
                        health: .writable,
                        fileMetadata: trustedMetadata(matching: recoveredJournal.savedDigest)
                    ), nil)
                }
            } catch {
                if isJournalInfrastructureFailure(error) {
                    throw error
                }
                return degradedSavedWorkspace(
                    reason: "working_journal_recovery_failed",
                    journal: journal
                )
            }
            if let workingBytes = journal.workingDocument {
                guard let document = decodeWorkspaceDocument(
                    workingBytes,
                    fileURL: fileURL,
                    expectedWorkspaceID: workspaceID
                ) else {
                    return degradedSavedWorkspace(
                        reason: "working_document_decode_failed",
                        journal: journal
                    )
                }
                return (.init(
                    document: document,
                    savedDigest: journal.savedDigest,
                    revisions: journal.revisions,
                    contextRevisions: journal.contextRevisions,
                    contextTombstones: journal.contextTombstones,
                    operations: journal.operations,
                    health: .writable,
                    fileMetadata: trustedMetadata(matching: journal.savedDigest)
                ), nil)
            }
            guard let savedDocument else { return nil }
            return (.init(
                document: savedDocument,
                savedDigest: journal.savedDigest,
                revisions: journal.revisions,
                contextRevisions: journal.contextRevisions,
                contextTombstones: journal.contextTombstones,
                operations: journal.operations,
                health: .writable,
                fileMetadata: trustedMetadata(matching: journal.savedDigest)
            ), nil)
        case .success(nil):
            guard let savedDocument else { return nil }
            let revisions = try loadSavedRevision(
                workspaceID: workspaceID,
                digest: savedDocument.contentDigest,
                validator: validator
            )
            return (.init(
                document: savedDocument,
                savedDigest: savedDocument.contentDigest,
                revisions: revisions,
                contextRevisions: Dictionary(uniqueKeysWithValues: savedDocument.metadata.contexts.map {
                    ($0.identity.contextID, revisions)
                }),
                contextTombstones: [:],
                operations: [],
                health: .writable,
                fileMetadata: observedMetadata
            ), nil)
        case let .failure(error):
            if isJournalInfrastructureFailure(error) {
                throw error
            }
            return degradedSavedWorkspace(reason: journalDegradedReason(error))
        }
    }

    private func decodeWorkspaceDocument(
        _ bytes: Data,
        fileURL: URL,
        expectedWorkspaceID: UUID
    ) -> DomainWorkspaceDocument? {
        guard let document = try? DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL),
              document.workspaceID == expectedWorkspaceID
        else { return nil }
        return document
    }

    private func persistCreatedBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedCatalogRevision: UInt64?,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceSavedCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            try validateMutationScope(permit, document: document)
            let currentCatalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)
            let currentCatalogValidation = currentCatalogSnapshot.validation
            let currentCatalog = currentCatalogValidation.catalog
            if let expectedCatalogRevision,
               expectedCatalogRevision != currentCatalog.revision
            {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedCatalogRevision,
                    actual: currentCatalog.revision
                )
            }
            guard !currentCatalog.entries.contains(where: {
                $0.workspaceID == document.workspaceID
            }) else {
                throw DomainPersistenceError.stateConflict(expected: 0, actual: 1)
            }
            guard operation.operationID == operationID else {
                throw DomainPersistenceError.corruptJournal
            }

            return try withLock(at: lockURL(document.workspaceID)) {
                try validateMutationScope(permit, document: document)
                let originalRaw = try readRawJournalSnapshot(workspaceID: document.workspaceID)
                if case let .present(_, bytes) = originalRaw {
                    let existing = try validator.validateSynchronously(
                        bytes,
                        expectedWorkspaceID: document.workspaceID,
                        expectedFileURL: document.fileURL
                    ).journal
                    throw DomainPersistenceError.stateConflict(
                        expected: 0,
                        actual: existing.revisions.workingRevision
                    )
                }
                guard !fileManager.fileExists(atPath: document.fileURL.path) else {
                    throw DomainPersistenceError.stateConflict(expected: 0, actual: 1)
                }
                let rawCatalogBytes: Data? = switch currentCatalogSnapshot.raw {
                case .absent: nil
                case let .present(_, bytes): bytes
                }
                let transaction = try validator.beginCreateTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalog: currentCatalogValidation,
                    document: document,
                    contextRevisions: contextRevisions,
                    operation: operation,
                    updatedAt: now
                )
                defer { transaction.close() }

                func failureReport(
                    actionID: UInt64,
                    error: Error
                ) -> CoreWorkspaceSaveActionReportV1 {
                    if error is CancellationError || error as? DomainPersistenceError == .cancelled {
                        return .cancelled(actionID: actionID)
                    }
                    if case let DomainPersistenceError.stateConflict(expected, actual) = error {
                        return .stateConflict(
                            actionID: actionID,
                            expected: expected,
                            actual: actual
                        )
                    }
                    return .writeFailed(actionID: actionID)
                }

                var rawJournal = originalRaw
                var directive = try transaction.nextDirective()
                var authorityReceipt: DomainWorkspaceCreateCommitReceipt?
                var catalogAuthorityEstablished = false
                do {
                    createTransactionLoop: while true {
                        switch directive {
                        case let .writePendingJournal(
                            actionID,
                            expectedRawDigest,
                            validation,
                            logicalExpectedRevision
                        ):
                            guard rawJournal.digest == expectedRawDigest else {
                                throw DomainPersistenceError.corruptJournal
                            }
                            rawJournal = try replaceJournal(
                                expected: rawJournal,
                                candidate: PreparedJournalCandidate(
                                    journal: validation.journal,
                                    canonicalBytes: validation.canonicalBytes,
                                    contentDigest: validation.contentDigest
                                ),
                                logicalExpectedRevision: logicalExpectedRevision,
                                validator: validator
                            )
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: validation.contentDigest
                            ))
                        case let .publishWorkspaceDocument(actionID, bytes, contentDigest):
                            try DomainPersistenceLock.atomicWrite(bytes, to: document.fileURL)
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: contentDigest
                            ))
                        case let .writeCommittedJournal(
                            actionID,
                            expectedRawDigest,
                            validation,
                            logicalExpectedRevision
                        ):
                            guard rawJournal.digest == expectedRawDigest else {
                                throw DomainPersistenceError.corruptJournal
                            }
                            rawJournal = try replaceJournal(
                                expected: rawJournal,
                                candidate: PreparedJournalCandidate(
                                    journal: validation.journal,
                                    canonicalBytes: validation.canonicalBytes,
                                    contentDigest: validation.contentDigest
                                ),
                                logicalExpectedRevision: logicalExpectedRevision,
                                validator: validator,
                                allowsCancellation: false
                            )
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: validation.contentDigest
                            ))
                        case let .writeSavedRevision(actionID, validation):
                            try DomainPersistenceLock.atomicWrite(
                                validation.canonicalBytes,
                                to: revisionURL(document.workspaceID)
                            )
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: validation.contentDigest
                            ))
                        case let .removeDeletionSidecar(actionID, contentDigest):
                            let sidecar = deletionURL(document.workspaceID)
                            if fileManager.fileExists(atPath: sidecar.path) {
                                try fileManager.removeItem(at: sidecar)
                            }
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: contentDigest
                            ))
                        case let .publishCatalog(
                            actionID,
                            expectedRawDigest,
                            catalog,
                            logicalExpectedRevision,
                            attachedReceipt
                        ):
                            guard currentCatalogSnapshot.raw.digest == expectedRawDigest else {
                                throw DomainPersistenceError.corruptJournal
                            }
                            do {
                                let authorityPermit = try transaction.acquireAuthorityPermit()
                                defer { authorityPermit.close() }
                                _ = try writeCatalog(
                                    expected: currentCatalogSnapshot.raw,
                                    candidate: catalog,
                                    logicalExpectedRevision: logicalExpectedRevision,
                                    validator: validator
                                )
                                catalogAuthorityEstablished = true
                                do {
                                    let reported = try transaction.report(.success(
                                        actionID: actionID,
                                        writtenDigest: catalog.contentDigest
                                    ))
                                    if case let .committed(receipt) = reported {
                                        authorityReceipt = receipt
                                    } else {
                                        authorityReceipt = attachedReceipt
                                    }
                                } catch {
                                    authorityReceipt = attachedReceipt
                                }
                                break createTransactionLoop
                            } catch {
                                let physicalError = error
                                do {
                                    directive = try transaction.report(failureReport(
                                        actionID: actionID,
                                        error: physicalError
                                    ))
                                } catch {
                                    throw physicalError
                                }
                                if case .failed = directive { throw physicalError }
                            }
                        case let .committed(receipt):
                            authorityReceipt = receipt
                            catalogAuthorityEstablished = true
                            break createTransactionLoop
                        case let .failed(failure):
                            switch failure {
                            case .cancelled:
                                throw DomainPersistenceError.cancelled
                            case let .stateConflict(expected, actual):
                                throw DomainPersistenceError.stateConflict(
                                    expected: expected,
                                    actual: actual
                                )
                            case .writeFailed:
                                throw DomainPersistenceError.writeFailed(
                                    "workspace_create_transaction_write_failed"
                                )
                            }
                        }
                    }
                } catch {
                    if !catalogAuthorityEstablished {
                        try? fileManager.removeItem(at: journalURL(document.workspaceID))
                        try? fileManager.removeItem(at: revisionURL(document.workspaceID))
                        try? fileManager.removeItem(at: document.fileURL)
                    }
                    throw error
                }
                guard let authorityReceipt else {
                    throw DomainPersistenceError.corruptJournal
                }
                return DomainPersistenceSavedCommit(
                    journal: authorityReceipt.committedJournal.journal,
                    catalogRevision: authorityReceipt.catalog.catalog.revision,
                    revisionSidecarMissing: false
                )
            }
        }
    }

    private func executeJournalMutationTransaction(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        snapshot: ValidatedJournalSnapshot,
        document: DomainWorkspaceDocument,
        transition: DomainWorkspaceWorkingJournalTransition,
        catalogRevision: UInt64,
        revisionOperationID: UUID?,
        now: Date,
        diskDocumentBytes: Data?
    ) throws -> (
        receipt: DomainWorkspaceJournalMutationCommitReceipt,
        finalization: DomainWorkspaceJournalMutationFinalization
    ) {
        let rawJournalBytes: Data? = switch snapshot.raw {
        case .absent: nil
        case let .present(_, bytes): bytes
        }
        let transaction = try validator.beginJournalMutationTransaction(
            rawJournalBytes: rawJournalBytes,
            effectiveJournal: snapshot.effectiveValidation,
            document: document,
            transition: transition,
            catalogRevision: catalogRevision,
            revisionOperationID: revisionOperationID,
            updatedAt: now,
            diskDocumentBytes: diskDocumentBytes
        )
        defer { transaction.close() }

        func rawSnapshot(digest: String?) -> RawJournalSnapshot {
            if let digest { return .present(digest: digest, bytes: Data()) }
            return .absent
        }

        func failureReport(
            actionID: UInt64,
            error: Error
        ) -> CoreWorkspaceSaveActionReportV1 {
            if error is CancellationError || error as? DomainPersistenceError == .cancelled {
                return .cancelled(actionID: actionID)
            }
            if case let DomainPersistenceError.stateConflict(expected, actual) = error {
                return .stateConflict(
                    actionID: actionID,
                    expected: expected,
                    actual: actual
                )
            }
            return .writeFailed(actionID: actionID)
        }

        var directive = try transaction.nextDirective()
        var activatedReceipt: DomainWorkspaceJournalMutationCommitReceipt?
        var activatedFinalization: DomainWorkspaceJournalMutationFinalization?
        var expectedActionID: UInt64 = 1

        func receiptsMatch(
            _ lhs: DomainWorkspaceJournalMutationCommitReceipt,
            _ rhs: DomainWorkspaceJournalMutationCommitReceipt
        ) -> Bool {
            lhs.workspaceID == rhs.workspaceID
                && lhs.requestDigest == rhs.requestDigest
                && lhs.catalogRevision == rhs.catalogRevision
                && lhs.committedJournal.contentDigest == rhs.committedJournal.contentDigest
                && lhs.committedJournal.canonicalBytes == rhs.committedJournal.canonicalBytes
                && lhs.savedRevision?.contentDigest == rhs.savedRevision?.contentDigest
                && lhs.savedRevision?.canonicalBytes == rhs.savedRevision?.canonicalBytes
        }

        func activatedOutcome() -> (
            receipt: DomainWorkspaceJournalMutationCommitReceipt,
            finalization: DomainWorkspaceJournalMutationFinalization
        )? {
            guard let activatedReceipt, let activatedFinalization else { return nil }
            return (activatedReceipt, activatedFinalization)
        }

        while true {
            switch directive {
            case let .writeJournal(
                actionID,
                expectedRawDigest,
                validation,
                logicalExpectedRevision,
                authorityReceipt,
                postAuthoritySuccessFinalization
            ):
                guard actionID == expectedActionID, activatedReceipt == nil else {
                    if let outcome = activatedOutcome() { return outcome }
                    throw DomainPersistenceError.corruptJournal
                }
                do {
                    let authorityPermit = try transaction.acquireAuthorityPermit()
                    defer { authorityPermit.close() }
                    _ = try replaceJournal(
                        expected: rawSnapshot(digest: expectedRawDigest),
                        candidate: PreparedJournalCandidate(
                            journal: validation.journal,
                            canonicalBytes: validation.canonicalBytes,
                            contentDigest: validation.contentDigest
                        ),
                        logicalExpectedRevision: logicalExpectedRevision,
                        validator: validator
                    )
                    activatedReceipt = authorityReceipt
                    activatedFinalization = postAuthoritySuccessFinalization
                    expectedActionID += 1
                    do {
                        directive = try transaction.report(.success(
                            actionID: actionID,
                            writtenDigest: validation.contentDigest
                        ))
                    } catch {
                        return (authorityReceipt, postAuthoritySuccessFinalization)
                    }
                } catch {
                    let physicalError = error
                    do {
                        directive = try transaction.report(failureReport(
                            actionID: actionID,
                            error: physicalError
                        ))
                    } catch {
                        throw physicalError
                    }
                    if case .failed = directive { throw physicalError }
                }

            case let .writeSavedRevision(
                actionID,
                validation,
                postAuthoritySuccessFinalization,
                postAuthorityFailureFinalization
            ):
                guard actionID == expectedActionID, activatedReceipt != nil else {
                    if let outcome = activatedOutcome() { return outcome }
                    throw DomainPersistenceError.corruptJournal
                }
                do {
                    try DomainPersistenceLock.atomicWrite(
                        validation.canonicalBytes,
                        to: revisionURL(document.workspaceID)
                    )
                    activatedFinalization = postAuthoritySuccessFinalization
                    expectedActionID += 1
                    do {
                        directive = try transaction.report(.success(
                            actionID: actionID,
                            writtenDigest: validation.contentDigest
                        ))
                    } catch {
                        guard let activatedReceipt else { throw error }
                        return (activatedReceipt, postAuthoritySuccessFinalization)
                    }
                } catch {
                    let physicalError = error
                    activatedFinalization = postAuthorityFailureFinalization
                    expectedActionID += 1
                    do {
                        directive = try transaction.report(failureReport(
                            actionID: actionID,
                            error: physicalError
                        ))
                    } catch {
                        guard let outcome = activatedOutcome() else { throw physicalError }
                        return outcome
                    }
                }

            case let .committed(receipt, finalization):
                guard let outcome = activatedOutcome() else {
                    throw DomainPersistenceError.corruptJournal
                }
                guard receiptsMatch(receipt, outcome.receipt),
                      finalization == outcome.finalization
                else { return outcome }
                return (receipt, finalization)

            case let .failed(failure):
                if let outcome = activatedOutcome() { return outcome }
                switch failure {
                case .cancelled:
                    throw DomainPersistenceError.cancelled
                case let .stateConflict(expected, actual):
                    throw DomainPersistenceError.stateConflict(
                        expected: expected,
                        actual: actual
                    )
                case .writeFailed:
                    throw DomainPersistenceError.writeFailed(
                        "workspace_journal_mutation_transaction_write_failed"
                    )
                }
            }
        }
    }

    private func persistUnchangedBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceWorkingCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withExistingWorkspaceLocks(
            document: document,
            validator: validator,
            now: now,
            permit: permit
        ) { catalogRevision in
            let snapshot = try readCurrentJournalOrSeed(
                document: document,
                validator: validator
            )
            let receipt = try executeJournalMutationTransaction(
                validator: validator,
                snapshot: snapshot,
                document: document,
                transition: .unchanged(
                    expectedWorkingRevision: expectedRevision,
                    operation: operation,
                    updatedAt: now
                ),
                catalogRevision: catalogRevision,
                revisionOperationID: nil,
                now: now,
                diskDocumentBytes: try boundedWorkspaceDocumentBytes(at: document.fileURL)
            ).receipt
            return DomainPersistenceWorkingCommit(
                journal: receipt.committedJournal.journal,
                catalogRevision: receipt.catalogRevision
            )
        }
    }

    private func persistWorkingBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceWorkingCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withExistingWorkspaceLocks(
            document: document,
            validator: validator,
            now: now,
            permit: permit
        ) { catalogRevision in
            let snapshot = try readCurrentJournalOrSeed(
                document: document,
                validator: validator
            )
            let receipt = try executeJournalMutationTransaction(
                validator: validator,
                snapshot: snapshot,
                document: document,
                transition: .working(
                    expectedWorkingRevision: expectedRevision,
                    newRevisions: newRevision,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: contextTombstones,
                    operations: operations,
                    updatedAt: now
                ),
                catalogRevision: catalogRevision,
                revisionOperationID: nil,
                now: now,
                diskDocumentBytes: try boundedWorkspaceDocumentBytes(at: document.fileURL)
            ).receipt
            return DomainPersistenceWorkingCommit(
                journal: receipt.committedJournal.journal,
                catalogRevision: receipt.catalogRevision
            )
        }
    }

    private func persistSavedBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceSavedCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withExistingWorkspaceLocks(
            document: document,
            validator: validator,
            now: now,
            permit: permit
        ) { catalogRevision in
            let snapshot = try readCurrentJournalOrSeed(
                document: document,
                validator: validator
            )
            let rawJournalBytes: Data? = switch snapshot.raw {
            case .absent: nil
            case let .present(_, bytes): bytes
            }
            let transaction = try validator.beginSaveTransaction(
                rawJournalBytes: rawJournalBytes,
                effectiveJournal: snapshot.effectiveValidation,
                document: document,
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                contextRevisions: contextRevisions,
                contextTombstones: contextTombstones,
                operations: operations,
                updatedAt: now,
                catalogRevision: catalogRevision,
                diskDocumentBytes: try boundedWorkspaceDocumentBytes(at: document.fileURL)
            )
            defer { transaction.close() }

            func commit(
                _ receipt: DomainWorkspaceSaveCommitReceipt,
                finalization: DomainWorkspaceSaveFinalization
            ) -> DomainPersistenceSavedCommit {
                DomainPersistenceSavedCommit(
                    journal: receipt.committedJournal.journal,
                    catalogRevision: receipt.catalogRevision,
                    revisionSidecarMissing: finalization == .revisionSidecarMissing
                )
            }

            func rawSnapshot(
                digest: String?,
                bytes: Data = Data()
            ) -> RawJournalSnapshot {
                if let digest { return .present(digest: digest, bytes: bytes) }
                return .absent
            }

            func failureReport(
                actionID: UInt64,
                error: Error
            ) -> CoreWorkspaceSaveActionReportV1 {
                if error is CancellationError || error as? DomainPersistenceError == .cancelled {
                    return .cancelled(actionID: actionID)
                }
                if case let DomainPersistenceError.stateConflict(expected, actual) = error {
                    return .stateConflict(
                        actionID: actionID,
                        expected: expected,
                        actual: actual
                    )
                }
                return .writeFailed(actionID: actionID)
            }

            var directive = try transaction.nextDirective()
            var activatedReceipt: DomainWorkspaceSaveCommitReceipt?
            var activatedFinalization: DomainWorkspaceSaveFinalization?
            var expectedActionID: UInt64 = 1

            func receiptsMatch(
                _ lhs: DomainWorkspaceSaveCommitReceipt,
                _ rhs: DomainWorkspaceSaveCommitReceipt
            ) -> Bool {
                lhs.workspaceID == rhs.workspaceID
                    && lhs.operationID == rhs.operationID
                    && lhs.requestDigest == rhs.requestDigest
                    && lhs.catalogRevision == rhs.catalogRevision
                    && lhs.documentDigest == rhs.documentDigest
                    && lhs.committedJournal.contentDigest == rhs.committedJournal.contentDigest
                    && lhs.committedJournal.canonicalBytes == rhs.committedJournal.canonicalBytes
                    && lhs.savedRevision.contentDigest == rhs.savedRevision.contentDigest
                    && lhs.savedRevision.canonicalBytes == rhs.savedRevision.canonicalBytes
            }

            func activatedCommit() -> DomainPersistenceSavedCommit? {
                guard let activatedReceipt, let activatedFinalization else { return nil }
                return commit(activatedReceipt, finalization: activatedFinalization)
            }

            while true {
                switch directive {
                case let .writePendingJournal(
                    actionID,
                    expectedRawDigest,
                    validation,
                    logicalExpectedRevision
                ):
                    guard actionID == expectedActionID, activatedReceipt == nil else {
                        if let committed = activatedCommit() { return committed }
                        throw DomainPersistenceError.corruptJournal
                    }
                    do {
                        _ = try replaceJournal(
                            expected: rawSnapshot(digest: expectedRawDigest),
                            candidate: PreparedJournalCandidate(
                                journal: validation.journal,
                                canonicalBytes: validation.canonicalBytes,
                                contentDigest: validation.contentDigest
                            ),
                            logicalExpectedRevision: logicalExpectedRevision,
                            validator: validator
                        )
                        expectedActionID += 1
                        directive = try transaction.report(.success(
                            actionID: actionID,
                            writtenDigest: validation.contentDigest
                        ))
                    } catch {
                        let physicalError = error
                        do {
                            directive = try transaction.report(failureReport(
                                actionID: actionID,
                                error: physicalError
                            ))
                        } catch {
                            throw physicalError
                        }
                        if case .failed = directive { throw physicalError }
                    }

                case let .publishWorkspaceDocument(
                    actionID,
                    bytes,
                    contentDigest,
                    authorityReceipt,
                    postAuthoritySuccessFinalization
                ):
                    guard actionID == expectedActionID, activatedReceipt == nil else {
                        if let committed = activatedCommit() { return committed }
                        throw DomainPersistenceError.corruptJournal
                    }
                    guard bytes == document.documentBytes else {
                        throw DomainPersistenceError.corruptJournal
                    }
                    do {
                        try DomainPersistenceLock.atomicWrite(bytes, to: document.fileURL)
                        // Rust attached and DomainRuntime verified this receipt before the physical
                        // authority write. Once atomicWrite returns, no later failure may report a
                        // false failed save.
                        activatedReceipt = authorityReceipt
                        activatedFinalization = postAuthoritySuccessFinalization
                        expectedActionID += 1
                        do {
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: contentDigest
                            ))
                        } catch {
                            return commit(
                                authorityReceipt,
                                finalization: postAuthoritySuccessFinalization
                            )
                        }
                    } catch {
                        let physicalError = error
                        do {
                            directive = try transaction.report(failureReport(
                                actionID: actionID,
                                error: physicalError
                            ))
                        } catch {
                            throw physicalError
                        }
                        if case .failed = directive { throw physicalError }
                    }

                case let .writeCommittedJournal(
                    actionID,
                    expectedRawDigest,
                    validation,
                    logicalExpectedRevision,
                    postAuthoritySuccessFinalization,
                    postAuthorityFailureFinalization
                ):
                    guard actionID == expectedActionID, activatedReceipt != nil else {
                        if let committed = activatedCommit() { return committed }
                        throw DomainPersistenceError.corruptJournal
                    }
                    do {
                        _ = try replaceJournal(
                            expected: rawSnapshot(digest: expectedRawDigest),
                            candidate: PreparedJournalCandidate(
                                journal: validation.journal,
                                canonicalBytes: validation.canonicalBytes,
                                contentDigest: validation.contentDigest
                            ),
                            logicalExpectedRevision: logicalExpectedRevision,
                            validator: validator
                        )
                        activatedFinalization = postAuthoritySuccessFinalization
                        expectedActionID += 1
                        do {
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: validation.contentDigest
                            ))
                        } catch {
                            guard let committed = activatedCommit() else { throw error }
                            return committed
                        }
                    } catch {
                        let physicalError = error
                        activatedFinalization = postAuthorityFailureFinalization
                        expectedActionID += 1
                        do {
                            directive = try transaction.report(failureReport(
                                actionID: actionID,
                                error: physicalError
                            ))
                        } catch {
                            if let committed = activatedCommit() { return committed }
                            throw physicalError
                        }
                    }

                case let .writeSavedRevision(
                    actionID,
                    validation,
                    postAuthoritySuccessFinalization,
                    postAuthorityFailureFinalization
                ):
                    guard actionID == expectedActionID, activatedReceipt != nil else {
                        if let committed = activatedCommit() { return committed }
                        throw DomainPersistenceError.corruptJournal
                    }
                    do {
                        try DomainPersistenceLock.atomicWrite(
                            validation.canonicalBytes,
                            to: revisionURL(document.workspaceID)
                        )
                        activatedFinalization = postAuthoritySuccessFinalization
                        expectedActionID += 1
                        do {
                            directive = try transaction.report(.success(
                                actionID: actionID,
                                writtenDigest: validation.contentDigest
                            ))
                        } catch {
                            guard let committed = activatedCommit() else { throw error }
                            return committed
                        }
                    } catch {
                        let physicalError = error
                        activatedFinalization = postAuthorityFailureFinalization
                        expectedActionID += 1
                        do {
                            directive = try transaction.report(failureReport(
                                actionID: actionID,
                                error: physicalError
                            ))
                        } catch {
                            if let committed = activatedCommit() { return committed }
                            throw physicalError
                        }
                    }

                case let .committed(receipt, finalization):
                    guard let activatedReceipt, let activatedFinalization else {
                        throw DomainPersistenceError.corruptJournal
                    }
                    guard receiptsMatch(receipt, activatedReceipt),
                          finalization == activatedFinalization
                    else { return commit(activatedReceipt, finalization: activatedFinalization) }
                    return commit(receipt, finalization: finalization)

                case let .failed(failure):
                    if let committed = activatedCommit() { return committed }
                    switch failure {
                    case .cancelled:
                        throw DomainPersistenceError.cancelled
                    case let .stateConflict(expected, actual):
                        throw DomainPersistenceError.stateConflict(
                            expected: expected,
                            actual: actual
                        )
                    case .writeFailed:
                        throw DomainPersistenceError.writeFailed(
                            "workspace_save_transaction_write_failed"
                        )
                    }
                }
            }
        }
    }

    private func persistExternalReloadBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedRevision: UInt64,
        newRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceSavedCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withExistingWorkspaceLocks(
            document: document,
            validator: validator,
            now: now,
            permit: permit
        ) { catalogRevision in
            let snapshot = try readCurrentJournalOrSeed(
                document: document,
                validator: validator
            )
            let operationID = UUID()
            let result = try executeJournalMutationTransaction(
                validator: validator,
                snapshot: snapshot,
                document: document,
                transition: .externalReload(
                    expectedWorkingRevision: expectedRevision,
                    newRevision: newRevision,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: contextTombstones,
                    operations: operations,
                    updatedAt: now
                ),
                catalogRevision: catalogRevision,
                revisionOperationID: operationID,
                now: now,
                diskDocumentBytes: try boundedWorkspaceDocumentBytes(at: document.fileURL)
            )
            let revisionSidecarMissing: Bool = switch result.finalization {
            case .finalized: false
            case .revisionSidecarMissing: true
            }
            return DomainPersistenceSavedCommit(
                journal: result.receipt.committedJournal.journal,
                catalogRevision: result.receipt.catalogRevision,
                revisionSidecarMissing: revisionSidecarMissing
            )
        }
    }

    private func persistConflictRebaseBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        externalSavedDigest: String,
        expectedRevisions: DomainRevisionState,
        newRevisions: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceWorkingCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withExistingWorkspaceLocks(
            document: document,
            validator: validator,
            now: now,
            permit: permit
        ) { catalogRevision in
            let snapshot = try readCurrentJournalOrSeed(
                document: document,
                validator: validator
            )
            let receipt = try executeJournalMutationTransaction(
                validator: validator,
                snapshot: snapshot,
                document: document,
                transition: .conflictRebase(
                    expectedRevisions: expectedRevisions,
                    newRevisions: newRevisions,
                    externalSavedDigest: externalSavedDigest,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: contextTombstones,
                    operations: operations,
                    updatedAt: now
                ),
                catalogRevision: catalogRevision,
                revisionOperationID: nil,
                now: now,
                diskDocumentBytes: try boundedWorkspaceDocumentBytes(at: document.fileURL)
            ).receipt
            return DomainPersistenceWorkingCommit(
                journal: receipt.committedJournal.journal,
                catalogRevision: receipt.catalogRevision
            )
        }
    }

    private func persistDeletedBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        document: DomainWorkspaceDocument,
        expectedWorkspaceRevision: UInt64,
        expectedCatalogRevision: UInt64?,
        operation: DomainRecordedOperation,
        now: Date,
        permit: DomainWorkspaceMutationPermit
    ) throws -> DomainPersistenceDeleteCommit {
        try validateMutationScope(permit, document: document)
        try ensureLazyMigration(now: now, permit: permit, validator: validator)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            try validateMutationScope(permit, document: document)
            let currentCatalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)
            let currentCatalogValidation = currentCatalogSnapshot.validation
            let currentCatalog = currentCatalogValidation.catalog
            let requestedCatalogRevision = expectedCatalogRevision ?? currentCatalog.revision
            return try withLock(at: lockURL(document.workspaceID)) {
                try validateMutationScope(permit, document: document)
                let snapshot = try readCurrentJournalOrSeed(
                    document: document,
                    validator: validator
                )
                let rawCatalogBytes: Data? = switch currentCatalogSnapshot.raw {
                case .absent: nil
                case let .present(_, bytes): bytes
                }
                let transaction = try validator.beginDeleteTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalog: currentCatalogValidation,
                    effectiveJournal: snapshot.effectiveValidation,
                    document: document,
                    expectedWorkingRevision: expectedWorkspaceRevision,
                    expectedCatalogRevision: requestedCatalogRevision,
                    operation: operation,
                    deletedAt: now
                )
                defer { transaction.close() }

                func failureReport(
                    actionID: UInt64,
                    error: Error
                ) -> CoreWorkspaceSaveActionReportV1 {
                    if error is CancellationError || error as? DomainPersistenceError == .cancelled {
                        return .cancelled(actionID: actionID)
                    }
                    if case let DomainPersistenceError.stateConflict(expected, actual) = error {
                        return .stateConflict(
                            actionID: actionID,
                            expected: expected,
                            actual: actual
                        )
                    }
                    return .writeFailed(actionID: actionID)
                }

                var directive = try transaction.nextDirective()
                let receipt: DomainWorkspaceDeleteCommitReceipt
                let catalogDirectorySyncWarning: String?
                deleteTransactionLoop: while true {
                    switch directive {
                    case let .publishCatalog(
                        actionID,
                        expectedRawDigest,
                        catalog,
                        logicalExpectedRevision,
                        authorityReceipt
                    ):
                        let capturedDigest: String? = switch currentCatalogSnapshot.raw {
                        case .absent: nil
                        case let .present(digest, _): digest
                        }
                        guard capturedDigest == expectedRawDigest else {
                            throw DomainPersistenceError.corruptJournal
                        }
                        do {
                            let catalogWriteReceipt = try writeCatalog(
                                expected: currentCatalogSnapshot.raw,
                                candidate: catalog,
                                logicalExpectedRevision: logicalExpectedRevision,
                                validator: validator
                            )
                            catalogDirectorySyncWarning = catalogWriteReceipt.directorySyncWarning
                            // The catalog rename is delete authority. The attached receipt was
                            // prevalidated before the write, so no reporting/runtime failure may
                            // manufacture a failed retry after this point.
                            do {
                                let reported = try transaction.report(.success(
                                    actionID: actionID,
                                    writtenDigest: catalog.contentDigest
                                ))
                                if case let .committed(committedReceipt) = reported {
                                    receipt = committedReceipt
                                } else {
                                    receipt = authorityReceipt
                                }
                            } catch {
                                receipt = authorityReceipt
                            }
                            break deleteTransactionLoop
                        } catch {
                            let physicalError = error
                            do {
                                directive = try transaction.report(failureReport(
                                    actionID: actionID,
                                    error: physicalError
                                ))
                            } catch {
                                throw physicalError
                            }
                            if case .failed = directive { throw physicalError }
                        }
                    case let .committed(committedReceipt):
                        receipt = committedReceipt
                        catalogDirectorySyncWarning = nil
                        break deleteTransactionLoop
                    case let .failed(failure):
                        switch failure {
                        case .cancelled:
                            throw DomainPersistenceError.cancelled
                        case let .stateConflict(expected, actual):
                            throw DomainPersistenceError.stateConflict(
                                expected: expected,
                                actual: actual
                            )
                        case .writeFailed:
                            throw DomainPersistenceError.writeFailed(
                                "workspace_delete_transaction_write_failed"
                            )
                        }
                    }
                }
                let plannedTombstone = receipt.tombstone
                let tombstone = plannedTombstone.tombstone
                let next = receipt.catalog
                var artifactCleanupWarnings = [String]()
                if let catalogDirectorySyncWarning {
                    // Rename established in-process authority, but a crash may expose the old
                    // directory entry. Preserve every workspace artifact until reconciliation can
                    // prove the catalog replacement durable.
                    artifactCleanupWarnings.append(
                        "catalog directory sync indeterminate: \(catalogDirectorySyncWarning)"
                    )
                } else {
                    // The catalog embeds the full tombstone. Its sidecar is a recoverable
                    // convenience and cannot turn an already-authoritative delete into failure.
                    do {
                        try DomainPersistenceLock.atomicWrite(
                            plannedTombstone.canonicalBytes,
                            to: deletionURL(document.workspaceID)
                        )
                    } catch {
                        artifactCleanupWarnings.append("deletion sidecar: \(error.localizedDescription)")
                    }
                    if let warning = removeDeletedArtifact(
                        at: journalURL(document.workspaceID),
                        label: "working journal"
                    ) {
                        artifactCleanupWarnings.append(warning)
                    }
                    if let warning = removeDeletedArtifact(
                        at: revisionURL(document.workspaceID),
                        label: "revision sidecar"
                    ) {
                        artifactCleanupWarnings.append(warning)
                    }
                    if let warning = removeDeletedArtifact(
                        at: document.fileURL,
                        label: "workspace document"
                    ) {
                        artifactCleanupWarnings.append(warning)
                    }
                    artifactCleanupWarnings.append(contentsOf: finalizeDeletedWorkspaceArtifacts(document))
                }

                var recordedTombstone = tombstone
                if !artifactCleanupWarnings.isEmpty {
                    do {
                        let cleanupPlan = try validator.amendDeletionTombstoneCleanup(
                            authoritative: plannedTombstone,
                            cleanupWarnings: artifactCleanupWarnings
                        )
                        recordedTombstone = cleanupPlan.tombstone
                        if catalogDirectorySyncWarning == nil {
                            do {
                                try DomainPersistenceLock.atomicWrite(
                                    cleanupPlan.canonicalBytes,
                                    to: deletionURL(document.workspaceID)
                                )
                            } catch {
                                artifactCleanupWarnings.append(
                                    "cleanup status sidecar: \(error.localizedDescription)"
                                )
                                if let amendedPlan = try? validator.amendDeletionTombstoneCleanup(
                                    authoritative: plannedTombstone,
                                    cleanupWarnings: artifactCleanupWarnings
                                ) {
                                    recordedTombstone = amendedPlan.tombstone
                                }
                            }
                        }
                    } catch {
                        artifactCleanupWarnings.append(
                            "cleanup status planning: \(error.localizedDescription)"
                        )
                    }
                }
                return DomainPersistenceDeleteCommit(
                    catalogRevision: next.catalog.revision,
                    tombstone: recordedTombstone,
                    artifactCleanupWarnings: artifactCleanupWarnings
                )
            }
        }
    }

    private func finalizeDeletedWorkspaceArtifacts(_ document: DomainWorkspaceDocument) -> [String] {
        let fileURL = document.fileURL.standardizedFileURL
        guard fileURL.lastPathComponent == "workspace.json" else { return [] }
        let workspaceDirectory = fileURL.deletingLastPathComponent()
        if document.metadata.customStoragePath != nil {
            return removeDeletedArtifact(
                at: workspaceDirectory.appendingPathComponent("_git_data", isDirectory: true),
                label: "workspace git-data directory"
            ).map { [$0] } ?? []
        }

        let expectedParent = workspaceRoot.standardizedFileURL
        let identitySuffix = "-\(document.workspaceID.uuidString)"
        guard workspaceDirectory.deletingLastPathComponent().standardizedFileURL == expectedParent,
              workspaceDirectory.lastPathComponent.hasSuffix(identitySuffix)
        else { return [] }
        return removeDeletedArtifact(
            at: workspaceDirectory,
            label: "workspace artifact directory"
        ).map { [$0] } ?? []
    }

    private func removeDeletedArtifact(at url: URL, label: String) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try fileManager.removeItem(at: url)
            return nil
        } catch {
            return "\(label): \(error.localizedDescription)"
        }
    }

    private func externalDocumentBlocking(
        for snapshot: DomainWorkspaceSnapshot,
        savedDigest: String,
        knownMetadata: DomainFileMetadata
    ) -> DomainExternalDocumentProbe {
        let observedMetadata = fileMetadata(at: snapshot.document.fileURL)
        guard observedMetadata != knownMetadata else {
            return .unchanged(observedMetadata)
        }
        guard observedMetadata.exists else {
            return .missing(observedMetadata)
        }
        do {
            let bytes = try Data(contentsOf: snapshot.document.fileURL)
            let digest = DomainContentDigest.sha256(bytes)
            guard digest != savedDigest else { return .unchanged(observedMetadata) }
            let document = try DomainWorkspaceDocument.decode(
                documentBytes: bytes,
                fileURL: snapshot.document.fileURL
            )
            guard document.workspaceID == snapshot.document.workspaceID else {
                return .invalid(observedMetadata)
            }
            return .changed(document, observedMetadata)
        } catch {
            return .invalid(observedMetadata)
        }
    }

    private func fileMetadata(at url: URL) -> DomainFileMetadata {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let modificationNanoseconds = Int64(
            (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
        )
        return DomainFileMetadata(
            exists: true,
            byteCount: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationNanoseconds: modificationNanoseconds,
            fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        )
    }

    private func boundedWorkspaceDocumentBytes(at url: URL) throws -> Data? {
        let maximumBytes = CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw DomainPersistenceError.writeFailed("workspace_document_read_failed")
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes)
        else {
            throw DomainPersistenceError.writeFailed("workspace_document_too_large")
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw DomainPersistenceError.writeFailed("workspace_document_read_failed")
            }
            guard count > 0 else { break }
            guard bytes.count <= maximumBytes - count else {
                throw DomainPersistenceError.writeFailed("workspace_document_too_large")
            }
            bytes.append(contentsOf: buffer[0 ..< count])
        }
        return bytes
    }

    private func resolvedPendingSave(
        _ validation: DomainWorkspaceWorkingJournalValidation,
        expectedWorkspaceID: UUID,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> (validation: DomainWorkspaceWorkingJournalValidation, document: DomainWorkspaceDocument)? {
        let journal = validation.journal
        guard journal.workspaceID == expectedWorkspaceID else {
            throw DomainPersistenceError.corruptJournal
        }
        let savedBytes = try boundedWorkspaceDocumentBytes(at: journal.fileURL)
        switch try validator.resolvePendingSave(
            rawJournalBytes: validation.canonicalBytes,
            expectedWorkspaceID: expectedWorkspaceID,
            expectedFileURL: journal.fileURL,
            documentBytes: savedBytes
        ) {
        case .noPending, .pendingNotCommitted:
            return nil
        case let .committed(cleanJournal, documentDigest):
            guard let savedBytes,
                  DomainContentDigest.sha256(savedBytes) == documentDigest,
                  let document = decodeWorkspaceDocument(
                      savedBytes,
                      fileURL: journal.fileURL,
                      expectedWorkspaceID: expectedWorkspaceID
                  )
            else { throw DomainPersistenceError.corruptJournal }
            return (cleanJournal, document)
        }
    }

    private func readRawJournalSnapshot(
        workspaceID: UUID,
        allowsCancellation: Bool = true
    ) throws -> RawJournalSnapshot {
        let url = journalURL(workspaceID)
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .absent }
            throw DomainPersistenceError.writeFailed("working_journal_read_failed")
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes)
        else {
            throw DomainPersistenceError.writeFailed("working_journal_too_large")
        }

        var bytes = Data()
        bytes.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if allowsCancellation {
                try cancellation?.check()
            }
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw DomainPersistenceError.writeFailed("working_journal_read_failed")
            }
            guard count > 0 else { break }
            guard bytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes - count else {
                throw DomainPersistenceError.writeFailed("working_journal_too_large")
            }
            bytes.append(contentsOf: buffer[0 ..< count])
        }
        return .present(digest: DomainContentDigest.sha256(bytes), bytes: bytes)
    }

    private func loadJournal(
        workspaceID: UUID,
        expectedFileURL: URL? = nil,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) -> Result<DomainWorkspaceWorkingJournalValidation?, Error> {
        do {
            switch try readRawJournalSnapshot(workspaceID: workspaceID) {
            case .absent:
                return .success(nil)
            case let .present(_, bytes):
                let validation = try validator.validateSynchronously(
                    bytes,
                    expectedWorkspaceID: workspaceID,
                    expectedFileURL: expectedFileURL
                )
                return .success(validation)
            }
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    private func replaceJournal(
        expected: RawJournalSnapshot,
        candidate: PreparedJournalCandidate,
        logicalExpectedRevision: UInt64,
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        allowsCancellation: Bool = true
    ) throws -> RawJournalSnapshot {
        let current = try readRawJournalSnapshot(
            workspaceID: candidate.journal.workspaceID,
            allowsCancellation: allowsCancellation
        )
        let matches = switch (expected, current) {
        case (.absent, .absent):
            true
        case let (.present(expectedDigest, _), .present(currentDigest, _)):
            expectedDigest == currentDigest
        default:
            false
        }
        guard matches else {
            let actualRevision: UInt64
            switch current {
            case .absent:
                actualRevision = 0
            case let .present(_, bytes):
                actualRevision = try validator.validateSynchronously(
                    bytes,
                    expectedWorkspaceID: candidate.journal.workspaceID,
                    expectedFileURL: candidate.journal.fileURL
                ).journal.revisions.workingRevision
            }
            throw DomainPersistenceError.stateConflict(
                expected: logicalExpectedRevision,
                actual: actualRevision
            )
        }
        try DomainPersistenceLock.atomicWrite(
            candidate.canonicalBytes,
            to: journalURL(candidate.journal.workspaceID)
        )
        return .present(digest: candidate.contentDigest, bytes: candidate.canonicalBytes)
    }

    private func readSavedRevisionSnapshot(workspaceID: UUID) throws -> OptionalMetadataSnapshot {
        try readOptionalMetadataSnapshot(at: revisionURL(workspaceID))
    }

    private func readOptionalMetadataSnapshot(at url: URL) throws -> OptionalMetadataSnapshot {
        let maximumBytes = CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return .absent }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0
        else { return .absent }
        guard UInt64(metadata.st_size) <= UInt64(maximumBytes) else { return .oversized }

        var bytes = Data()
        bytes.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                return .absent
            }
            guard count > 0 else { break }
            guard bytes.count <= maximumBytes - count else { return .oversized }
            bytes.append(contentsOf: buffer[0 ..< count])
        }
        return .present(bytes)
    }

    private func loadSavedRevision(
        workspaceID: UUID,
        digest: String,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> DomainRevisionState {
        let bytes: Data
        switch try readSavedRevisionSnapshot(workspaceID: workspaceID) {
        case .absent:
            return .initial
        case .oversized:
            // Preserve optional-sidecar recovery only after proving the exact prepared runtime is
            // still live. A stopped/replaced Rust authority must fail closed even though Swift can
            // reject this artifact by size without dispatching its bytes.
            try validator.requireRuntimeAvailability()
            return .initial
        case let .present(value):
            bytes = value
        }
        do {
            let validation = try validator.validateSavedRevision(
                bytes,
                expectedWorkspaceID: workspaceID,
                expectedDocumentDigest: digest
            )
            return DomainRevisionState(
                workingRevision: validation.record.savedRevision,
                savedRevision: validation.record.savedRevision,
                dirtyRevision: nil
            )
        } catch let error as DomainPersistenceError {
            if error == .writeFailed("working_journal_rust_unavailable") {
                throw error
            }
            // A missing, stale, future, oversized, or malformed optional revision sidecar has
            // always seeded revision zero. Rust now owns that semantic verdict; Swift preserves
            // the existing recovery behavior without decoding or interpreting the record.
            return .initial
        }
    }

    private func readCurrentJournalOrSeed(
        document: DomainWorkspaceDocument,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> ValidatedJournalSnapshot {
        let raw = try readRawJournalSnapshot(workspaceID: document.workspaceID)
        switch raw {
        case .absent:
            let savedBytes = try boundedWorkspaceDocumentBytes(at: document.fileURL)
                ?? document.documentBytes
            let savedDigest = DomainContentDigest.sha256(savedBytes)
            let revisions = try loadSavedRevision(
                workspaceID: document.workspaceID,
                digest: savedDigest,
                validator: validator
            )
            let validation = try validator.seedWorkingJournal(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                revisions: revisions,
                savedDigest: savedDigest,
                contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                    ($0.identity.contextID, $0.contentDigest)
                }),
                updatedAt: identity.createdAt
            )
            return ValidatedJournalSnapshot(
                raw: raw,
                effectiveJournal: validation.journal,
                effectiveValidation: validation
            )
        case let .present(_, bytes):
            let stored = try validator.validateSynchronously(
                bytes,
                expectedWorkspaceID: document.workspaceID,
                expectedFileURL: document.fileURL
            )
            let recovered = try resolvedPendingSave(
                stored,
                expectedWorkspaceID: document.workspaceID,
                validator: validator
            )?.validation
            let effective = recovered ?? stored
            return ValidatedJournalSnapshot(
                raw: raw,
                effectiveJournal: effective.journal,
                effectiveValidation: effective
            )
        }
    }

    private func withExistingWorkspaceLocks<T>(
        document: DomainWorkspaceDocument,
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        now: Date,
        permit: DomainWorkspaceMutationPermit,
        _ body: (UInt64) throws -> T
    ) throws -> T {
        try validateMutationScope(permit, document: document)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            try validateMutationScope(permit, document: document)
            let catalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)
            let catalogValidation = catalogSnapshot.validation
            let catalog = catalogValidation.catalog
            return try withLock(at: lockURL(document.workspaceID)) {
                try validateMutationScope(permit, document: document)
                if let entry = catalog.entries.first(where: {
                    $0.workspaceID == document.workspaceID
                }) {
                    guard entry.fileURL.standardizedFileURL == document.fileURL.standardizedFileURL else {
                        throw DomainPersistenceError.stateConflict(
                            expected: catalog.revision,
                            actual: catalog.revision &+ 1
                        )
                    }
                    return try body(catalog.revision)
                }

                // A process may die after the create intent/document commit but before catalog
                // publication. Only that runtime-owned create marker may complete identity here;
                // an ordinary stale writer can never recreate a deleted/missing catalog entry.
                guard let diskDocumentBytes = try boundedWorkspaceDocumentBytes(at: document.fileURL),
                      diskDocumentBytes == document.documentBytes,
                      let diskDocument = try? DomainWorkspaceDocument.decode(
                          documentBytes: diskDocumentBytes,
                          fileURL: document.fileURL
                      ),
                      diskDocument.workspaceID == document.workspaceID
                else {
                    throw DomainPersistenceError.stateConflict(
                        expected: catalog.revision,
                        actual: catalog.revision &+ 1
                    )
                }
                let recovered = try readCurrentJournalOrSeed(
                    document: diskDocument,
                    validator: validator
                )
                guard case let .present(_, rawJournalBytes) = recovered.raw else {
                    throw DomainPersistenceError.stateConflict(
                        expected: catalog.revision,
                        actual: catalog.revision &+ 1
                    )
                }
                let rawCatalogBytes: Data? = switch catalogSnapshot.raw {
                case .absent: nil
                case let .present(_, bytes): bytes
                }
                let transaction = try validator.beginCreateRecoveryTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalog: catalogValidation,
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournal: recovered.effectiveValidation,
                    document: diskDocument,
                    updatedAt: now
                )
                defer { transaction.close() }
                let directive = try transaction.nextDirective()
                let receipt: DomainWorkspaceCreateCommitReceipt
                switch directive {
                case let .publishCatalog(
                    actionID,
                    expectedRawDigest,
                    candidate,
                    logicalExpectedRevision,
                    attachedReceipt
                ):
                    guard catalogSnapshot.raw.digest == expectedRawDigest else {
                        throw DomainPersistenceError.corruptJournal
                    }
                    do {
                        let authorityPermit = try transaction.acquireAuthorityPermit()
                        defer { authorityPermit.close() }
                        _ = try writeCatalog(
                            expected: catalogSnapshot.raw,
                            candidate: candidate,
                            logicalExpectedRevision: logicalExpectedRevision,
                            validator: validator
                        )
                    } catch {
                        let physicalError = error
                        let report: CoreWorkspaceSaveActionReportV1
                        if case let DomainPersistenceError.stateConflict(expected, actual) = error {
                            report = .stateConflict(
                                actionID: actionID,
                                expected: expected,
                                actual: actual
                            )
                        } else if error is CancellationError
                            || error as? DomainPersistenceError == .cancelled
                        {
                            report = .cancelled(actionID: actionID)
                        } else {
                            report = .writeFailed(actionID: actionID)
                        }
                        _ = try? transaction.report(report)
                        throw physicalError
                    }
                    do {
                        let reported = try transaction.report(.success(
                            actionID: actionID,
                            writtenDigest: candidate.contentDigest
                        ))
                        if case let .committed(committed) = reported {
                            receipt = committed
                        } else {
                            receipt = attachedReceipt
                        }
                    } catch {
                        // The catalog rename is create authority. The attached receipt was fully
                        // validated before I/O, so runtime loss after rename cannot manufacture a
                        // false failed retry.
                        receipt = attachedReceipt
                    }
                case let .committed(committed):
                    receipt = committed
                case let .failed(failure):
                    switch failure {
                    case .cancelled:
                        throw DomainPersistenceError.cancelled
                    case let .stateConflict(expected, actual):
                        throw DomainPersistenceError.stateConflict(
                            expected: expected,
                            actual: actual
                        )
                    case .writeFailed:
                        throw DomainPersistenceError.writeFailed(
                            "workspace_create_recovery_transaction_write_failed"
                        )
                    }
                case .writePendingJournal,
                     .publishWorkspaceDocument,
                     .writeCommittedJournal,
                     .writeSavedRevision,
                     .removeDeletionSidecar:
                    throw DomainPersistenceError.corruptJournal
                }
                return try body(receipt.catalog.catalog.revision)
            }
        }
    }

    private func readCatalogBytes() throws -> Data? {
        let descriptor: Int32 = catalogURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw DomainPersistenceError.writeFailed("workspace_catalog_read_failed_\(errno)")
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0
        else {
            throw DomainPersistenceError.writeFailed("workspace_catalog_read_failed_\(errno)")
        }
        guard UInt64(metadata.st_size) <= UInt64(Self.maximumWorkspaceCatalogBytes) else {
            throw DomainPersistenceError.writeFailed("workspace_catalog_too_large")
        }

        var bytes = Data()
        bytes.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw DomainPersistenceError.writeFailed("workspace_catalog_read_failed_\(errno)")
            }
            guard count > 0 else { break }
            guard bytes.count <= Self.maximumWorkspaceCatalogBytes - count else {
                throw DomainPersistenceError.writeFailed("workspace_catalog_too_large")
            }
            bytes.append(contentsOf: buffer[0 ..< count])
        }
        return bytes
    }

    private func loadCurrentCatalog(
        now: Date,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> ValidatedCatalogSnapshot {
        if let bytes = try readCatalogBytes() {
            return ValidatedCatalogSnapshot(
                raw: .present(
                    digest: DomainContentDigest.sha256(bytes),
                    bytes: bytes
                ),
                validation: try validator.validateCatalog(bytes)
            )
        }
        return ValidatedCatalogSnapshot(
            raw: .absent,
            validation: try validator.seedCatalog(
                entries: legacyCatalogEntries(),
                updatedAt: now
            )
        )
    }

    @discardableResult
    private func writeCatalog(
        expected: RawCatalogSnapshot,
        candidate: DomainWorkspaceCatalogValidation,
        logicalExpectedRevision: UInt64,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> CatalogWriteReceipt {
        #if DEBUG
            let directorySyncTestHook = Self.takeCatalogDirectorySyncTestHook(for: catalogURL)
        #else
            let directorySyncTestHook: (@Sendable () throws -> Void)? = nil
        #endif
        let writeReceipt = try DomainPersistenceLock.atomicWrite(
            candidate.canonicalBytes,
            to: catalogURL,
            validateBeforeReplace: {
                #if DEBUG
                    try Self.takeCatalogReplacementTestHook(for: catalogURL)?()
                #endif
                let currentBytes = try readCatalogBytes()
                let current: RawCatalogSnapshot = if let currentBytes {
                    .present(
                        digest: DomainContentDigest.sha256(currentBytes),
                        bytes: currentBytes
                    )
                } else {
                    .absent
                }
                let matches = switch (expected, current) {
                case (.absent, .absent):
                    true
                case let (.present(expectedDigest, _), .present(currentDigest, _)):
                    expectedDigest == currentDigest
                default:
                    false
                }
                guard matches else {
                    let actualRevision: UInt64 = switch current {
                    case .absent:
                        0
                    case let .present(_, bytes):
                        try validator.validateCatalog(bytes).catalog.revision
                    }
                    throw DomainPersistenceError.stateConflict(
                        expected: logicalExpectedRevision,
                        actual: actualRevision
                    )
                }
            },
            beforeDirectorySync: directorySyncTestHook
        )
        return CatalogWriteReceipt(
            raw: .present(
                digest: candidate.contentDigest,
                bytes: candidate.canonicalBytes
            ),
            directorySyncWarning: writeReceipt.directorySyncWarning
        )
    }

    private func ensureLazyMigration(
        now: Date,
        permit: DomainWorkspaceMutationPermit,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws {
        try validateMutationPermitScope(permit)
        guard !fileManager.fileExists(atPath: policyURL.path) else { return }
        try withLock(at: lockDirectory.appendingPathComponent("runtime-policy.lock")) {
            try validateMutationPermitScope(permit)
            guard !fileManager.fileExists(atPath: policyURL.path) else { return }
            let rollbackName = "migration-\(Int(now.timeIntervalSince1970))-\(identity.runtimeID.uuidString)"
            let rollbackDirectory = rollbackRoot.appendingPathComponent(rollbackName, isDirectory: true)
            var artifacts: [RollbackManifest.Artifact] = []
            if let indexBytes = try? Data(contentsOf: indexURL) {
                let destination = rollbackDirectory.appendingPathComponent("workspacesIndex.json")
                try DomainPersistenceLock.atomicWrite(indexBytes, to: destination)
                artifacts.append(.init(relativePath: "workspacesIndex.json", digest: DomainContentDigest.sha256(indexBytes)))
            }
            for entry in (try? decoder.decode([LegacyWorkspaceIndexEntry].self, from: Data(contentsOf: indexURL))) ?? [] {
                let url = entry.customStoragePath?.appendingPathComponent("workspace.json")
                    ?? workspaceRoot
                    .appendingPathComponent(
                        DomainWorkspaceStoragePath.directoryName(name: entry.name, id: entry.id),
                        isDirectory: true
                    )
                    .appendingPathComponent("workspace.json")
                guard let bytes = try? Data(contentsOf: url) else { continue }
                let relative = "workspaces/\(entry.id.uuidString).json"
                try DomainPersistenceLock.atomicWrite(bytes, to: rollbackDirectory.appendingPathComponent(relative))
                artifacts.append(.init(relativePath: relative, digest: DomainContentDigest.sha256(bytes)))
            }
            try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
                try validateMutationPermitScope(permit)
                if !fileManager.fileExists(atPath: catalogURL.path) {
                    let catalogSnapshot = try loadCurrentCatalog(now: now, validator: validator)
                    switch catalogSnapshot.raw {
                    case .absent:
                        _ = try writeCatalog(
                            expected: catalogSnapshot.raw,
                            candidate: catalogSnapshot.validation,
                            logicalExpectedRevision: 0,
                            validator: validator
                        )
                    case .present:
                        break
                    }
                }
            }
            if !configuration.legacyRuntimeDefaults.isEmpty {
                let defaultsURL = rollbackDirectory.appendingPathComponent("legacy-runtime-defaults.json")
                let defaultsBytes = try encoder.encode(configuration.legacyRuntimeDefaults)
                try DomainPersistenceLock.atomicWrite(defaultsBytes, to: defaultsURL)
                artifacts.append(.init(
                    relativePath: "legacy-runtime-defaults.json",
                    digest: DomainContentDigest.sha256(defaultsBytes)
                ))
            }
            let manifest = RollbackManifest(
                version: RollbackManifest.schemaVersion,
                profileIdentifier: configuration.profileIdentifier,
                runtimeID: identity.runtimeID,
                runtimeGeneration: identity.lifecycleGeneration,
                createdAt: now,
                artifacts: artifacts,
                legacyDefaultKeys: configuration.legacyRuntimeDefaults.keys.sorted()
            )
            try DomainPersistenceLock.atomicWrite(
                encoder.encode(manifest),
                to: rollbackDirectory.appendingPathComponent("manifest.json")
            )
            let policy = RuntimePolicyDocument(
                version: RuntimePolicyDocument.schemaVersion,
                profileIdentifier: configuration.profileIdentifier,
                legacyDefaultsPreserved: true,
                rollbackDirectoryName: rollbackName,
                migratedAt: now
            )
            try DomainPersistenceLock.atomicWrite(encoder.encode(policy), to: policyURL)
        }
    }
}

private struct DomainPersistenceAtomicWriteReceipt {
    let directorySyncWarning: String?
}

private enum DomainPersistenceLock {
    private static let waitTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let retryDelayMicroseconds: useconds_t = 10000

    static func withLock<T>(
        at url: URL,
        cancellation: DomainBlockingCancellation?,
        _ body: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainPersistenceError.writeFailed("lock_open_failed_\(errno)")
        }
        defer { close(descriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ waitTimeoutNanoseconds
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw DomainPersistenceError.writeFailed("lock_acquire_failed_\(errno)")
            }
            try cancellation?.check()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw DomainPersistenceError.lockTimedOut
            }
            usleep(retryDelayMicroseconds)
        }
        defer { flock(descriptor, LOCK_UN) }
        try cancellation?.check()
        return try body()
    }

    @discardableResult
    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        validateBeforeReplace: (() throws -> Void)? = nil,
        beforeDirectorySync: (@Sendable () throws -> Void)? = nil
    ) throws -> DomainPersistenceAtomicWriteReceipt {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DomainPersistenceError.writeFailed("temp_open_failed_\(errno)")
        }
        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    guard count > 0 else {
                        throw DomainPersistenceError.writeFailed("write_failed_\(errno)")
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DomainPersistenceError.writeFailed("fsync_failed_\(errno)")
            }
            close(descriptor)
            descriptorIsOpen = false
            try validateBeforeReplace?()
            guard rename(temporary.path, destination.path) == 0 else {
                throw DomainPersistenceError.writeFailed("rename_failed_\(errno)")
            }
            let directorySyncWarning: String?
            do {
                try beforeDirectorySync?()
                let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
                guard directoryDescriptor >= 0 else {
                    throw DomainPersistenceError.writeFailed("directory_open_failed_\(errno)")
                }
                defer { close(directoryDescriptor) }
                guard fsync(directoryDescriptor) == 0 else {
                    throw DomainPersistenceError.writeFailed("directory_fsync_failed_\(errno)")
                }
                directorySyncWarning = nil
            } catch {
                directorySyncWarning = error.localizedDescription
            }
            return DomainPersistenceAtomicWriteReceipt(
                directorySyncWarning: directorySyncWarning
            )
        } catch {
            if descriptorIsOpen {
                close(descriptor)
            }
            unlink(temporary.path)
            throw error
        }
    }
}

enum DomainPersistenceAtomicWriter {
    static func write(_ data: Data, to destination: URL) throws {
        try DomainPersistenceLock.atomicWrite(data, to: destination)
    }
}
