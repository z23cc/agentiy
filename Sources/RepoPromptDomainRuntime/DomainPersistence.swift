import AgentryCoreBridge
import Darwin
import Foundation
import os

struct DomainPendingSave: Codable, Equatable {
    let operationID: UUID
    let documentDigest: String
}

struct DomainWorkingJournal: Codable, Equatable {
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

struct DomainSavedRevisionRecord: Codable, Equatable {
    static let schemaVersion = 1

    let version: Int
    let workspaceID: UUID
    let savedRevision: UInt64
    let documentDigest: String
    let operationID: UUID
    let updatedAt: Date
}

struct DomainDeletionTombstone: Codable, Equatable {
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

enum DomainExternalObservationEvidence: Equatable {
    case unchanged(DomainFileMetadata)
    case present(bytes: Data, metadata: DomainFileMetadata, digest: String)
    case absent(DomainFileMetadata)
    case unavailable(metadata: DomainFileMetadata, reason: String)
    case cancelled
}

enum DomainWorkspaceCommandAdmissionJournalEvidence: Equatable {
    case absent
    case present(Data)
    case unavailable

    var canonicalBytes: Data? {
        switch self {
        case .absent, .unavailable:
            nil
        case let .present(bytes):
            bytes
        }
    }

    var isAvailable: Bool {
        switch self {
        case .absent, .present:
            true
        case .unavailable:
            false
        }
    }
}

struct DomainPersistenceBootstrap {
    struct Workspace {
        let document: DomainWorkspaceDocument
        let savedDigest: String
        let revisions: DomainRevisionState
        let contextRevisions: [UUID: DomainRevisionState]
        let contextTombstones: [UUID: UInt64]
        let operations: [DomainRecordedOperation]
        let admissionJournalEvidence: DomainWorkspaceCommandAdmissionJournalEvidence
        let health: DomainAuthorityHealth
        let externalDocument: DomainWorkspaceDocument?
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
    let deletedWorkspaceIDs: Set<UUID>
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
    let semanticRecovery: DomainWorkspaceRustJournal.PreparedSemanticRecovery?
    let semanticPreview: DomainWorkspaceSemanticRecoveryPreview?
}

struct DomainPersistenceWorkspaceRefresh {
    let workspace: DomainPersistenceBootstrap.Workspace?
    let unavailableWorkspace: DomainPersistenceBootstrap.UnavailableWorkspace?
    let workspaceIsDeleted: Bool
    let workspaceIsNoChange: Bool
    let health: DomainAuthorityHealth
    let catalogRevision: UInt64
    let semanticRecovery: DomainWorkspaceRustJournal.PreparedSemanticRecovery?
    let semanticPreview: DomainWorkspaceSemanticRecoveryPreview?
}

enum DomainPersistenceError: Error, Equatable {
    case stateConflict(expected: UInt64, actual: UInt64)
    case externalDocumentConflict
    case admissionRecoveryStale
    case admissionFullRecoveryRequired
    case futureJournal(Int)
    /// The journal or catalog could not be interpreted. The payload names *where* that
    /// conclusion was reached, because this case is reachable from ~90 distinct checks in this
    /// module and from a ten-way collapse of Rust journal errors in
    /// `DomainWorkspaceRustJournal`. Without it the value is unattributable, which is exactly how
    /// one occurrence cost a full diagnostic session and 93 temporary probes to localize.
    /// Construct it with `journalCorruption(...)`, which captures the site automatically.
    case corruptJournal(String)
    case operationIDCollision
    case invalidWorkspaceDocument
    case writeFailed(String)
    case lockTimedOut
    case cancelled
    case runtimeShutdownRequested
    case mutationPermitInvalid
    case workspaceOutsideMutationScope
}

extension DomainPersistenceError {
    /// Builds `corruptJournal` with its origin attached. Callers pass a reason only when they know
    /// something the call site does not already say; the file and line come for free.
    static func journalCorruption(
        _ reason: String? = nil,
        file: String = #fileID,
        line: Int = #line
    ) -> DomainPersistenceError {
        .corruptJournal(reason.map { "\($0) @\(file):\(line)" } ?? "\(file):\(line)")
    }
}

package struct DomainPersistenceDataSnapshot {
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
    private static let maximumWorkspaceCatalogBytes = 128 * 1024 * 1024

    #if DEBUG
        private static let catalogReplacementTestHooks = OSAllocatedUnfairLock(
            initialState: [String: @Sendable () throws -> Void]()
        )

        package static func setCatalogReplacementTestHook(
            for catalogURL: URL,
            _ hook: (@Sendable () throws -> Void)?
        ) {
            let triggerPath = catalogURL.deletingLastPathComponent().appendingPathComponent("catalog_replacement_hook.trigger")
            let contentPath = catalogURL.deletingLastPathComponent().appendingPathComponent("catalog_replacement_hook.content")
            if let hook {
                let originalData = try? Data(contentsOf: catalogURL)
                try? hook()
                if let replacedData = try? Data(contentsOf: catalogURL) {
                    try? replacedData.write(to: contentPath)
                    try? "".write(to: triggerPath, atomically: true, encoding: .utf8)
                    if let originalData {
                        let fileDestination = catalogURL
                        try? originalData.write(to: fileDestination, options: .atomic)
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: triggerPath)
                try? FileManager.default.removeItem(at: contentPath)
            }
            catalogReplacementTestHooks.withLock { hooks in
                hooks[catalogURL.standardizedFileURL.path] = hook
            }
        }
    #endif

    struct RuntimeWorkspaceCatalog: Codable, Equatable {
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

    private enum RawCatalogSnapshot {
        case absent
        case present(digest: String, bytes: Data)

        var digest: String? {
            switch self {
            case .absent: nil
            case let .present(digest, _): digest
            }
        }
    }

    private struct ValidatedCatalogSnapshot {
        let raw: RawCatalogSnapshot
        let validation: DomainWorkspaceCatalogValidation
    }

    private let configuration: DomainRuntimeConfiguration
    private let identity: DomainRuntimeIdentity
    private let coreService: AgentryCoreService
    private let cancellation: DomainBlockingCancellation?

    package init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        workspaceAuthorityScope: DomainWorkspaceAuthorityLeaseScope? = nil,
        workspaceMutationPermitRegistry: DomainWorkspaceMutationPermitRegistry? = nil,
        coreService: AgentryCoreService = .shared
    ) {
        _ = workspaceAuthorityScope
        _ = workspaceMutationPermitRegistry
        self.configuration = configuration
        self.identity = identity
        self.coreService = coreService
        cancellation = nil
    }

    private init(
        configuration: DomainRuntimeConfiguration,
        identity: DomainRuntimeIdentity,
        coreService: AgentryCoreService,
        cancellation: DomainBlockingCancellation
    ) {
        self.configuration = configuration
        self.identity = identity
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
            coreService: coreService,
            cancellation: cancellation
        )
    }

    private func prepareJournalValidator() async throws -> DomainWorkspaceRustJournal.PreparedValidator {
        try await DomainWorkspaceRustJournal.prepare(coreService: coreService)
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

    private var canonicalWorkspaceRuntimeRoot: URL {
        workspaceRoot.appendingPathComponent(".agentry-domain-runtime", isDirectory: true)
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

    private var journalDirectory: URL {
        let canonical = canonicalWorkspaceRuntimeRoot.appendingPathComponent("working-journals", isDirectory: true)
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        return runtimeRoot.appendingPathComponent("working-journals", isDirectory: true)
    }

    private var revisionDirectory: URL {
        let canonical = canonicalWorkspaceRuntimeRoot.appendingPathComponent("revisions", isDirectory: true)
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        return runtimeRoot.appendingPathComponent("revisions", isDirectory: true)
    }

    private var deletionDirectory: URL {
        let canonical = canonicalWorkspaceRuntimeRoot.appendingPathComponent("deletion-tombstones", isDirectory: true)
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        return runtimeRoot.appendingPathComponent("deletion-tombstones", isDirectory: true)
    }

    private var lockDirectory: URL {
        let canonical = canonicalWorkspaceRuntimeRoot.appendingPathComponent("locks", isDirectory: true)
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        return runtimeRoot.appendingPathComponent("locks", isDirectory: true)
    }

    private var settingsDirectory: URL {
        runtimeRoot.appendingPathComponent("settings", isDirectory: true)
    }

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

    private var catalogURL: URL {
        let canonical = canonicalWorkspaceRuntimeRoot.appendingPathComponent("workspace-catalog.json")
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        return runtimeRoot.appendingPathComponent("workspace-catalog.json")
    }

    private var indexURL: URL {
        workspaceRoot.appendingPathComponent("workspacesIndex.json")
    }

    private func journalURL(_ workspaceID: UUID) -> URL {
        let canonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("working-journals", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        let legacyCanonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("working-journals", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString).json")
        if FileManager.default.fileExists(atPath: legacyCanonical.path) {
            return legacyCanonical
        }
        return journalDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func revisionURL(_ workspaceID: UUID) -> URL {
        let canonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        let legacyCanonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString).json")
        if FileManager.default.fileExists(atPath: legacyCanonical.path) {
            return legacyCanonical
        }
        return revisionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func deletionURL(_ workspaceID: UUID) -> URL {
        let canonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("deletion-tombstones", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }
        let legacyCanonical = canonicalWorkspaceRuntimeRoot
            .appendingPathComponent("deletion-tombstones", isDirectory: true)
            .appendingPathComponent("\(workspaceID.uuidString).json")
        if FileManager.default.fileExists(atPath: legacyCanonical.path) {
            return legacyCanonical
        }
        return deletionDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    func bootstrap(
        permit: DomainWorkspaceMutationPermit? = nil,
        commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission? = nil
    ) async -> DomainPersistenceBootstrap {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).bootstrapBlocking(
                    validator: validator,
                    permit: permit,
                    commandAdmission: commandAdmission
                )
            }
        } catch {
            let reason = if error as? DomainPersistenceError == .cancelled {
                "bootstrap_cancelled"
            } else {
                "working_journal_rust_unavailable"
            }
            return DomainPersistenceBootstrap(
                workspaces: [],
                unavailableWorkspaces: [],
                deletedWorkspaceIDs: [],
                health: .degradedReadOnly(reason: reason),
                catalogRevision: 0,
                semanticRecovery: nil,
                semanticPreview: nil
            )
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

    func currentCatalogRevision() async throws -> UInt64? {
        let validator = try await prepareJournalValidator()
        return try await DomainBlockingIO.run { cancellation in
            try cancellation.check()
            let worker = blockingWorker(cancellation)
            guard let bytes = try worker.readCatalogBytes() else { return nil }
            return try validator.validateCatalog(bytes).catalog.revision
        }
    }

    func externalObservationEvidence(
        for snapshot: DomainWorkspaceSnapshot,
        knownMetadata: DomainFileMetadata
    ) async -> DomainExternalObservationEvidence {
        do {
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).externalObservationEvidenceBlocking(
                    for: snapshot,
                    knownMetadata: knownMetadata
                )
            }
        } catch DomainPersistenceError.cancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unavailable(metadata: knownMetadata, reason: "external_workspace_probe_failed")
        }
    }

    func refreshWorkspace(
        workspaceID: UUID,
        fallbackFileURL: URL,
        permit: DomainWorkspaceMutationPermit? = nil,
        commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission? = nil
    ) async -> DomainPersistenceWorkspaceRefresh? {
        do {
            let validator = try await prepareJournalValidator()
            return try await DomainBlockingIO.run { cancellation in
                try cancellation.check()
                return try blockingWorker(cancellation).refreshWorkspaceBlocking(
                    workspaceID: workspaceID,
                    fallbackFileURL: fallbackFileURL,
                    validator: validator,
                    permit: permit,
                    commandAdmission: commandAdmission
                )
            }
        } catch DomainPersistenceError.cancelled {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                unavailableWorkspace: nil,
                workspaceIsDeleted: false,
                workspaceIsNoChange: false,
                health: .degradedReadOnly(reason: "workspace_catalog_probe_failed"),
                catalogRevision: 0,
                semanticRecovery: nil,
                semanticPreview: nil
            )
        }
    }

    private func refreshWorkspaceBlocking(
        workspaceID: UUID,
        fallbackFileURL: URL,
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        permit: DomainWorkspaceMutationPermit?,
        commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission?
    ) throws -> DomainPersistenceWorkspaceRefresh {
        let validation: DomainWorkspaceCatalogValidation
        do {
            validation = try validatedSemanticRecoveryCatalog(validator: validator)
        } catch {
            if isJournalInfrastructureFailure(error) {
                throw error
            }
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                unavailableWorkspace: nil,
                workspaceIsDeleted: false,
                workspaceIsNoChange: false,
                health: .degradedReadOnly(reason: catalogDegradedReason(error)),
                catalogRevision: 0,
                semanticRecovery: nil,
                semanticPreview: nil
            )
        }
        guard let commandAdmission else {
            return DomainPersistenceWorkspaceRefresh(
                workspace: nil,
                unavailableWorkspace: nil,
                workspaceIsDeleted: false,
                workspaceIsNoChange: false,
                health: .degradedReadOnly(reason: "workspace_command_admission_unavailable"),
                catalogRevision: validation.catalog.revision,
                semanticRecovery: nil,
                semanticPreview: nil
            )
        }

        let evidence = try semanticTargetRecoveryEvidence(
            validation: validation,
            workspaceID: workspaceID,
            fallbackFileURL: fallbackFileURL
        )
        let prepared = try commandAdmission.prepareSemanticTargetRecovery(evidence)
        let preview = try prepared.preview()
        guard preview.catalogRevision == validation.catalog.revision,
              preview.catalogDigest == validation.contentDigest,
              preview.targetWorkspaceID == workspaceID,
              case let .target(directive) = preview.projection
        else {
            prepared.close()
            throw DomainPersistenceError.journalCorruption()
        }

        let workspace: DomainPersistenceBootstrap.Workspace?
        let unavailableWorkspace: DomainPersistenceBootstrap.UnavailableWorkspace?
        let workspaceIsDeleted: Bool
        let workspaceIsNoChange: Bool
        switch directive {
        case let .upsert(active):
            workspace = persistenceWorkspace(
                active,
                journalEvidence: evidence.journal,
                savedDocumentEvidence: evidence.savedDocument
            )
            unavailableWorkspace = nil
            workspaceIsDeleted = false
            workspaceIsNoChange = false
        case let .unavailable(row):
            workspace = nil
            unavailableWorkspace = .init(
                workspaceID: row.workspaceID,
                fileURL: row.fileURL,
                reason: row.reason,
                fileMetadata: fileMetadata(at: row.fileURL)
            )
            workspaceIsDeleted = false
            workspaceIsNoChange = false
        case .noChange:
            workspace = nil
            unavailableWorkspace = nil
            workspaceIsDeleted = false
            workspaceIsNoChange = true
        case .delete:
            workspace = nil
            unavailableWorkspace = nil
            workspaceIsDeleted = true
            workspaceIsNoChange = false
        }
        return DomainPersistenceWorkspaceRefresh(
            workspace: workspace,
            unavailableWorkspace: unavailableWorkspace,
            workspaceIsDeleted: workspaceIsDeleted,
            workspaceIsNoChange: workspaceIsNoChange,
            health: preview.globalHealth,
            catalogRevision: preview.catalogRevision,
            semanticRecovery: prepared,
            semanticPreview: preview
        )
    }

