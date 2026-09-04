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
    case duplicateCatalogIdentity
    case invalidFileURL
    case invalidRevisionState
    case invalidDigest
    case invalidWorkingDocument
    case invalidContextTable
    case invalidOperationLedger
    case invalidPendingSave
    case invalidTimestamp
    case externalDocumentConflict
    case staleRecoverySnapshot
    case fullRecoveryRequired
    case invalidTransaction
    // MARK: ADR-0012 Canonical Persistence & Quarantine Cases
    case workspaceQuarantined
    case persistenceIoError
    case unsupportedCatalogSchemaVersion
    case storageLeaseRequired
}

public enum CoreWorkspaceCommandOriginV1: Sendable, Equatable {
    case appPresentation(windowID: Int64)
    case appMCP(connectionID: UUID?)
    case standalone
    case externalReload
}

public enum CoreWorkspaceCommandKindV1: Sendable, Equatable {
    case create
    case replace
    case save
    case delete
    case resolveExternalConflict
}

public enum CoreWorkspaceSemanticPreflightDispositionV1: Sendable, Equatable {
    case proceed
    case unchanged
    case conflict
    case missing
    case unavailable
}

public struct CoreWorkspaceSemanticPreflightV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let commandKind: CoreWorkspaceCommandKindV1
    public let disposition: CoreWorkspaceSemanticPreflightDispositionV1
    public let catalogRevision: UInt64
    public let revisions: CoreWorkspaceProjectionRevisionState?
    public let health: CoreWorkspaceProjectionHealth?
    public let contentDigest: String?
    public let changedContextIDs: [UUID]
    public let addedContextIDs: [UUID]
    public let removedContextIDs: [UUID]
    public let externalDocumentDigest: String?
    public let protectedContextIDs: [UUID]
    public let diagnostic: String?

    public init(
        workspaceID: UUID,
        commandKind: CoreWorkspaceCommandKindV1,
        disposition: CoreWorkspaceSemanticPreflightDispositionV1,
        catalogRevision: UInt64,
        revisions: CoreWorkspaceProjectionRevisionState?,
        health: CoreWorkspaceProjectionHealth?,
        contentDigest: String?,
        changedContextIDs: [UUID] = [],
        addedContextIDs: [UUID] = [],
        removedContextIDs: [UUID] = [],
        externalDocumentDigest: String? = nil,
        protectedContextIDs: [UUID] = [],
        diagnostic: String?
    ) {
        self.workspaceID = workspaceID
        self.commandKind = commandKind
        self.disposition = disposition
        self.catalogRevision = catalogRevision
        self.revisions = revisions
        self.health = health
        self.contentDigest = contentDigest
        self.changedContextIDs = changedContextIDs
        self.addedContextIDs = addedContextIDs
        self.removedContextIDs = removedContextIDs
        self.externalDocumentDigest = externalDocumentDigest
        self.protectedContextIDs = protectedContextIDs
        self.diagnostic = diagnostic
    }
}

public enum CoreWorkspaceExternalObservationDispositionV1: Sendable, Equatable {
    case noChange
    case cleanReload
    case dirtyConflict
}

public enum CoreWorkspaceExternalObservationCandidateV1: Sendable, Equatable {
    case none
    case externalDocument
    case existingWorkingDocument
}

public enum CoreWorkspaceExternalObservationTransitionV1: Sendable, Equatable {
    case none
    case externalReload
    case conflictRebase
}

public struct CoreWorkspaceExternalObservationRecoveryRequestV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let expectedFileURL: URL
    public let expectedCatalogRevision: UInt64
    public let expectedWorkspaceRevision: UInt64
    public let currentDocumentDigest: String
    public let savedDigest: String
    public let externalDocumentBytes: Data
    public let updatedAt: Date

    public init(
        workspaceID: UUID,
        expectedFileURL: URL,
        expectedCatalogRevision: UInt64,
        expectedWorkspaceRevision: UInt64,
        currentDocumentDigest: String,
        savedDigest: String,
        externalDocumentBytes: Data,
        updatedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.expectedFileURL = expectedFileURL
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.currentDocumentDigest = currentDocumentDigest
        self.savedDigest = savedDigest
        self.externalDocumentBytes = externalDocumentBytes
        self.updatedAt = updatedAt
    }
}

public struct CoreWorkspaceExternalObservationRecoveryPlanV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let expectedFileURL: URL
    public let catalogRevision: UInt64
    public let workspaceRevision: UInt64
    public let aggregateGeneration: UInt64
    public let semanticGeneration: UInt64
    public let publicationSequence: UInt64
    public let semanticProjectionDigest: String
    public let currentDocumentDigest: String
    public let savedDigest: String
    public let externalDocumentDigest: String
    public let changedContextIDs: [UUID]
    public let addedContextIDs: [UUID]
    public let removedContextIDs: [UUID]
    public let disposition: CoreWorkspaceExternalObservationDispositionV1
    public let candidate: CoreWorkspaceExternalObservationCandidateV1
    public let transition: CoreWorkspaceExternalObservationTransitionV1
    public let updatedAt: Date
    public let revisionSidecarID: UUID?
    public let diagnostic: String?

    public init(
        workspaceID: UUID,
        expectedFileURL: URL,
        catalogRevision: UInt64,
        workspaceRevision: UInt64,
        aggregateGeneration: UInt64,
        semanticGeneration: UInt64,
        publicationSequence: UInt64,
        semanticProjectionDigest: String,
        currentDocumentDigest: String,
        savedDigest: String,
        externalDocumentDigest: String,
        changedContextIDs: [UUID],
        addedContextIDs: [UUID],
        removedContextIDs: [UUID],
        disposition: CoreWorkspaceExternalObservationDispositionV1,
        candidate: CoreWorkspaceExternalObservationCandidateV1,
        transition: CoreWorkspaceExternalObservationTransitionV1,
        updatedAt: Date,
        revisionSidecarID: UUID? = nil,
        diagnostic: String?
    ) {
        self.workspaceID = workspaceID
        self.expectedFileURL = expectedFileURL
        self.catalogRevision = catalogRevision
        self.workspaceRevision = workspaceRevision
        self.aggregateGeneration = aggregateGeneration
        self.semanticGeneration = semanticGeneration
        self.publicationSequence = publicationSequence
        self.semanticProjectionDigest = semanticProjectionDigest
        self.currentDocumentDigest = currentDocumentDigest
        self.savedDigest = savedDigest
        self.externalDocumentDigest = externalDocumentDigest
        self.changedContextIDs = changedContextIDs
        self.addedContextIDs = addedContextIDs
        self.removedContextIDs = removedContextIDs
        self.disposition = disposition
        self.candidate = candidate
        self.transition = transition
        self.updatedAt = updatedAt
        self.revisionSidecarID = revisionSidecarID
        self.diagnostic = diagnostic
    }
}

