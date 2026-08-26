import AgentryUniFFIRaw
import Foundation

/// Read-only Rust projection of one composed context's headless prompt/selection fields.
public struct CoreWorkspaceContextProjectionV1: Sendable, Equatable {
    public let contextID: UUID
    public let name: String
    public let activeAgentSessionID: UUID?
    public let activeChatSessionID: UUID?
    public let prompt: String
    public let selection: [String]

    public init(
        contextID: UUID,
        name: String,
        activeAgentSessionID: UUID?,
        activeChatSessionID: UUID?,
        prompt: String,
        selection: [String]
    ) {
        self.contextID = contextID
        self.name = name
        self.activeAgentSessionID = activeAgentSessionID
        self.activeChatSessionID = activeChatSessionID
        self.prompt = prompt
        self.selection = selection
    }
}

/// P5-1a's complete, order-preserving projection of one canonical workspace document.
public struct CoreWorkspaceDocumentProjectionV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1
    public static let maximumDocumentBytes = 32 * 1024 * 1024

    public let workspaceID: UUID
    public let schemaVersion: Int
    public let name: String
    public let repoPaths: [String]
    public let activeContextID: UUID?
    public let contexts: [CoreWorkspaceContextProjectionV1]
    public let authority: CoreWorkspaceProjectionAuthorityState?

    public init(
        workspaceID: UUID,
        schemaVersion: Int,
        name: String,
        repoPaths: [String],
        activeContextID: UUID?,
        contexts: [CoreWorkspaceContextProjectionV1],
        authority: CoreWorkspaceProjectionAuthorityState? = nil
    ) {
        self.workspaceID = workspaceID
        self.schemaVersion = schemaVersion
        self.name = name
        self.repoPaths = repoPaths
        self.activeContextID = activeContextID
        self.contexts = contexts
        self.authority = authority
    }
}

public enum CoreWorkspaceWorkingJournalValidationError: Error, Sendable, Equatable {
    case inputTooLarge
    case outputTooLarge
    case malformed
    case futureSchema(UInt16)
    case invalidIdentity
    case invalidFileURL
    case invalidRevisionState
    case invalidDigest
    case invalidWorkingDocument
    case invalidContextTable
    case invalidOperationLedger
    case invalidPendingSave
    case invalidTimestamp
}

public struct CoreWorkspaceWorkingJournalTransitionPlanV1: Sendable, Equatable {
    public let primary: CoreWorkspaceWorkingJournalValidationV1
    public let committed: CoreWorkspaceWorkingJournalValidationV1?

    public init(
        primary: CoreWorkspaceWorkingJournalValidationV1,
        committed: CoreWorkspaceWorkingJournalValidationV1?
    ) {
        self.primary = primary
        self.committed = committed
    }
}

public struct CoreWorkspacePersistenceMetadataValidationV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let operationID: UUID
    public let schemaVersion: UInt16
    public let contentDigest: String
    public let canonicalBytes: Data

    public init(
        workspaceID: UUID,
        operationID: UUID,
        schemaVersion: UInt16,
        contentDigest: String,
        canonicalBytes: Data
    ) {
        self.workspaceID = workspaceID
        self.operationID = operationID
        self.schemaVersion = schemaVersion
        self.contentDigest = contentDigest
        self.canonicalBytes = canonicalBytes
    }
}

public struct CoreWorkspaceWorkingJournalValidationV1: Sendable, Equatable {
    public static let contractVersion: UInt16 = 1
    public static let maximumJournalBytes = 128 * 1024 * 1024

    public let workspaceID: UUID
    public let journalVersion: UInt16
    public let contentDigest: String
    public let canonicalBytes: Data

    public init(
        workspaceID: UUID,
        journalVersion: UInt16,
        contentDigest: String,
        canonicalBytes: Data
    ) {
        self.workspaceID = workspaceID
        self.journalVersion = journalVersion
        self.contentDigest = contentDigest
        self.canonicalBytes = canonicalBytes
    }
}

/// Short-lived synchronous capability for validating working journals while a caller holds a
/// non-suspending filesystem transaction. Every call carries the exact runtime identity captured
/// during preparation; Rust rejects stopped, poisoned, or replaced runtimes before returning bytes.
public struct CorePreparedWorkspaceWorkingJournalValidatorV1: Sendable {
    private let context: CoreDirectComputeOperationContext

    init(context: CoreDirectComputeOperationContext) {
        self.context = context
    }

    public func planSavedRevision(
        _ requestBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(requestBytes) { identity, payloadBytes in
            try context.transport.workspaceSavedRevisionPlanV1(
                identity: identity,
                payloadBytes: payloadBytes
            )
        }
    }

    public func validateSavedRevision(
        _ artifactBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(artifactBytes) { identity, payloadBytes in
            try context.transport.workspaceSavedRevisionValidateV1(
                identity: identity,
                payloadBytes: payloadBytes
            )
        }
    }

    public func planDeletionTombstone(
        _ requestBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(requestBytes) { identity, payloadBytes in
            try context.transport.workspaceDeletionTombstonePlanV1(
                identity: identity,
                payloadBytes: payloadBytes
            )
        }
    }

    /// Probes the exact prepared runtime identity without accepting any persistence artifact. A
    /// live runtime must reject the deliberately malformed bounded payload with the typed semantic
    /// error; a stopped or replaced runtime fails through the transport instead.
    public func requireRuntimeAvailability() throws {
        do {
            _ = try context.transport.workspaceSavedRevisionValidateV1(
                identity: context.identity,
                payloadBytes: Data("{}".utf8)
            )
            throw CoreTransportError.unexpected(
                "workspace persistence availability probe unexpectedly validated"
            )
        } catch is CoreWorkspaceWorkingJournalValidationError {
            return
        }
    }