    private func bootstrapBlocking(
        validator: DomainWorkspaceRustJournal.PreparedValidator,
        permit: DomainWorkspaceMutationPermit?,
        commandAdmission: DomainWorkspaceRustJournal.PreparedCommandAdmission?
    ) throws -> DomainPersistenceBootstrap {
        let validation: DomainWorkspaceCatalogValidation
        do {
            validation = try validatedSemanticRecoveryCatalog(validator: validator)
        } catch {
            if isJournalInfrastructureFailure(error) {
                throw error
            }
            return DomainPersistenceBootstrap(
                workspaces: [],
                unavailableWorkspaces: [],
                deletedWorkspaceIDs: [],
                health: .degradedReadOnly(reason: catalogDegradedReason(error)),
                catalogRevision: 0,
                semanticRecovery: nil,
                semanticPreview: nil
            )
        }

        let evidence = try semanticFullRecoveryEvidence(validation: validation)
        let prepared = try commandAdmission?.prepareSemanticFullRecovery(evidence)
            ?? validator.prepareInitialSemanticRecovery(evidence)
        let preview = try prepared.preview()
        guard preview.catalogRevision == validation.catalog.revision,
              preview.catalogDigest == validation.contentDigest,
              preview.targetWorkspaceID == nil,
              case let .full(rows) = preview.projection
        else {
            prepared.close()
            throw DomainPersistenceError.journalCorruption()
        }

        let evidenceByWorkspaceID = Dictionary(uniqueKeysWithValues: evidence.workspaces.map {
            ($0.workspaceID, $0)
        })
        var workspaces: [DomainPersistenceBootstrap.Workspace] = []
        var unavailable: [DomainPersistenceBootstrap.UnavailableWorkspace] = []
        var deletedWorkspaceIDs = Set<UUID>()
        for row in rows {
            switch row {
            case let .active(active):
                guard let physical = evidenceByWorkspaceID[active.document.workspaceID] else {
                    prepared.close()
                    throw DomainPersistenceError.journalCorruption()
                }
                workspaces.append(persistenceWorkspace(
                    active,
                    journalEvidence: physical.journal,
                    savedDocumentEvidence: physical.savedDocument
                ))
            case let .unavailable(row):
                unavailable.append(.init(
                    workspaceID: row.workspaceID,
                    fileURL: row.fileURL,
                    reason: row.reason,
                    fileMetadata: fileMetadata(at: row.fileURL)
                ))
            case let .deleted(workspaceID, _):
                deletedWorkspaceIDs.insert(workspaceID)
            }
        }
        return DomainPersistenceBootstrap(
            workspaces: workspaces,
            unavailableWorkspaces: unavailable,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            health: preview.globalHealth,
            catalogRevision: preview.catalogRevision,
            semanticRecovery: prepared,
            semanticPreview: preview
        )
    }