public enum CoreWorkspaceTabLocationV1: Sendable, Equatable {
    case composed
    case stashed
}

public struct CoreWorkspaceProtectedAgentIdentityV1: Sendable, Equatable {
    public let tabID: UUID
    public let location: CoreWorkspaceTabLocationV1
    public let activeAgentSessionID: UUID?
    public let isPinned: Bool

    public init(
        tabID: UUID,
        location: CoreWorkspaceTabLocationV1,
        activeAgentSessionID: UUID?,
        isPinned: Bool
    ) {
        self.tabID = tabID
        self.location = location
        self.activeAgentSessionID = activeAgentSessionID
        self.isPinned = isPinned
    }
}

public struct CoreWorkspaceCommandIdentityRequestV1: Sendable, Equatable {
    public static let maximumProtectedAgentIdentities = 256

    public let operationID: UUID
    public let expectedCatalogRevision: UInt64?
    public let expectedWorkspaceRevision: UInt64?
    public let expectedContextRevision: UInt64?
    public let origin: CoreWorkspaceCommandOriginV1
    public let commandKind: CoreWorkspaceCommandKindV1
    public let workspaceID: UUID
    public let fileURL: URL?
    public let contentDigest: String?
    public let acceptExternal: Bool?
    public let protectedAgentIdentities: [CoreWorkspaceProtectedAgentIdentityV1]

    public init(
        operationID: UUID,
        expectedCatalogRevision: UInt64?,
        expectedWorkspaceRevision: UInt64?,
        expectedContextRevision: UInt64?,
        origin: CoreWorkspaceCommandOriginV1,
        commandKind: CoreWorkspaceCommandKindV1,
        workspaceID: UUID,
        fileURL: URL?,
        contentDigest: String?,
        acceptExternal: Bool?,
        protectedAgentIdentities: [CoreWorkspaceProtectedAgentIdentityV1]
    ) {
        self.operationID = operationID
        self.expectedCatalogRevision = expectedCatalogRevision
        self.expectedWorkspaceRevision = expectedWorkspaceRevision
        self.expectedContextRevision = expectedContextRevision
        self.origin = origin
        self.commandKind = commandKind
        self.workspaceID = workspaceID
        self.fileURL = fileURL
        self.contentDigest = contentDigest
        self.acceptExternal = acceptExternal
        self.protectedAgentIdentities = protectedAgentIdentities
    }
}

public struct CoreWorkspaceCommandIdentityV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let commandKind: CoreWorkspaceCommandKindV1
    public let fingerprint: String

    public init(
        workspaceID: UUID,
        commandKind: CoreWorkspaceCommandKindV1,
        fingerprint: String
    ) {
        self.workspaceID = workspaceID
        self.commandKind = commandKind
        self.fingerprint = fingerprint
    }
}

public struct CoreWorkspaceRecordedOperationV1: Sendable, Equatable {
    public let operationID: UUID
    public let fingerprint: String
    public let recordedAt: TimeInterval
    public let disposition: String
    public let before: CoreWorkspaceProjectionRevisionState?
    public let after: CoreWorkspaceProjectionRevisionState?
    public let catalogRevision: UInt64
    public let resultingDigest: String?
    public let errorCode: String?
    public let diagnostic: String?

    public init(
        operationID: UUID,
        fingerprint: String,
        recordedAt: TimeInterval,
        disposition: String,
        before: CoreWorkspaceProjectionRevisionState?,
        after: CoreWorkspaceProjectionRevisionState?,
        catalogRevision: UInt64,
        resultingDigest: String?,
        errorCode: String?,
        diagnostic: String?
    ) {
        self.operationID = operationID
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
        self.disposition = disposition
        self.before = before
        self.after = after
        self.catalogRevision = catalogRevision
        self.resultingDigest = resultingDigest
        self.errorCode = errorCode
        self.diagnostic = diagnostic
    }
}

public enum CoreWorkspaceRecoveryArtifactEvidenceV1: Sendable, Equatable {
    case absent
    case present(Data)
    case unavailable(reason: String)
}

public struct CoreWorkspaceSemanticRecoveryEvidenceV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let journal: CoreWorkspaceRecoveryArtifactEvidenceV1
    public let savedDocument: CoreWorkspaceRecoveryArtifactEvidenceV1
    public let savedRevision: CoreWorkspaceRecoveryArtifactEvidenceV1

    public init(
        workspaceID: UUID,
        journal: CoreWorkspaceRecoveryArtifactEvidenceV1,
        savedDocument: CoreWorkspaceRecoveryArtifactEvidenceV1,
        savedRevision: CoreWorkspaceRecoveryArtifactEvidenceV1
    ) {
        self.workspaceID = workspaceID
        self.journal = journal
        self.savedDocument = savedDocument
        self.savedRevision = savedRevision
    }
}