    private func workspacePersistenceMetadata(
        _ bytes: Data,
        operation: (CoreRuntimeIdentity, Data) throws -> CoreWorkspacePersistenceMetadataValidationV1
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        guard bytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try operation(context.identity, bytes)
    }

    public func validate(
        _ journalBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        guard journalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceWorkingJournalValidateV1(
            identity: context.identity,
            journalBytes: journalBytes
        )
    }

    public func planTransition(
        currentJournalBytes: Data?,
        transitionBytes: Data,
        documentBytes: Data?
    ) throws -> CoreWorkspaceWorkingJournalTransitionPlanV1 {
        guard currentJournalBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              transitionBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              documentBytes?.count ?? 0 <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceWorkingJournalPlanTransitionV1(
            identity: context.identity,
            currentJournalBytes: currentJournalBytes,
            transitionBytes: transitionBytes,
            documentBytes: documentBytes
        )
    }
}

public extension CoreComputeClient {
    /// Captures one exact live Rust runtime identity for synchronous journal validation.
    func prepareWorkspaceWorkingJournalValidatorV1()
        async throws -> CorePreparedWorkspaceWorkingJournalValidatorV1
    {
        try Task.checkCancellation()
        let context = try await bridge.prepareDirectComputeOperation()
        try Task.checkCancellation()
        return CorePreparedWorkspaceWorkingJournalValidatorV1(context: context)
    }

    /// Projects one complete `workspace.json` buffer through Rust without retaining or mutating it.
    func projectWorkspaceDocumentV1(_ documentBytes: Data) async throws -> CoreWorkspaceDocumentProjectionV1 {
        try Task.checkCancellation()
        guard documentBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes else {
            throw CoreComputeError.invalidRequest(
                "workspace document exceeds \(CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes)-byte projection limit"
            )
        }
        let context = try await bridge.prepareDirectComputeOperation()
        do {
            let result = try await Task.detached(priority: nil) {
                try context.transport.workspaceDocumentProjectionV1(
                    identity: context.identity,
                    documentBytes: documentBytes
                )
            }.value
            try Task.checkCancellation()
            try await bridge.validateComputeCompletion(identity: context.identity)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }

    /// Validates and deterministically canonicalizes one existing Swift V1 working journal.
    func validateWorkspaceWorkingJournalV1(
        _ journalBytes: Data
    ) async throws -> CoreWorkspaceWorkingJournalValidationV1 {
        try Task.checkCancellation()
        guard journalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreComputeError.invalidRequest(
                "workspace journal exceeds \(CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes)-byte limit"
            )
        }
        let prepared = try await prepareWorkspaceWorkingJournalValidatorV1()
        do {
            let result = try await Task.detached(priority: nil) {
                try prepared.validate(journalBytes)
            }.value
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CoreWorkspaceWorkingJournalValidationError {
            throw error
        } catch {
            throw await bridge.mapComputeFailure(error)
        }
    }
}

extension CoreRuntimeTransport {
    func workspaceProjectionOpenScopeV1(
        identity: CoreRuntimeIdentity,
        config: AgentryUniFFIRaw.CoreWorkspaceProjectionScopeConfigV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionScopeHandleV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionCloseScopeV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionReplaceV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionReplaceRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionUpsertV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionUpsertRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionUpsertAuthoritativeV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionUpsertAuthoritativeRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionPublishV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionPublishRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionPublishAuthoritativeV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionPublishAuthoritativeRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionPublicationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionRemoveV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionRemoveRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionMutationReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionExportCheckpointV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws -> Data {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionRestoreCheckpointV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionRestoreCheckpointRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionRestoreCheckpointReceiptV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionOpenSnapshotV1(
        identity: CoreRuntimeIdentity,
        request: AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotRequestV1
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotHandleV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionSnapshotPageV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64,
        offset: UInt64,
        limit: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionSnapshotPageV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionCloseSnapshotV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64,
        handleID: UInt64
    ) throws {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceProjectionDiagnosticsV1(
        identity: CoreRuntimeIdentity,
        scopeID: String,
        scopeIncarnation: UInt64
    ) throws -> AgentryUniFFIRaw.CoreWorkspaceProjectionDiagnosticsV1 {
        throw CoreTransportError.unexpected("workspace projection scope transport is unavailable")
    }

    func workspaceDocumentProjectionV1(
        identity: CoreRuntimeIdentity,
        documentBytes: Data
    ) throws -> CoreWorkspaceDocumentProjectionV1 {
        throw CoreTransportError.unexpected("workspace document projection transport is unavailable")
    }

    func workspaceSavedRevisionPlanV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        throw CoreTransportError.unexpected("workspace saved revision plan transport is unavailable")
    }

    func workspaceSavedRevisionValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        throw CoreTransportError.unexpected("workspace saved revision validation transport is unavailable")
    }

    func workspaceDeletionTombstonePlanV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        throw CoreTransportError.unexpected("workspace deletion tombstone plan transport is unavailable")
    }

    func workspaceWorkingJournalValidateV1(
        identity: CoreRuntimeIdentity,
        journalBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        throw CoreTransportError.unexpected("workspace working journal transport is unavailable")
    }

    func workspaceWorkingJournalPlanTransitionV1(
        identity: CoreRuntimeIdentity,
        currentJournalBytes: Data?,
        transitionBytes: Data,
        documentBytes: Data?
    ) throws -> CoreWorkspaceWorkingJournalTransitionPlanV1 {
        throw CoreTransportError.unexpected("workspace working journal transition transport is unavailable")
    }
}