    private func legacyCatalogEntries() throws -> [RuntimeWorkspaceCatalog.Entry] {
        struct CatalogRecoveryIndexEntry: Codable {
            let id: UUID
            let name: String
            let customStoragePath: URL?
            let isSystemWorkspace: Bool
            let isHiddenInMenus: Bool
        }
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        return try decoder.decode([CatalogRecoveryIndexEntry].self, from: Data(contentsOf: indexURL)).map { entry in
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

    private func validatedSemanticRecoveryCatalog(
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> DomainWorkspaceCatalogValidation {
        if let data = try readCatalogBytes() {
            return try validator.validateCatalog(data)
        }
        return try seedLegacyCatalog(
            entries: legacyCatalogEntries(),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            validator: validator
        )
    }

    private func semanticFullRecoveryEvidence(
        validation: DomainWorkspaceCatalogValidation
    ) throws -> DomainWorkspaceSemanticFullRecovery {
        let workspaces = try validation.catalog.entries
            .sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
            .map { entry in
                try DomainWorkspaceSemanticRecoveryEvidence(
                    workspaceID: entry.workspaceID,
                    journal: readSemanticRecoveryArtifact(
                        at: journalURL(entry.workspaceID),
                        maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                        readFailureReason: "working_journal_read_failed",
                        oversizedReason: "working_journal_too_large"
                    ),
                    savedDocument: readSemanticRecoveryArtifact(
                        at: entry.fileURL,
                        maximumBytes: CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes,
                        readFailureReason: "workspace_document_read_failed",
                        oversizedReason: "workspace_document_too_large"
                    ),
                    savedRevision: readSemanticRecoveryArtifact(
                        at: revisionURL(entry.workspaceID),
                        maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                        readFailureReason: "saved_revision_read_failed",
                        oversizedReason: "saved_revision_too_large"
                    )
                )
            }
        let deletions = try (validation.catalog.deletions ?? [])
            .sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
            .map { deletion in
                try DomainWorkspaceSemanticDeletionRecoveryEvidence(
                    workspaceID: deletion.workspaceID,
                    sidecar: readSemanticRecoveryArtifact(
                        at: deletionURL(deletion.workspaceID),
                        maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                        readFailureReason: "deletion_tombstone_read_failed",
                        oversizedReason: "deletion_tombstone_too_large"
                    )
                )
            }
        return DomainWorkspaceSemanticFullRecovery(
            catalogBytes: validation.canonicalBytes,
            catalogRevision: validation.catalog.revision,
            catalogDigest: validation.contentDigest,
            workspaces: workspaces,
            deletions: deletions
        )
    }

    private func semanticTargetRecoveryEvidence(
        validation: DomainWorkspaceCatalogValidation,
        workspaceID: UUID,
        fallbackFileURL: URL
    ) throws -> DomainWorkspaceSemanticTargetRecovery {
        let entry = validation.catalog.entries.first { $0.workspaceID == workspaceID }
        let deletion = (validation.catalog.deletions ?? []).first {
            $0.workspaceID == workspaceID
        }
        let journal: DomainWorkspaceRecoveryArtifactEvidence
        let savedDocument: DomainWorkspaceRecoveryArtifactEvidence
        let savedRevision: DomainWorkspaceRecoveryArtifactEvidence
        if let entry {
            journal = try readSemanticRecoveryArtifact(
                at: journalURL(workspaceID),
                maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                readFailureReason: "working_journal_read_failed",
                oversizedReason: "working_journal_too_large"
            )
            savedDocument = try readSemanticRecoveryArtifact(
                at: entry.fileURL,
                maximumBytes: CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes,
                readFailureReason: "workspace_document_read_failed",
                oversizedReason: "workspace_document_too_large"
            )
            savedRevision = try readSemanticRecoveryArtifact(
                at: revisionURL(workspaceID),
                maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                readFailureReason: "saved_revision_read_failed",
                oversizedReason: "saved_revision_too_large"
            )
        } else {
            journal = .absent
            savedDocument = .absent
            savedRevision = .absent
        }
        let deletionSidecar: DomainWorkspaceRecoveryArtifactEvidence = if deletion != nil {
            try readSemanticRecoveryArtifact(
                at: deletionURL(workspaceID),
                maximumBytes: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
                readFailureReason: "deletion_tombstone_read_failed",
                oversizedReason: "deletion_tombstone_too_large"
            )
        } else {
            .absent
        }
        _ = fallbackFileURL
        return DomainWorkspaceSemanticTargetRecovery(
            catalogBytes: validation.canonicalBytes,
            catalogRevision: validation.catalog.revision,
            catalogDigest: validation.contentDigest,
            workspaceID: workspaceID,
            journal: journal,
            savedDocument: savedDocument,
            savedRevision: savedRevision,
            deletionSidecar: deletionSidecar
        )
    }

    private func readSemanticRecoveryArtifact(
        at url: URL,
        maximumBytes: Int,
        readFailureReason: String,
        oversizedReason: String
    ) throws -> DomainWorkspaceRecoveryArtifactEvidence {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .absent : .unavailable(reason: readFailureReason)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_size >= 0
        else {
            return .unavailable(reason: readFailureReason)
        }
        guard UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            return .unavailable(reason: oversizedReason)
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
                return .unavailable(reason: readFailureReason)
            }
            guard count > 0 else { break }
            guard bytes.count <= maximumBytes - count else {
                return .unavailable(reason: oversizedReason)
            }
            bytes.append(contentsOf: buffer[0 ..< count])
        }
        return .present(bytes)
    }

    private func persistenceWorkspace(
        _ active: DomainWorkspaceSemanticActiveRecovery,
        journalEvidence: DomainWorkspaceRecoveryArtifactEvidence,
        savedDocumentEvidence: DomainWorkspaceRecoveryArtifactEvidence
    ) -> DomainPersistenceBootstrap.Workspace {
        let admissionJournalEvidence: DomainWorkspaceCommandAdmissionJournalEvidence =
            switch journalEvidence {
            case .absent:
                .absent
            case let .present(bytes) where active.health.acceptsMutations:
                .present(bytes)
            case .present, .unavailable:
                .unavailable
            }
        let observedMetadata = fileMetadata(at: active.document.fileURL)
        let trustedMetadata: DomainFileMetadata = if case let .present(bytes) = savedDocumentEvidence,
                                                     DomainContentDigest.sha256(bytes) == active.savedDigest
        {
            observedMetadata
        } else {
            .missing
        }
        return DomainPersistenceBootstrap.Workspace(
            document: active.document,
            savedDigest: active.savedDigest,
            revisions: active.revisions,
            contextRevisions: active.contextRevisions,
            contextTombstones: active.contextTombstones,
            operations: active.operations,
            admissionJournalEvidence: admissionJournalEvidence,
            health: active.health,
            externalDocument: active.externalDocument,
            fileMetadata: trustedMetadata
        )
    }

    private func isJournalInfrastructureFailure(_ error: Error) -> Bool {
        guard let persistenceError = error as? DomainPersistenceError else { return true }
        switch persistenceError {
        case .cancelled, .runtimeShutdownRequested,
             .writeFailed("working_journal_rust_unavailable"):
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
        case .writeFailed("duplicate_workspace_catalog_id"):
            "duplicate_workspace_catalog_id"
        default:
            "workspace_catalog_decode_failed"
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

    private func externalObservationEvidenceBlocking(
        for snapshot: DomainWorkspaceSnapshot,
        knownMetadata: DomainFileMetadata
    ) throws -> DomainExternalObservationEvidence {
        let observedMetadata = fileMetadata(at: snapshot.document.fileURL)
        guard observedMetadata != knownMetadata else {
            return .unchanged(observedMetadata)
        }
        guard observedMetadata.exists else {
            return .absent(observedMetadata)
        }
        do {
            guard let bytes = try boundedWorkspaceDocumentBytes(at: snapshot.document.fileURL) else {
                return .absent(observedMetadata)
            }
            return .present(
                bytes: bytes,
                metadata: observedMetadata,
                digest: DomainContentDigest.sha256(bytes)
            )
        } catch DomainPersistenceError.cancelled {
            throw DomainPersistenceError.cancelled
        } catch {
            return .unavailable(
                metadata: observedMetadata,
                reason: externalObservationProbeReason(error)
            )
        }
    }

    private func externalObservationProbeReason(_ error: Error) -> String {
        guard let persistenceError = error as? DomainPersistenceError else {
            return "external_workspace_probe_failed"
        }
        switch persistenceError {
        case .writeFailed("workspace_document_too_large"):
            return "external_workspace_too_large"
        case .writeFailed("workspace_document_read_failed"):
            return "external_workspace_read_failed"
        case .cancelled, .runtimeShutdownRequested:
            return "external_workspace_probe_cancelled"
        default:
            return "external_workspace_probe_failed"
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

    private func seedLegacyCatalog(
        entries: [RuntimeWorkspaceCatalog.Entry],
        updatedAt: Date,
        validator: DomainWorkspaceRustJournal.PreparedValidator
    ) throws -> DomainWorkspaceCatalogValidation {
        try validator.seedCatalog(entries: entries, updatedAt: updatedAt)
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