public struct CoreWorkspaceSemanticDeletionRecoveryEvidenceV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let sidecar: CoreWorkspaceRecoveryArtifactEvidenceV1

    public init(workspaceID: UUID, sidecar: CoreWorkspaceRecoveryArtifactEvidenceV1) {
        self.workspaceID = workspaceID
        self.sidecar = sidecar
    }
}

public struct CoreWorkspaceSemanticFullRecoveryV1: Sendable, Equatable {
    public let catalogBytes: Data
    public let workspaces: [CoreWorkspaceSemanticRecoveryEvidenceV1]
    public let deletions: [CoreWorkspaceSemanticDeletionRecoveryEvidenceV1]

    public init(
        catalogBytes: Data,
        workspaces: [CoreWorkspaceSemanticRecoveryEvidenceV1],
        deletions: [CoreWorkspaceSemanticDeletionRecoveryEvidenceV1]
    ) {
        self.catalogBytes = catalogBytes
        self.workspaces = workspaces
        self.deletions = deletions
    }
}

public struct CoreWorkspaceSemanticTargetRecoveryV1: Sendable, Equatable {
    public let catalogBytes: Data
    public let workspaceID: UUID
    public let journal: CoreWorkspaceRecoveryArtifactEvidenceV1
    public let savedDocument: CoreWorkspaceRecoveryArtifactEvidenceV1
    public let savedRevision: CoreWorkspaceRecoveryArtifactEvidenceV1
    public let deletionSidecar: CoreWorkspaceRecoveryArtifactEvidenceV1

    public init(
        catalogBytes: Data,
        workspaceID: UUID,
        journal: CoreWorkspaceRecoveryArtifactEvidenceV1,
        savedDocument: CoreWorkspaceRecoveryArtifactEvidenceV1,
        savedRevision: CoreWorkspaceRecoveryArtifactEvidenceV1,
        deletionSidecar: CoreWorkspaceRecoveryArtifactEvidenceV1
    ) {
        self.catalogBytes = catalogBytes
        self.workspaceID = workspaceID
        self.journal = journal
        self.savedDocument = savedDocument
        self.savedRevision = savedRevision
        self.deletionSidecar = deletionSidecar
    }
}

public enum CoreWorkspaceSemanticRecoveryAdmissionDispositionV1: Sendable, Equatable {
    case installed
    case preserved
    case quarantined
}

public struct CoreWorkspaceSemanticContextRecoveryV1: Sendable, Equatable {
    public let contextID: UUID
    public let revisions: CoreWorkspaceProjectionRevisionState
}

public struct CoreWorkspaceSemanticActiveRecoveryV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let fileURL: URL
    public let documentBytes: Data
    public let documentDigest: String
    public let savedDigest: String
    public let revisions: CoreWorkspaceProjectionRevisionState
    public let contextRevisions: [CoreWorkspaceSemanticContextRecoveryV1]
    public let contextTombstones: [UUID: UInt64]
    public let operations: [CoreWorkspaceRecordedOperationV1]
    public let health: CoreWorkspaceProjectionHealth
    public let externalDocumentBytes: Data?
}

public struct CoreWorkspaceSemanticUnavailableRecoveryV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let fileURL: URL
    public let reason: String
}

public enum CoreWorkspaceSemanticRecoveryRowV1: Sendable, Equatable {
    case active(CoreWorkspaceSemanticActiveRecoveryV1)
    case unavailable(CoreWorkspaceSemanticUnavailableRecoveryV1)
    case deleted(workspaceID: UUID, fileURL: URL)
}

public enum CoreWorkspaceSemanticTargetDirectiveV1: Sendable, Equatable {
    case upsert(CoreWorkspaceSemanticActiveRecoveryV1)
    case unavailable(CoreWorkspaceSemanticUnavailableRecoveryV1)
    case delete(workspaceID: UUID, fileURL: URL)
    case noChange
}

public struct CoreWorkspaceSemanticJournalRewriteV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let expectedArtifactDigest: String
    public let replacementCanonicalBytes: Data
    public let replacementCanonicalDigest: String
}

public enum CoreWorkspaceSemanticRecoveryProjectionV1: Sendable, Equatable {
    case full(rows: [CoreWorkspaceSemanticRecoveryRowV1])
    case target(directive: CoreWorkspaceSemanticTargetDirectiveV1)
}

public struct CoreWorkspaceSemanticRecoveryPreviewV1: Sendable, Equatable {
    public let catalogRevision: UInt64
    public let catalogDigest: String
    public let targetWorkspaceID: UUID?
    public let globalHealth: CoreWorkspaceProjectionHealth
    public let admissionDisposition: CoreWorkspaceSemanticRecoveryAdmissionDispositionV1
    public let projection: CoreWorkspaceSemanticRecoveryProjectionV1
    public let journalRewrites: [CoreWorkspaceSemanticJournalRewriteV1]
    public let projectionDigest: String
}

public struct CoreWorkspaceSemanticRecoveryCommitV1: Sendable {
    public let admission: CorePreparedWorkspaceCommandAdmissionV1?
    public let admissionReceipt: CoreWorkspaceCommandAdmissionRecoveryReceiptV1?
    public let catalogRevision: UInt64
    public let catalogDigest: String
    public let targetWorkspaceID: UUID?
    public let admissionDisposition: CoreWorkspaceSemanticRecoveryAdmissionDispositionV1
    public let projectionDigest: String
}

public final class CorePreparedWorkspaceSemanticRecoveryV1: @unchecked Sendable {
    let rawRecovery: AgentryUniFFIRaw.CorePreparedWorkspaceSemanticRecoveryV1
    private let previewOperation: @Sendable () throws -> CoreWorkspaceSemanticRecoveryPreviewV1
    private let commitOperation: @Sendable () throws -> CoreWorkspaceSemanticRecoveryCommitV1
    private let closeOperation: @Sendable () -> Bool

