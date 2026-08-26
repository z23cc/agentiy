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

    private struct RuntimeWorkspaceCatalog: Codable {
        static let schemaVersion = 1

        struct Entry: Codable, Equatable {
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
    }

    private enum OptionalMetadataSnapshot: Sendable {
        case absent
        case present(Data)
        case oversized
    }

    private struct ValidatedJournalSnapshot: Sendable {
        let raw: RawJournalSnapshot
        let effectiveJournal: DomainWorkingJournal
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

    func bootstrap() async -> DomainPersistenceBootstrap {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).bootstrapBlocking(validator: validator)
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
        try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard worker.fileManager.fileExists(atPath: worker.catalogURL.path) else { return nil }
            let data = try Data(contentsOf: worker.catalogURL)
            let catalog = try worker.decoder.decode(RuntimeWorkspaceCatalog.self, from: data)
            guard catalog.version <= RuntimeWorkspaceCatalog.schemaVersion else {
                throw DomainPersistenceError.futureJournal(catalog.version)
            }
            return catalog.revision
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
        guard let catalogData = try? Data(contentsOf: catalogURL) else {
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
        guard let catalog = try? decoder.decode(RuntimeWorkspaceCatalog.self, from: catalogData) else {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                workspaceIsDeleted: false,
                health: .degradedReadOnly(reason: "workspace_catalog_decode_failed"),
                catalogRevision: 0
            )
        }
        guard catalog.version <= RuntimeWorkspaceCatalog.schemaVersion else {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                workspaceIsDeleted: false,
                health: .degradedReadOnly(reason: "future_workspace_catalog"),
                catalogRevision: catalog.revision
            )
        }
        let isDeleted = (catalog.deletions ?? []).contains { $0.workspaceID == workspaceID }
        let matchingEntries = catalog.entries.filter { $0.workspaceID == workspaceID }
        guard matchingEntries.count <= 1 else {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                workspaceIsDeleted: isDeleted,
                health: .degradedReadOnly(reason: "duplicate_workspace_catalog_id"),
                catalogRevision: catalog.revision
            )
        }
        let fileURL = matchingEntries.first?.fileURL ?? fallbackFileURL
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
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> DomainPersistenceBootstrap {
        var globalHealth: DomainAuthorityHealth = .writable
        let catalog: RuntimeWorkspaceCatalog?
        if let data = try? Data(contentsOf: catalogURL) {
            do {
                let decoded = try decoder.decode(RuntimeWorkspaceCatalog.self, from: data)
                if decoded.version <= RuntimeWorkspaceCatalog.schemaVersion {
                    catalog = decoded
                } else {
                    catalog = nil
                    globalHealth = .degradedReadOnly(reason: "future_workspace_catalog")
                }
            } catch {
                catalog = nil
                globalHealth = .degradedReadOnly(reason: "workspace_catalog_decode_failed")
            }
        } else {
            catalog = nil
        }

        let deletionURLs = (try? fileManager.contentsOfDirectory(
            at: deletionDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let sidecarTombstones = deletionURLs.compactMap { url -> DomainDeletionTombstone? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let tombstone = try? decoder.decode(DomainDeletionTombstone.self, from: data),
                  tombstone.version <= DomainDeletionTombstone.schemaVersion
            else { return nil }
            return tombstone
        }
        // The catalog remains deletion authority. When both records exist, prefer the
        // sidecar's operation outcome because cleanup status is recorded there after the
        // authoritative catalog tombstone is committed.
        let deletionTombstones = Dictionary(
            ((catalog?.deletions ?? []) + sidecarTombstones).map { ($0.workspaceID, $0) },
            uniquingKeysWith: { _, latest in latest }
        ).values.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
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

        // A crash between an atomic journal commit and catalog publication is recovered by
        // scanning only the bounded runtime-owned journal directory.
        let journalURLs = (try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for journalURL in journalURLs where journalURL.pathExtension == "json" {
            guard let workspaceID = UUID(uuidString: journalURL.deletingPathExtension().lastPathComponent),
                  !loadedIDs.contains(workspaceID),
                  !deletedIDs.contains(workspaceID)
            else { continue }
            switch loadJournal(workspaceID: workspaceID, validator: validator) {
            case let .success(journal?):
                if let result = try loadWorkspace(
                    workspaceID: workspaceID,
                    fileURL: journal.fileURL,
                    validator: validator
                ) {
                    loaded.append(result.workspace)
                } else {
                    unavailable.append(.init(
                        workspaceID: workspaceID,
                        fileURL: journal.fileURL,
                        reason: "workspace_document_unavailable",
                        fileMetadata: fileMetadata(at: journal.fileURL)
                    ))
                }
                loadedIDs.insert(workspaceID)
            case .success(nil):
                continue
            case let .failure(error):
                if isJournalInfrastructureFailure(error) {
                    throw error
                }
                let reason = journalDegradedReason(error)
                globalHealth = .degradedReadOnly(reason: reason)
                unavailable.append(.init(
                    workspaceID: workspaceID,
                    fileURL: journalURL,
                    reason: reason,
                    fileMetadata: fileMetadata(at: journalURL)
                ))
                loadedIDs.insert(workspaceID)
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
        case let .success(journal?):
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
                    journal,
                    expectedWorkspaceID: workspaceID,
                    validator: validator
                ) {
                    return (.init(
                        document: recovered.document,
                        savedDigest: recovered.journal.savedDigest,
                        revisions: recovered.journal.revisions,
                        contextRevisions: recovered.journal.contextRevisions,
                        contextTombstones: recovered.journal.contextTombstones,
                        operations: recovered.journal.operations,
                        health: .writable,
                        fileMetadata: trustedMetadata(matching: recovered.journal.savedDigest)
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
        try ensureLazyMigration(now: now, permit: permit)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            try validateMutationScope(permit, document: document)
            let currentCatalog = try loadCurrentCatalog(now: now)
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

            let journal = try withLock(at: lockURL(document.workspaceID)) {
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
                let plan = try planJournalTransition(
                    current: nil,
                    transition: .create(
                        workspaceID: document.workspaceID,
                        fileURL: document.fileURL,
                        contextRevisions: contextRevisions,
                        contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                            ($0.identity.contextID, $0.contentDigest)
                        }),
                        operation: operation,
                        operationID: operationID,
                        updatedAt: now
                    ),
                    documentBytes: document.documentBytes,
                    validator: validator
                )
                let pending = plan.primary
                guard let committed = plan.committed else {
                    throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
                }
                let savedRevision = try validator.planSavedRevision(
                    workspaceID: document.workspaceID,
                    savedRevision: committed.journal.revisions.savedRevision,
                    documentDigest: document.contentDigest,
                    operationID: operationID,
                    updatedAt: now
                )
                let pendingRaw = try replaceJournal(
                    expected: originalRaw,
                    candidate: pending,
                    logicalExpectedRevision: 0,
                    validator: validator
                )
                try DomainPersistenceLock.atomicWrite(document.documentBytes, to: document.fileURL)
                _ = try replaceJournal(
                    expected: pendingRaw,
                    candidate: committed,
                    logicalExpectedRevision: pending.journal.revisions.workingRevision,
                    validator: validator,
                    allowsCancellation: false
                )
                try DomainPersistenceLock.atomicWrite(
                    savedRevision.canonicalBytes,
                    to: revisionURL(document.workspaceID)
                )
                return committed.journal
            }

            var entries = currentCatalog.entries.filter {
                $0.workspaceID != document.workspaceID
            }
            entries.append(.init(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL
            ))
            let nextCatalog = RuntimeWorkspaceCatalog(
                version: RuntimeWorkspaceCatalog.schemaVersion,
                revision: currentCatalog.revision &+ 1,
                entries: entries.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString },
                deletions: (currentCatalog.deletions ?? []).filter {
                    $0.workspaceID != document.workspaceID
                },
                updatedAt: now
            )
            do {
                let priorDeletionURL = deletionURL(document.workspaceID)
                if fileManager.fileExists(atPath: priorDeletionURL.path) {
                    // Remove the crash-recovery sidecar before publishing recreated identity. If
                    // catalog publication then fails, the still-authoritative catalog tombstone
                    // continues to suppress the workspace; a stale sidecar can never suppress a
                    // successfully recreated identity on the next launch.
                    try fileManager.removeItem(at: priorDeletionURL)
                }
                try DomainPersistenceLock.atomicWrite(encoder.encode(nextCatalog), to: catalogURL)
            } catch {
                // Catalog publication is the create authority point. Roll back the earlier
                // intent/document artifacts when publication fails in-process; a process crash
                // is instead recovered from the create-marked journal on the next mutation.
                try? fileManager.removeItem(at: journalURL(document.workspaceID))
                try? fileManager.removeItem(at: revisionURL(document.workspaceID))
                try? fileManager.removeItem(at: document.fileURL)
                throw error
            }
            return DomainPersistenceSavedCommit(
                journal: journal,
                catalogRevision: nextCatalog.revision
            )
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
        try ensureLazyMigration(now: now, permit: permit)
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
            let durable = snapshot.effectiveJournal
            guard durable.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            let plan = try planJournalTransition(
                current: durable,
                transition: .unchanged(
                    expectedWorkingRevision: expectedRevision,
                    operation: operation,
                    updatedAt: now
                ),
                validator: validator
            )
            guard plan.committed == nil else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            let candidate = plan.primary
            _ = try replaceJournal(
                expected: snapshot.raw,
                candidate: candidate,
                logicalExpectedRevision: expectedRevision,
                validator: validator
            )
            return DomainPersistenceWorkingCommit(
                journal: candidate.journal,
                catalogRevision: catalogRevision
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
        try ensureLazyMigration(now: now, permit: permit)
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
            let durable = snapshot.effectiveJournal
            guard durable.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            let plan = try planJournalTransition(
                current: durable,
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
                documentBytes: document.documentBytes,
                validator: validator
            )
            guard plan.committed == nil else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            let candidate = plan.primary
            _ = try replaceJournal(
                expected: snapshot.raw,
                candidate: candidate,
                logicalExpectedRevision: expectedRevision,
                validator: validator
            )
            return DomainPersistenceWorkingCommit(
                journal: candidate.journal,
                catalogRevision: catalogRevision
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
        try ensureLazyMigration(now: now, permit: permit)
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
            let durable = snapshot.effectiveJournal
            guard durable.revisions.workingRevision == expectedWorkingRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedWorkingRevision,
                    actual: durable.revisions.workingRevision
                )
            }
            if let diskBytes = try? Data(contentsOf: document.fileURL) {
                let diskDigest = DomainContentDigest.sha256(diskBytes)
                guard diskDigest == durable.savedDigest || diskDigest == document.contentDigest else {
                    throw DomainPersistenceError.externalDocumentConflict
                }
            }
            let plan = try planJournalTransition(
                current: durable,
                transition: .save(
                    expectedWorkingRevision: expectedWorkingRevision,
                    operationID: operationID,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: contextTombstones,
                    operations: operations,
                    updatedAt: now
                ),
                documentBytes: document.documentBytes,
                validator: validator
            )
            let pending = plan.primary
            guard let committed = plan.committed else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            let revision = try validator.planSavedRevision(
                workspaceID: document.workspaceID,
                savedRevision: committed.journal.revisions.savedRevision,
                documentDigest: document.contentDigest,
                operationID: operationID,
                updatedAt: now
            )
            let pendingRaw = try replaceJournal(
                expected: snapshot.raw,
                candidate: pending,
                logicalExpectedRevision: expectedWorkingRevision,
                validator: validator
            )
            try DomainPersistenceLock.atomicWrite(document.documentBytes, to: document.fileURL)
            // The saved document is the authority point. Final sidecars are recoverable from
            // the pending journal plus document digest, so a post-document sidecar failure must
            // not report a false failed commit to a retrying caller.
            do {
                _ = try replaceJournal(
                    expected: pendingRaw,
                    candidate: committed,
                    logicalExpectedRevision: expectedWorkingRevision,
                    validator: validator
                )
                try DomainPersistenceLock.atomicWrite(
                    revision.canonicalBytes,
                    to: revisionURL(document.workspaceID)
                )
            } catch {
                // Leave the durable pending journal in place. resolvedPendingSave(_:) presents
                // and persists the same clean revision on the next load/mutation.
            }
            return DomainPersistenceSavedCommit(
                journal: committed.journal,
                catalogRevision: catalogRevision
            )
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
        try ensureLazyMigration(now: now, permit: permit)
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
            let current = snapshot.effectiveJournal
            guard current.revisions.workingRevision == expectedRevision else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevision,
                    actual: current.revisions.workingRevision
                )
            }
            let operationID = UUID()
            let revisionRecord = try validator.planSavedRevision(
                workspaceID: document.workspaceID,
                savedRevision: newRevision,
                documentDigest: document.contentDigest,
                operationID: operationID,
                updatedAt: now
            )
            let plan = try planJournalTransition(
                current: current,
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
                documentBytes: document.documentBytes,
                validator: validator
            )
            guard plan.committed == nil else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            let candidate = plan.primary
            _ = try replaceJournal(
                expected: snapshot.raw,
                candidate: candidate,
                logicalExpectedRevision: expectedRevision,
                validator: validator
            )
            try DomainPersistenceLock.atomicWrite(
                revisionRecord.canonicalBytes,
                to: revisionURL(document.workspaceID)
            )
            return DomainPersistenceSavedCommit(
                journal: candidate.journal,
                catalogRevision: catalogRevision
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
        try ensureLazyMigration(now: now, permit: permit)
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
            let current = snapshot.effectiveJournal
            guard current.revisions == expectedRevisions else {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedRevisions.workingRevision,
                    actual: current.revisions.workingRevision
                )
            }
            guard let externalBytes = try? Data(contentsOf: document.fileURL),
                  DomainContentDigest.sha256(externalBytes) == externalSavedDigest
            else {
                throw DomainPersistenceError.externalDocumentConflict
            }
            let plan = try planJournalTransition(
                current: current,
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
                documentBytes: document.documentBytes,
                validator: validator
            )
            guard plan.committed == nil else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            let candidate = plan.primary
            _ = try replaceJournal(
                expected: snapshot.raw,
                candidate: candidate,
                logicalExpectedRevision: expectedRevisions.workingRevision,
                validator: validator
            )
            return DomainPersistenceWorkingCommit(
                journal: candidate.journal,
                catalogRevision: catalogRevision
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
        try ensureLazyMigration(now: now, permit: permit)
        return try withLock(at: lockDirectory.appendingPathComponent("workspace-catalog.lock")) {
            try validateMutationScope(permit, document: document)
            let currentCatalog = try loadCurrentCatalog(now: now)
            if let expectedCatalogRevision,
               expectedCatalogRevision != currentCatalog.revision
            {
                throw DomainPersistenceError.stateConflict(
                    expected: expectedCatalogRevision,
                    actual: currentCatalog.revision
                )
            }
            return try withLock(at: lockURL(document.workspaceID)) {
                try validateMutationScope(permit, document: document)
                let snapshot = try readCurrentJournalOrSeed(
                    document: document,
                    validator: validator
                )
                let current = snapshot.effectiveJournal
                guard current.revisions.workingRevision == expectedWorkspaceRevision else {
                    throw DomainPersistenceError.stateConflict(
                        expected: expectedWorkspaceRevision,
                        actual: current.revisions.workingRevision
                    )
                }
                let plannedTombstone = try validator.planDeletionTombstone(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    operation: operation,
                    deletedAt: now
                )
                let tombstone = plannedTombstone.tombstone
                let entries = currentCatalog.entries.filter {
                    $0.workspaceID != document.workspaceID
                }
                var deletions = (currentCatalog.deletions ?? []).filter {
                    $0.workspaceID != document.workspaceID
                }
                deletions.append(tombstone)
                let next = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: currentCatalog.revision &+ 1,
                    entries: entries,
                    deletions: deletions,
                    updatedAt: now
                )
                // Catalog deletion is the crash-safe authority point. The sidecar and artifact
                // cleanup follow while both identity and workspace locks remain held.
                try DomainPersistenceLock.atomicWrite(encoder.encode(next), to: catalogURL)
                var artifactCleanupWarnings = [String]()
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

                var recordedTombstone = tombstone
                if !artifactCleanupWarnings.isEmpty {
                    do {
                        let cleanupPlan = try validator.planDeletionTombstone(
                            workspaceID: tombstone.workspaceID,
                            fileURL: tombstone.fileURL,
                            operation: tombstone.operation,
                            deletedAt: tombstone.deletedAt,
                            cleanupWarnings: artifactCleanupWarnings
                        )
                        recordedTombstone = cleanupPlan.tombstone
                        do {
                            try DomainPersistenceLock.atomicWrite(
                                cleanupPlan.canonicalBytes,
                                to: deletionURL(document.workspaceID)
                            )
                        } catch {
                            artifactCleanupWarnings.append(
                                "cleanup status sidecar: \(error.localizedDescription)"
                            )
                            if let amendedPlan = try? validator.planDeletionTombstone(
                                workspaceID: tombstone.workspaceID,
                                fileURL: tombstone.fileURL,
                                operation: tombstone.operation,
                                deletedAt: tombstone.deletedAt,
                                cleanupWarnings: artifactCleanupWarnings
                            ) {
                                recordedTombstone = amendedPlan.tombstone
                            }
                        }
                    } catch {
                        artifactCleanupWarnings.append(
                            "cleanup status planning: \(error.localizedDescription)"
                        )
                    }
                }
                return DomainPersistenceDeleteCommit(
                    catalogRevision: next.revision,
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

    private func resolvedPendingSave(
        _ journal: DomainWorkingJournal,
        expectedWorkspaceID: UUID,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> (journal: DomainWorkingJournal, document: DomainWorkspaceDocument)? {
        guard journal.workspaceID == expectedWorkspaceID,
              let pendingSave = journal.pendingSave,
              let savedBytes = try? Data(contentsOf: journal.fileURL),
              DomainContentDigest.sha256(savedBytes) == pendingSave.documentDigest,
              let document = decodeWorkspaceDocument(
                  savedBytes,
                  fileURL: journal.fileURL,
                  expectedWorkspaceID: expectedWorkspaceID
              )
        else { return nil }
        let plan = try planJournalTransition(
            current: journal,
            transition: .recoverPending(expectedWorkspaceID: expectedWorkspaceID),
            validator: validator
        )
        guard plan.committed == nil else {
            throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
        }
        return (plan.primary.journal, document)
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
    ) -> Result<DomainWorkingJournal?, Error> {
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
                return .success(validation.journal)
            }
        } catch {
            return .failure(error)
        }
    }

    private func planJournalTransition(
        current: DomainWorkingJournal?,
        transition: DomainWorkspaceWorkingJournalTransition,
        documentBytes: Data? = nil,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> (primary: PreparedJournalCandidate, committed: PreparedJournalCandidate?) {
        let plan = try validator.planTransition(
            current: current,
            transition: transition,
            documentBytes: documentBytes
        )
        func candidate(
            _ validation: DomainWorkspaceWorkingJournalValidation
        ) -> PreparedJournalCandidate {
            PreparedJournalCandidate(
                journal: validation.journal,
                canonicalBytes: validation.canonicalBytes,
                contentDigest: validation.contentDigest
            )
        }
        return (
            primary: candidate(plan.primary),
            committed: plan.committed.map(candidate)
        )
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
        let url = revisionURL(workspaceID)
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
            let savedBytes = (try? Data(contentsOf: document.fileURL)) ?? document.documentBytes
            let savedDigest = DomainContentDigest.sha256(savedBytes)
            let revisions = try loadSavedRevision(
                workspaceID: document.workspaceID,
                digest: savedDigest,
                validator: validator
            )
            let plan = try planJournalTransition(
                current: nil,
                transition: .seed(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL,
                    revisions: revisions,
                    savedDigest: savedDigest,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    updatedAt: identity.createdAt
                ),
                validator: validator
            )
            guard plan.committed == nil else {
                throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
            }
            return ValidatedJournalSnapshot(
                raw: raw,
                effectiveJournal: plan.primary.journal
            )
        case let .present(_, bytes):
            let stored = try validator.validateSynchronously(
                bytes,
                expectedWorkspaceID: document.workspaceID,
                expectedFileURL: document.fileURL
            ).journal
            let effective = try resolvedPendingSave(
                stored,
                expectedWorkspaceID: document.workspaceID,
                validator: validator
            )?.journal ?? stored
            return ValidatedJournalSnapshot(
                raw: raw,
                effectiveJournal: effective
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
            let catalog = try loadCurrentCatalog(now: now)
            let isDeleted = (catalog.deletions ?? []).contains {
                $0.workspaceID == document.workspaceID
            }
            guard !isDeleted else {
                throw DomainPersistenceError.stateConflict(
                    expected: catalog.revision,
                    actual: catalog.revision &+ 1
                )
            }
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
                let recovered = try readCurrentJournalOrSeed(
                    document: document,
                    validator: validator
                ).effectiveJournal
                guard recovered.fileURL.standardizedFileURL == document.fileURL.standardizedFileURL,
                      recovered.operations.contains(where: { $0.before == nil })
                else {
                    throw DomainPersistenceError.stateConflict(
                        expected: catalog.revision,
                        actual: catalog.revision &+ 1
                    )
                }
                var entries = catalog.entries
                entries.append(.init(
                    workspaceID: document.workspaceID,
                    fileURL: document.fileURL
                ))
                let repairedCatalog = RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: catalog.revision &+ 1,
                    entries: entries.sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString },
                    deletions: catalog.deletions ?? [],
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(
                    encoder.encode(repairedCatalog),
                    to: catalogURL
                )
                return try body(repairedCatalog.revision)
            }
        }
    }

    private func loadCurrentCatalog(now: Date) throws -> RuntimeWorkspaceCatalog {
        if fileManager.fileExists(atPath: catalogURL.path) {
            let current = try decoder.decode(
                RuntimeWorkspaceCatalog.self,
                from: Data(contentsOf: catalogURL)
            )
            guard current.version <= RuntimeWorkspaceCatalog.schemaVersion else {
                throw DomainPersistenceError.futureJournal(current.version)
            }
            try validateUniqueCatalogEntries(current.entries)
            return current
        }
        let entries = try legacyCatalogEntries()
        try validateUniqueCatalogEntries(entries)
        return RuntimeWorkspaceCatalog(
            version: RuntimeWorkspaceCatalog.schemaVersion,
            revision: 0,
            entries: entries,
            updatedAt: now
        )
    }

    private func validateUniqueCatalogEntries(_ entries: [RuntimeWorkspaceCatalog.Entry]) throws {
        guard Set(entries.map(\.workspaceID)).count == entries.count else {
            throw DomainPersistenceError.invalidWorkspaceDocument
        }
    }

    private func ensureLazyMigration(
        now: Date,
        permit: DomainWorkspaceMutationPermit
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
            if !fileManager.fileExists(atPath: catalogURL.path) {
                let catalog = try RuntimeWorkspaceCatalog(
                    version: RuntimeWorkspaceCatalog.schemaVersion,
                    revision: 0,
                    entries: legacyCatalogEntries(),
                    updatedAt: now
                )
                try DomainPersistenceLock.atomicWrite(encoder.encode(catalog), to: catalogURL)
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

    static func atomicWrite(_ data: Data, to destination: URL) throws {
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
            guard rename(temporary.path, destination.path) == 0 else {
                throw DomainPersistenceError.writeFailed("rename_failed_\(errno)")
            }
            let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                close(directoryDescriptor)
            }
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