    init(
        rawRecovery: AgentryUniFFIRaw.CorePreparedWorkspaceSemanticRecoveryV1,
        preview: @escaping @Sendable () throws -> CoreWorkspaceSemanticRecoveryPreviewV1,
        commit: @escaping @Sendable () throws -> CoreWorkspaceSemanticRecoveryCommitV1,
        close: @escaping @Sendable () -> Bool
    ) {
        self.rawRecovery = rawRecovery
        previewOperation = preview
        commitOperation = commit
        closeOperation = close
    }

    deinit {
        _ = closeOperation()
    }

    public func preview() throws -> CoreWorkspaceSemanticRecoveryPreviewV1 {
        try previewOperation()
    }

    public func commit() throws -> CoreWorkspaceSemanticRecoveryCommitV1 {
        try commitOperation()
    }

    @discardableResult
    public func close() -> Bool {
        closeOperation()
    }
}

public enum CoreWorkspaceCommandAdmissionLookupScopeV1: Sendable, Equatable {
    case workspace
    case global
}

public enum CoreWorkspaceCommandLifecycleDirective: Sendable, Equatable {
    case continueExecution
    case cancelled
    case deadlineExceeded
    case shutdownRequested
}

public enum CoreWorkspaceCommandAdmissionAcquisitionV1: Sendable {
    case claimed(
        identity: CoreWorkspaceCommandIdentityV1,
        claim: CoreWorkspaceCommandExecutionClaimV1,
        generation: UInt64
    )
    case pending(identity: CoreWorkspaceCommandIdentityV1, generation: UInt64)
    case collision(
        identity: CoreWorkspaceCommandIdentityV1,
        scope: CoreWorkspaceCommandAdmissionLookupScopeV1?
    )
    case replay(
        identity: CoreWorkspaceCommandIdentityV1,
        scope: CoreWorkspaceCommandAdmissionLookupScopeV1,
        operation: CoreWorkspaceRecordedOperationV1
    )
}

public final class CoreWorkspaceCommandExecutionClaimV1: @unchecked Sendable {
    let rawClaim: AgentryUniFFIRaw.CoreWorkspaceCommandExecutionClaimV1
    private let semanticPreflightOperation: @Sendable (
        CoreWorkspaceCommandIdentityRequestV1,
        Data?,
        Data?
    ) throws -> CoreWorkspaceSemanticPreflightV1
    private let checkpointOperation: @Sendable () throws
        -> CoreWorkspaceCommandLifecycleDirective
    private let finalizeTransientOperation: @Sendable (CoreWorkspaceRecordedOperationV1) throws
        -> CoreWorkspaceRecordedOperationV1
    private let abandonOperation: @Sendable () throws -> Bool
    private let closeOperation: @Sendable () -> Void

    init(
        rawClaim: AgentryUniFFIRaw.CoreWorkspaceCommandExecutionClaimV1,
        semanticPreflight: @escaping @Sendable (
            CoreWorkspaceCommandIdentityRequestV1,
            Data?,
            Data?
        ) throws -> CoreWorkspaceSemanticPreflightV1,
        checkpoint: @escaping @Sendable () throws -> CoreWorkspaceCommandLifecycleDirective,
        finalizeTransient: @escaping @Sendable (CoreWorkspaceRecordedOperationV1) throws
            -> CoreWorkspaceRecordedOperationV1,
        abandon: @escaping @Sendable () throws -> Bool,
        close: @escaping @Sendable () -> Void
    ) {
        self.rawClaim = rawClaim
        semanticPreflightOperation = semanticPreflight
        checkpointOperation = checkpoint
        finalizeTransientOperation = finalizeTransient
        abandonOperation = abandon
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func semanticPreflight(
        _ request: CoreWorkspaceCommandIdentityRequestV1,
        candidateDocumentBytes: Data? = nil,
        externalDocumentBytes: Data? = nil
    ) throws -> CoreWorkspaceSemanticPreflightV1 {
        try semanticPreflightOperation(request, candidateDocumentBytes, externalDocumentBytes)
    }

    public func checkpoint() throws -> CoreWorkspaceCommandLifecycleDirective {
        try checkpointOperation()
    }

    public func finalizeTransient(
        operation: CoreWorkspaceRecordedOperationV1
    ) throws -> CoreWorkspaceRecordedOperationV1 {
        try finalizeTransientOperation(operation)
    }

    @discardableResult
    public func abandon() throws -> Bool {
        try abandonOperation()
    }

    public func close() {
        closeOperation()
    }
}

public struct CoreWorkspaceCommandAdmissionDiagnosticsV1: Sendable, Equatable {
    public let globalOperationCount: UInt64
    public let workspaceCount: UInt64
    public let workspaceOperationCount: UInt64

    public init(
        globalOperationCount: UInt64,
        workspaceCount: UInt64,
        workspaceOperationCount: UInt64
    ) {
        self.globalOperationCount = globalOperationCount
        self.workspaceCount = workspaceCount
        self.workspaceOperationCount = workspaceOperationCount
    }
}

public struct CoreWorkspaceCommandAdmissionRecoveryReceiptV1: Sendable, Equatable {
    public let catalogRevision: UInt64
    public let catalogDigest: String
    public let targetWorkspaceID: UUID?
    public let diagnostics: CoreWorkspaceCommandAdmissionDiagnosticsV1

    public init(
        catalogRevision: UInt64,
        catalogDigest: String,
        targetWorkspaceID: UUID?,
        diagnostics: CoreWorkspaceCommandAdmissionDiagnosticsV1
    ) {
        self.catalogRevision = catalogRevision
        self.catalogDigest = catalogDigest
        self.targetWorkspaceID = targetWorkspaceID
        self.diagnostics = diagnostics
    }
}

public struct CoreWorkspaceAuthorityPublicationDraft: Sendable, Equatable {
    public let catalogRevision: UInt64
    public let kind: CoreWorkspaceProjectionPublicationKind
    public let workspaceID: UUID?
    public let contextID: UUID?
    public let operationID: UUID?
    public let revisions: CoreWorkspaceProjectionRevisionState?

    public init(
        catalogRevision: UInt64,
        kind: CoreWorkspaceProjectionPublicationKind,
        workspaceID: UUID?,
        contextID: UUID?,
        operationID: UUID?,
        revisions: CoreWorkspaceProjectionRevisionState?
    ) {
        self.catalogRevision = catalogRevision
        self.kind = kind
        self.workspaceID = workspaceID
        self.contextID = contextID
        self.operationID = operationID
        self.revisions = revisions
    }
}

public struct CoreWorkspaceAuthorityPublicationReceipt: Sendable, Equatable {
    public let previousGeneration: UInt64
    public let generation: UInt64
    public let projectionChanged: Bool
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
    public let previousCatalogRevision: UInt64
    public let previousPublicationSequence: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let eventLogFloorSequence: UInt64
    public let eventLogCount: UInt64
    public let projectionDigest: String
    public let event: CoreWorkspaceProjectionPublicationEvent

    public init(
        previousGeneration: UInt64,
        generation: UInt64,
        projectionChanged: Bool,
        workspaceCount: UInt64,
        retainedBytes: UInt64,
        previousCatalogRevision: UInt64,
        previousPublicationSequence: UInt64,
        catalogRevision: UInt64,
        publicationSequence: UInt64,
        eventLogFloorSequence: UInt64,
        eventLogCount: UInt64,
        projectionDigest: String,
        event: CoreWorkspaceProjectionPublicationEvent
    ) {
        self.previousGeneration = previousGeneration
        self.generation = generation
        self.projectionChanged = projectionChanged
        self.workspaceCount = workspaceCount
        self.retainedBytes = retainedBytes
        self.previousCatalogRevision = previousCatalogRevision
        self.previousPublicationSequence = previousPublicationSequence
        self.catalogRevision = catalogRevision
        self.publicationSequence = publicationSequence
        self.eventLogFloorSequence = eventLogFloorSequence
        self.eventLogCount = eventLogCount
        self.projectionDigest = projectionDigest
        self.event = event
    }
}

public struct CoreWorkspaceClaimlessAuthorityPublicationReceipt: Sendable, Equatable {
    public let previousSemanticGeneration: UInt64
    public let semanticGeneration: UInt64
    public let previousPublicationSequence: UInt64
    public let publicationSequence: UInt64
    public let catalogRevision: UInt64
    public let projectionDigest: String
    public let event: CoreWorkspaceProjectionPublicationEvent

    public init(
        previousSemanticGeneration: UInt64,
        semanticGeneration: UInt64,
        previousPublicationSequence: UInt64,
        publicationSequence: UInt64,
        catalogRevision: UInt64,
        projectionDigest: String,
        event: CoreWorkspaceProjectionPublicationEvent
    ) {
        self.previousSemanticGeneration = previousSemanticGeneration
        self.semanticGeneration = semanticGeneration
        self.previousPublicationSequence = previousPublicationSequence
        self.publicationSequence = publicationSequence
        self.catalogRevision = catalogRevision
        self.projectionDigest = projectionDigest
        self.event = event
    }
}

public struct CoreWorkspaceAuthorityProjectionSyncReceipt: Sendable, Equatable {
    public let previousGeneration: UInt64
    public let generation: UInt64
    public let projectionChanged: Bool
    public let workspaceCount: UInt64
    public let retainedBytes: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let projectionDigest: String

    public init(
        previousGeneration: UInt64,
        generation: UInt64,
        projectionChanged: Bool,
        workspaceCount: UInt64,
        retainedBytes: UInt64,
        catalogRevision: UInt64,
        publicationSequence: UInt64,
        projectionDigest: String
    ) {
        self.previousGeneration = previousGeneration
        self.generation = generation
        self.projectionChanged = projectionChanged
        self.workspaceCount = workspaceCount
        self.retainedBytes = retainedBytes
        self.catalogRevision = catalogRevision
        self.publicationSequence = publicationSequence
        self.projectionDigest = projectionDigest
    }
}

public struct CoreWorkspaceAuthorityRead: Sendable, Equatable {
    public let projection: CoreWorkspaceDocumentProjectionV1?
    public let contentDigest: String?
    public let generation: UInt64
    public let catalogRevision: UInt64
    public let publicationSequence: UInt64
    public let eventLogFloorSequence: UInt64
    public let eventLogCount: UInt64
    public let projectionDigest: String

    public init(
        projection: CoreWorkspaceDocumentProjectionV1?,
        contentDigest: String?,
        generation: UInt64,
        catalogRevision: UInt64,
        publicationSequence: UInt64,
        eventLogFloorSequence: UInt64,
        eventLogCount: UInt64,
        projectionDigest: String
    ) {
        self.projection = projection
        self.contentDigest = contentDigest
        self.generation = generation
        self.catalogRevision = catalogRevision
        self.publicationSequence = publicationSequence
        self.eventLogFloorSequence = eventLogFloorSequence
        self.eventLogCount = eventLogCount
        self.projectionDigest = projectionDigest
    }
}

public final class CorePreparedWorkspaceCommandAdmissionV1: @unchecked Sendable {
    let rawAdmission: AgentryUniFFIRaw.CorePreparedWorkspaceCommandAdmissionV1
    private let acquireOperation: @Sendable (CoreWorkspaceCommandIdentityRequestV1, UInt64?) throws
        -> CoreWorkspaceCommandAdmissionAcquisitionV1
    private let cancelOperation: @Sendable (OperationID) throws -> CoreCancellation
    private let semanticFullRecoveryOperation: @Sendable (CoreWorkspaceSemanticFullRecoveryV1) throws
        -> CorePreparedWorkspaceSemanticRecoveryV1
    private let semanticTargetRecoveryOperation: @Sendable (CoreWorkspaceSemanticTargetRecoveryV1) throws
        -> CorePreparedWorkspaceSemanticRecoveryV1
    private let externalObservationRecoveryOperation: @Sendable (
        CoreWorkspaceExternalObservationRecoveryRequestV1
    ) throws -> CoreWorkspaceExternalObservationRecoveryPlanV1
    private let diagnosticsOperation: @Sendable () throws
        -> CoreWorkspaceCommandAdmissionDiagnosticsV1
    private let publishAuthorityStateOperation: @Sendable (
        [CoreWorkspaceProjectionPublishedWorkspace],
        CoreWorkspaceAuthorityPublicationDraft
    ) throws -> CoreWorkspaceAuthorityPublicationReceipt
    private let synchronizeAuthorityProjectionOperation: @Sendable (
        [CoreWorkspaceProjectionPublishedWorkspace]
    ) throws -> CoreWorkspaceAuthorityProjectionSyncReceipt
    private let authorityReadOperation: @Sendable (UUID) throws -> CoreWorkspaceAuthorityRead
    private let closeOperation: @Sendable () -> Void

    init(
        rawAdmission: AgentryUniFFIRaw.CorePreparedWorkspaceCommandAdmissionV1,
        acquire: @escaping @Sendable (CoreWorkspaceCommandIdentityRequestV1, UInt64?) throws
            -> CoreWorkspaceCommandAdmissionAcquisitionV1,
        cancel: @escaping @Sendable (OperationID) throws -> CoreCancellation,
        prepareSemanticFullRecovery: @escaping @Sendable (CoreWorkspaceSemanticFullRecoveryV1) throws
            -> CorePreparedWorkspaceSemanticRecoveryV1,
        prepareSemanticTargetRecovery: @escaping @Sendable (CoreWorkspaceSemanticTargetRecoveryV1) throws
            -> CorePreparedWorkspaceSemanticRecoveryV1,
        prepareExternalObservationRecovery: @escaping @Sendable (
            CoreWorkspaceExternalObservationRecoveryRequestV1
        ) throws -> CoreWorkspaceExternalObservationRecoveryPlanV1,
        diagnostics: @escaping @Sendable () throws -> CoreWorkspaceCommandAdmissionDiagnosticsV1,
        publishAuthorityState: @escaping @Sendable (
            [CoreWorkspaceProjectionPublishedWorkspace],
            CoreWorkspaceAuthorityPublicationDraft
        ) throws -> CoreWorkspaceAuthorityPublicationReceipt,
        synchronizeAuthorityProjection: @escaping @Sendable (
            [CoreWorkspaceProjectionPublishedWorkspace]
        ) throws -> CoreWorkspaceAuthorityProjectionSyncReceipt,
        authorityRead: @escaping @Sendable (UUID) throws -> CoreWorkspaceAuthorityRead,
        close: @escaping @Sendable () -> Void
    ) {
        self.rawAdmission = rawAdmission
        acquireOperation = acquire
        cancelOperation = cancel
        semanticFullRecoveryOperation = prepareSemanticFullRecovery
        semanticTargetRecoveryOperation = prepareSemanticTargetRecovery
        externalObservationRecoveryOperation = prepareExternalObservationRecovery
        diagnosticsOperation = diagnostics
        publishAuthorityStateOperation = publishAuthorityState
        synchronizeAuthorityProjectionOperation = synchronizeAuthorityProjection
        authorityReadOperation = authorityRead
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func acquire(
        _ request: CoreWorkspaceCommandIdentityRequestV1,
        deadlineUnixMilliseconds: UInt64? = nil
    ) throws -> CoreWorkspaceCommandAdmissionAcquisitionV1 {
        try acquireOperation(request, deadlineUnixMilliseconds)
    }

    @discardableResult
    public func cancel(_ operationID: OperationID) throws -> CoreCancellation {
        try cancelOperation(operationID)
    }

    public func prepareSemanticFullRecovery(
        _ recovery: CoreWorkspaceSemanticFullRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        try semanticFullRecoveryOperation(recovery)
    }

    public func prepareSemanticTargetRecovery(
        _ recovery: CoreWorkspaceSemanticTargetRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        try semanticTargetRecoveryOperation(recovery)
    }

    public func prepareExternalObservationRecovery(
        _ request: CoreWorkspaceExternalObservationRecoveryRequestV1
    ) throws -> CoreWorkspaceExternalObservationRecoveryPlanV1 {
        try externalObservationRecoveryOperation(request)
    }

    public func diagnostics() throws -> CoreWorkspaceCommandAdmissionDiagnosticsV1 {
        try diagnosticsOperation()
    }

    public func publishAuthorityState(
        workspaces: [CoreWorkspaceProjectionPublishedWorkspace],
        draft: CoreWorkspaceAuthorityPublicationDraft
    ) throws -> CoreWorkspaceAuthorityPublicationReceipt {
        try publishAuthorityStateOperation(workspaces, draft)
    }

    public func synchronizeAuthorityProjection(
        workspaces: [CoreWorkspaceProjectionPublishedWorkspace]
    ) throws -> CoreWorkspaceAuthorityProjectionSyncReceipt {
        try synchronizeAuthorityProjectionOperation(workspaces)
    }

    public func authorityRead(workspaceID: UUID) throws -> CoreWorkspaceAuthorityRead {
        try authorityReadOperation(workspaceID)
    }

    public func close() {
        closeOperation()
    }
}

public struct CoreWorkspaceCatalogValidationV1: Sendable, Equatable {
    public let catalogVersion: UInt16
    public let revision: UInt64
    public let entryCount: UInt64
    public let deletionCount: UInt64
    public let contentDigest: String
    public let canonicalBytes: Data

    public init(
        catalogVersion: UInt16,
        revision: UInt64,
        entryCount: UInt64,
        deletionCount: UInt64,
        contentDigest: String,
        canonicalBytes: Data
    ) {
        self.catalogVersion = catalogVersion
        self.revision = revision
        self.entryCount = entryCount
        self.deletionCount = deletionCount
        self.contentDigest = contentDigest
        self.canonicalBytes = canonicalBytes
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

public enum CoreWorkspaceCommandResultDispositionV1: Sendable, Equatable {
    case applied
    case unchanged
    case deleted
}

public struct CoreWorkspaceCommandResultV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let operation: CoreWorkspaceRecordedOperationV1
    public let disposition: CoreWorkspaceCommandResultDispositionV1
    public let before: CoreWorkspaceProjectionRevisionState?
    public let after: CoreWorkspaceProjectionRevisionState?
    public let resultingDigest: String?
    public let catalogRevision: UInt64
    public let publicationKind: CoreWorkspaceProjectionPublicationKind
    public let contextID: UUID?

    public init(
        workspaceID: UUID,
        operation: CoreWorkspaceRecordedOperationV1,
        disposition: CoreWorkspaceCommandResultDispositionV1,
        before: CoreWorkspaceProjectionRevisionState?,
        after: CoreWorkspaceProjectionRevisionState?,
        resultingDigest: String?,
        catalogRevision: UInt64,
        publicationKind: CoreWorkspaceProjectionPublicationKind,
        contextID: UUID?
    ) {
        self.workspaceID = workspaceID
        self.operation = operation
        self.disposition = disposition
        self.before = before
        self.after = after
        self.resultingDigest = resultingDigest
        self.catalogRevision = catalogRevision
        self.publicationKind = publicationKind
        self.contextID = contextID
    }
}

public enum CoreWorkspacePendingSaveRecoveryV1: Sendable, Equatable {
    case noPending(CoreWorkspaceWorkingJournalValidationV1)
    case pendingNotCommitted(CoreWorkspaceWorkingJournalValidationV1)
    case committed(
        cleanJournal: CoreWorkspaceWorkingJournalValidationV1,
        documentDigest: String
    )
}

/// Short-lived synchronous capability for validating working journals while a caller holds a
/// non-suspending filesystem transaction. Every call carries the exact runtime identity captured
/// during preparation; Rust rejects stopped, poisoned, or replaced runtimes before returning bytes.
public struct CorePreparedWorkspaceWorkingJournalValidatorV1: Sendable {
    private let context: CoreDirectComputeOperationContext

    init(context: CoreDirectComputeOperationContext) {
        self.context = context
    }

    public func commandIdentity(
        _ request: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceCommandIdentityV1 {
        guard request.protectedAgentIdentities.count
            <= CoreWorkspaceCommandIdentityRequestV1.maximumProtectedAgentIdentities
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceCommandIdentityV1(
            identity: context.identity,
            request: request
        )
    }

    public func prepareInitialSemanticRecovery(
        _ recovery: CoreWorkspaceSemanticFullRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        guard recovery.workspaces.count <= 65_536,
              recovery.deletions.count <= 65_536
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceSemanticInitialRecoveryPrepareV1(
            identity: context.identity,
            recovery: recovery
        )
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

    public func validateDeletionTombstone(
        _ artifactBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        try workspacePersistenceMetadata(artifactBytes) { identity, payloadBytes in
            try context.transport.workspaceDeletionTombstoneValidateV1(
                identity: identity,
                payloadBytes: payloadBytes
            )
        }
    }

    public func validateCatalog(
        _ catalogBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        guard catalogBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceCatalogValidateV1(
            identity: context.identity,
            catalogBytes: catalogBytes
        )
    }

    public func seedCatalog(
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        guard seedRequestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceCatalogSeedV1(
            identity: context.identity,
            seedRequestBytes: seedRequestBytes
        )
    }

    public func createWorkspaceDirect(
        storageDirectory: String,
        workspaceID: UUID,
        workspaceName: String,
        documentBytes: Data,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        try context.transport.workspaceCreateDirectV1(
            identity: context.identity,
            storageDirectory: storageDirectory,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            documentBytes: documentBytes,
            expectedCatalogRevision: expectedCatalogRevision,
            operationID: operationID,
            fingerprint: fingerprint
        )
    }

    public func saveWorkspaceDirect(
        storageDirectory: String,
        workspaceID: UUID,
        documentBytes: Data,
        expectedWorkingRevision: UInt64,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        try context.transport.workspaceSaveDirectV1(
            identity: context.identity,
            storageDirectory: storageDirectory,
            workspaceID: workspaceID,
            documentBytes: documentBytes,
            expectedWorkingRevision: expectedWorkingRevision,
            expectedCatalogRevision: expectedCatalogRevision,
            operationID: operationID,
            fingerprint: fingerprint
        )
    }

    public func deleteWorkspaceDirect(
        storageDirectory: String,
        workspaceID: UUID,
        expectedCatalogRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        try context.transport.workspaceDeleteDirectV1(
            identity: context.identity,
            storageDirectory: storageDirectory,
            workspaceID: workspaceID,
            expectedCatalogRevision: expectedCatalogRevision,
            operationID: operationID
        )
    }

    public func mutateWorkingDirect(
        storageDirectory: String,
        workspaceID: UUID,
        candidateDocumentBytes: Data,
        expectedWorkingRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        try context.transport.workspaceMutateWorkingDirectV1(
            identity: context.identity,
            storageDirectory: storageDirectory,
            workspaceID: workspaceID,
            candidateDocumentBytes: candidateDocumentBytes,
            expectedWorkingRevision: expectedWorkingRevision,
            operationID: operationID
        )
    }

    public func isWorkspaceQuarantined(
        storageDirectory: String,
        workspaceID: UUID
    ) throws -> (isQuarantined: Bool, reason: String?) {
        try context.transport.workspaceIsQuarantinedV1(
            identity: context.identity,
            storageDirectory: storageDirectory,
            workspaceID: workspaceID
        )
    }

    public func quarantinedWorkspaces(
        storageDirectory: String
    ) throws -> [(workspaceID: UUID, reason: String)] {
        try context.transport.workspaceQuarantinedWorkspacesV1(
            identity: context.identity,
            storageDirectory: storageDirectory
        )
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

    public func resolvePendingSave(
        rawJournalBytes: Data,
        expectedWorkspaceID: UUID,
        expectedFileURL: URL,
        documentBytes: Data?
    ) throws -> CoreWorkspacePendingSaveRecoveryV1 {
        guard rawJournalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              documentBytes?.count ?? 0 <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspacePendingSaveResolveV1(
            identity: context.identity,
            rawJournalBytes: rawJournalBytes,
            expectedWorkspaceID: expectedWorkspaceID,
            expectedFileURL: expectedFileURL,
            documentBytes: documentBytes
        )
    }

    public func seedWorkingJournal(
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        guard seedRequestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceWorkingJournalSeedV1(
            identity: context.identity,
            seedRequestBytes: seedRequestBytes
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
    func workspaceSemanticInitialRecoveryPrepareV1(
        identity _: CoreRuntimeIdentity,
        recovery _: CoreWorkspaceSemanticFullRecoveryV1
    ) throws -> CorePreparedWorkspaceSemanticRecoveryV1 {
        throw CoreTransportError.unexpected(
            "workspace-semantic-recovery-v1 transport is unavailable"
        )
    }

    func workspaceCommandIdentityV1(
        identity _: CoreRuntimeIdentity,
        request _: CoreWorkspaceCommandIdentityRequestV1
    ) throws -> CoreWorkspaceCommandIdentityV1 {
        throw CoreTransportError.unexpected("workspace-command-identity-v1 transport is unavailable")
    }

    func workspaceDocumentProjectionV1(
        identity: CoreRuntimeIdentity,
        documentBytes: Data
    ) throws -> CoreWorkspaceDocumentProjectionV1 {
        throw CoreTransportError.unexpected("workspace document projection transport is unavailable")
    }

    func workspaceSavedRevisionValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        throw CoreTransportError.unexpected("workspace saved revision validation transport is unavailable")
    }

    func workspaceDeletionTombstoneValidateV1(
        identity: CoreRuntimeIdentity,
        payloadBytes: Data
    ) throws -> CoreWorkspacePersistenceMetadataValidationV1 {
        throw CoreTransportError.unexpected("workspace deletion tombstone validation transport is unavailable")
    }

    func workspaceCatalogValidateV1(
        identity: CoreRuntimeIdentity,
        catalogBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        throw CoreTransportError.unexpected("workspace catalog validation transport is unavailable")
    }

    func workspaceCatalogSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        throw CoreTransportError.unexpected("workspace catalog seed transport is unavailable")
    }

    func workspaceWorkingJournalValidateV1(
        identity: CoreRuntimeIdentity,
        journalBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        throw CoreTransportError.unexpected("workspace working journal transport is unavailable")
    }

    func workspaceWorkingJournalSeedV1(
        identity: CoreRuntimeIdentity,
        seedRequestBytes: Data
    ) throws -> CoreWorkspaceWorkingJournalValidationV1 {
        throw CoreTransportError.unexpected("workspace working journal seed transport is unavailable")
    }

    func workspacePendingSaveResolveV1(
        identity: CoreRuntimeIdentity,
        rawJournalBytes: Data,
        expectedWorkspaceID: UUID,
        expectedFileURL: URL,
        documentBytes: Data?
    ) throws -> CoreWorkspacePendingSaveRecoveryV1 {
        throw CoreTransportError.unexpected("workspace pending save recovery transport is unavailable")
    }

    func workspaceCreateDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        workspaceName: String,
        documentBytes: Data,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        throw CoreTransportError.unexpected("workspace create direct transport is unavailable")
    }

    func workspaceSaveDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        documentBytes: Data,
        expectedWorkingRevision: UInt64,
        expectedCatalogRevision: UInt64,
        operationID: UUID,
        fingerprint: String?
    ) throws -> CoreWorkspaceCommandResultV1 {
        throw CoreTransportError.unexpected("workspace save direct transport is unavailable")
    }

    func workspaceDeleteDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        expectedCatalogRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        throw CoreTransportError.unexpected("workspace delete direct transport is unavailable")
    }

    func workspaceMutateWorkingDirectV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID,
        candidateDocumentBytes: Data,
        expectedWorkingRevision: UInt64,
        operationID: UUID
    ) throws -> CoreWorkspaceCommandResultV1 {
        throw CoreTransportError.unexpected("workspace mutate working direct transport is unavailable")
    }

    func workspaceIsQuarantinedV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String,
        workspaceID: UUID
    ) throws -> (isQuarantined: Bool, reason: String?) {
        throw CoreTransportError.unexpected("workspace is quarantined transport is unavailable")
    }

    func workspaceQuarantinedWorkspacesV1(
        identity: CoreRuntimeIdentity,
        storageDirectory: String
    ) throws -> [(workspaceID: UUID, reason: String)] {
        throw CoreTransportError.unexpected("workspace quarantined workspaces transport is unavailable")
    }
}
