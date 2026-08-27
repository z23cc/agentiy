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
    case externalDocumentConflict
    case invalidTransaction
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

public enum CoreWorkspaceJournalMutationActionKindV1: Sendable, Equatable {
    case writeJournal
    case writeSavedRevision
}

public enum CoreWorkspaceJournalMutationFinalizationV1: Sendable, Equatable {
    case finalized
    case revisionSidecarMissing
}

public struct CoreWorkspaceJournalMutationCommitReceiptV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let requestDigest: String
    public let catalogRevision: UInt64
    public let committedJournal: CoreWorkspaceWorkingJournalValidationV1
    public let savedRevision: CoreWorkspacePersistenceMetadataValidationV1?
    public let resultingWorkingRevision: UInt64
    public let resultingSavedRevision: UInt64

    public init(
        workspaceID: UUID,
        requestDigest: String,
        catalogRevision: UInt64,
        committedJournal: CoreWorkspaceWorkingJournalValidationV1,
        savedRevision: CoreWorkspacePersistenceMetadataValidationV1?,
        resultingWorkingRevision: UInt64,
        resultingSavedRevision: UInt64
    ) {
        self.workspaceID = workspaceID
        self.requestDigest = requestDigest
        self.catalogRevision = catalogRevision
        self.committedJournal = committedJournal
        self.savedRevision = savedRevision
        self.resultingWorkingRevision = resultingWorkingRevision
        self.resultingSavedRevision = resultingSavedRevision
    }
}

public enum CoreWorkspaceJournalMutationDirectiveV1: Sendable, Equatable {
    case action(
        actionID: UInt64,
        requestDigest: String,
        kind: CoreWorkspaceJournalMutationActionKindV1,
        expectedRawJournalDigest: String?,
        canonicalBytes: Data,
        contentDigest: String,
        logicalExpectedRevision: UInt64?,
        authorityReceipt: CoreWorkspaceJournalMutationCommitReceiptV1?
    )
    case committed(
        receipt: CoreWorkspaceJournalMutationCommitReceiptV1,
        finalization: CoreWorkspaceJournalMutationFinalizationV1
    )
    case failed(CoreWorkspaceSaveFailureV1)
}

public enum CoreWorkspaceSaveActionKindV1: Sendable, Equatable {
    case writePendingJournal
    case publishWorkspaceDocument
    case writeCommittedJournal
    case writeSavedRevision
}

public enum CoreWorkspaceSaveFinalizationV1: Sendable, Equatable {
    case finalized
    case pendingJournalRetained
    case revisionSidecarMissing
}

public enum CoreWorkspaceSaveFailureV1: Sendable, Equatable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

public struct CoreWorkspaceSaveCommitReceiptV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let operationID: UUID
    public let requestDigest: String
    public let catalogRevision: UInt64
    public let documentDigest: String
    public let committedJournal: CoreWorkspaceWorkingJournalValidationV1
    public let savedRevision: CoreWorkspacePersistenceMetadataValidationV1
    public let resultingWorkingRevision: UInt64
    public let resultingSavedRevision: UInt64

    public init(
        workspaceID: UUID,
        operationID: UUID,
        requestDigest: String,
        catalogRevision: UInt64,
        documentDigest: String,
        committedJournal: CoreWorkspaceWorkingJournalValidationV1,
        savedRevision: CoreWorkspacePersistenceMetadataValidationV1,
        resultingWorkingRevision: UInt64,
        resultingSavedRevision: UInt64
    ) {
        self.workspaceID = workspaceID
        self.operationID = operationID
        self.requestDigest = requestDigest
        self.catalogRevision = catalogRevision
        self.documentDigest = documentDigest
        self.committedJournal = committedJournal
        self.savedRevision = savedRevision
        self.resultingWorkingRevision = resultingWorkingRevision
        self.resultingSavedRevision = resultingSavedRevision
    }
}

public enum CoreWorkspaceSaveDirectiveV1: Sendable, Equatable {
    case action(
        actionID: UInt64,
        requestDigest: String,
        kind: CoreWorkspaceSaveActionKindV1,
        expectedRawJournalDigest: String?,
        canonicalBytes: Data,
        contentDigest: String,
        logicalExpectedRevision: UInt64?,
        authorityReceipt: CoreWorkspaceSaveCommitReceiptV1?
    )
    case committed(
        receipt: CoreWorkspaceSaveCommitReceiptV1,
        finalization: CoreWorkspaceSaveFinalizationV1
    )
    case failed(CoreWorkspaceSaveFailureV1)
}

public enum CoreWorkspaceSaveActionReportV1: Sendable, Equatable {
    case success(actionID: UInt64, writtenDigest: String)
    case cancelled(actionID: UInt64)
    case stateConflict(actionID: UInt64, expected: UInt64, actual: UInt64)
    case writeFailed(actionID: UInt64)
}

public enum CoreWorkspaceCreateActionKindV1: Sendable, Equatable {
    case writePendingJournal
    case publishWorkspaceDocument
    case writeCommittedJournal
    case writeSavedRevision
    case removeDeletionSidecar
    case publishCatalog
}

public enum CoreWorkspaceCreateFailureV1: Sendable, Equatable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

public struct CoreWorkspaceCreateCommitReceiptV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let operationID: UUID
    public let requestDigest: String
    public let documentDigest: String
    public let catalog: CoreWorkspaceCatalogValidationV1
    public let committedJournal: CoreWorkspaceWorkingJournalValidationV1
    public let savedRevision: CoreWorkspacePersistenceMetadataValidationV1?

    public init(
        workspaceID: UUID,
        operationID: UUID,
        requestDigest: String,
        documentDigest: String,
        catalog: CoreWorkspaceCatalogValidationV1,
        committedJournal: CoreWorkspaceWorkingJournalValidationV1,
        savedRevision: CoreWorkspacePersistenceMetadataValidationV1?
    ) {
        self.workspaceID = workspaceID
        self.operationID = operationID
        self.requestDigest = requestDigest
        self.documentDigest = documentDigest
        self.catalog = catalog
        self.committedJournal = committedJournal
        self.savedRevision = savedRevision
    }
}

public enum CoreWorkspaceCreateDirectiveV1: Sendable, Equatable {
    case action(
        actionID: UInt64,
        requestDigest: String,
        kind: CoreWorkspaceCreateActionKindV1,
        expectedRawDigest: String?,
        canonicalBytes: Data,
        contentDigest: String,
        logicalExpectedRevision: UInt64?,
        authorityReceipt: CoreWorkspaceCreateCommitReceiptV1?
    )
    case committed(CoreWorkspaceCreateCommitReceiptV1)
    case failed(CoreWorkspaceCreateFailureV1)
}

public enum CoreWorkspaceDeleteFailureV1: Sendable, Equatable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

public struct CoreWorkspaceDeleteCommitReceiptV1: Sendable, Equatable {
    public let workspaceID: UUID
    public let operationID: UUID
    public let requestDigest: String
    public let catalog: CoreWorkspaceCatalogValidationV1
    public let tombstone: CoreWorkspacePersistenceMetadataValidationV1

    public init(
        workspaceID: UUID,
        operationID: UUID,
        requestDigest: String,
        catalog: CoreWorkspaceCatalogValidationV1,
        tombstone: CoreWorkspacePersistenceMetadataValidationV1
    ) {
        self.workspaceID = workspaceID
        self.operationID = operationID
        self.requestDigest = requestDigest
        self.catalog = catalog
        self.tombstone = tombstone
    }
}

public enum CoreWorkspaceDeleteDirectiveV1: Sendable, Equatable {
    case publishCatalog(
        actionID: UInt64,
        requestDigest: String,
        expectedRawCatalogDigest: String?,
        catalog: CoreWorkspaceCatalogValidationV1,
        logicalExpectedRevision: UInt64,
        authorityReceipt: CoreWorkspaceDeleteCommitReceiptV1
    )
    case committed(CoreWorkspaceDeleteCommitReceiptV1)
    case failed(CoreWorkspaceDeleteFailureV1)
}

public enum CoreWorkspacePendingSaveRecoveryV1: Sendable, Equatable {
    case noPending(CoreWorkspaceWorkingJournalValidationV1)
    case pendingNotCommitted(CoreWorkspaceWorkingJournalValidationV1)
    case committed(
        cleanJournal: CoreWorkspaceWorkingJournalValidationV1,
        documentDigest: String
    )
}

public final class CoreWorkspaceJournalMutationTransactionV1: @unchecked Sendable {
    private let acquireAuthorityPermitOperation: @Sendable () throws
        -> CoreWorkspaceCreateAuthorityPermitV1
    private let nextOperation: @Sendable () throws -> CoreWorkspaceJournalMutationDirectiveV1
    private let reportOperation: @Sendable (CoreWorkspaceSaveActionReportV1) throws
        -> CoreWorkspaceJournalMutationDirectiveV1
    private let closeOperation: @Sendable () -> Void

    init(
        acquireAuthorityPermit: @escaping @Sendable () throws
            -> CoreWorkspaceCreateAuthorityPermitV1,
        next: @escaping @Sendable () throws -> CoreWorkspaceJournalMutationDirectiveV1,
        report: @escaping @Sendable (CoreWorkspaceSaveActionReportV1) throws
            -> CoreWorkspaceJournalMutationDirectiveV1,
        close: @escaping @Sendable () -> Void
    ) {
        acquireAuthorityPermitOperation = acquireAuthorityPermit
        nextOperation = next
        reportOperation = report
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
        try acquireAuthorityPermitOperation()
    }

    public func nextDirective() throws -> CoreWorkspaceJournalMutationDirectiveV1 {
        try nextOperation()
    }

    public func report(
        _ report: CoreWorkspaceSaveActionReportV1
    ) throws -> CoreWorkspaceJournalMutationDirectiveV1 {
        try reportOperation(report)
    }

    public func close() {
        closeOperation()
    }
}

public final class CoreWorkspaceSaveTransactionV1: @unchecked Sendable {
    private let nextOperation: @Sendable () throws -> CoreWorkspaceSaveDirectiveV1
    private let reportOperation: @Sendable (CoreWorkspaceSaveActionReportV1) throws
        -> CoreWorkspaceSaveDirectiveV1
    private let closeOperation: @Sendable () -> Void

    init(
        next: @escaping @Sendable () throws -> CoreWorkspaceSaveDirectiveV1,
        report: @escaping @Sendable (CoreWorkspaceSaveActionReportV1) throws
            -> CoreWorkspaceSaveDirectiveV1,
        close: @escaping @Sendable () -> Void
    ) {
        nextOperation = next
        reportOperation = report
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func nextDirective() throws -> CoreWorkspaceSaveDirectiveV1 {
        try nextOperation()
    }

    public func report(
        _ report: CoreWorkspaceSaveActionReportV1
    ) throws -> CoreWorkspaceSaveDirectiveV1 {
        try reportOperation(report)
    }

    public func close() {
        closeOperation()
    }
}

public final class CoreWorkspaceCreateAuthorityPermitV1: @unchecked Sendable {
    private let closeOperation: @Sendable () -> Void

    init(close: @escaping @Sendable () -> Void) {
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func close() {
        closeOperation()
    }
}

public final class CoreWorkspaceCreateTransactionV1: @unchecked Sendable {
    private let acquireAuthorityPermitOperation: @Sendable () throws
        -> CoreWorkspaceCreateAuthorityPermitV1
    private let nextOperation: @Sendable () throws -> CoreWorkspaceCreateDirectiveV1
    private let reportOperation: @Sendable (CoreWorkspaceSaveActionReportV1) throws
        -> CoreWorkspaceCreateDirectiveV1
    private let closeOperation: @Sendable () -> Void

    init(
        acquireAuthorityPermit: @escaping @Sendable () throws
            -> CoreWorkspaceCreateAuthorityPermitV1,
        next: @escaping @Sendable () throws -> CoreWorkspaceCreateDirectiveV1,
        report: @escaping @Sendable (CoreWorkspaceSaveActionReportV1) throws
            -> CoreWorkspaceCreateDirectiveV1,
        close: @escaping @Sendable () -> Void
    ) {
        acquireAuthorityPermitOperation = acquireAuthorityPermit
        nextOperation = next
        reportOperation = report
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
        try acquireAuthorityPermitOperation()
    }

    public func nextDirective() throws -> CoreWorkspaceCreateDirectiveV1 {
        try nextOperation()
    }

    public func report(
        _ report: CoreWorkspaceSaveActionReportV1
    ) throws -> CoreWorkspaceCreateDirectiveV1 {
        try reportOperation(report)
    }

    public func close() {
        closeOperation()
    }
}

public final class CoreWorkspaceDeleteTransactionV1: @unchecked Sendable {
    private let nextOperation: @Sendable () throws -> CoreWorkspaceDeleteDirectiveV1
    private let reportOperation: @Sendable (CoreWorkspaceSaveActionReportV1) throws
        -> CoreWorkspaceDeleteDirectiveV1
    private let closeOperation: @Sendable () -> Void

    init(
        next: @escaping @Sendable () throws -> CoreWorkspaceDeleteDirectiveV1,
        report: @escaping @Sendable (CoreWorkspaceSaveActionReportV1) throws
            -> CoreWorkspaceDeleteDirectiveV1,
        close: @escaping @Sendable () -> Void
    ) {
        nextOperation = next
        reportOperation = report
        closeOperation = close
    }

    deinit {
        closeOperation()
    }

    public func nextDirective() throws -> CoreWorkspaceDeleteDirectiveV1 {
        try nextOperation()
    }

    public func report(
        _ report: CoreWorkspaceSaveActionReportV1
    ) throws -> CoreWorkspaceDeleteDirectiveV1 {
        try reportOperation(report)
    }

    public func close() {
        closeOperation()
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

    public func planCatalogTransition(
        currentCatalogBytes: Data?,
        transitionBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        guard currentCatalogBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              transitionBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceCatalogPlanTransitionV1(
            identity: context.identity,
            currentCatalogBytes: currentCatalogBytes,
            transitionBytes: transitionBytes
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

    public func beginCreateTransaction(
        rawCatalogBytes: Data?,
        effectiveCatalogBytes: Data,
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data?,
        requestBytes: Data,
        documentBytes: Data
    ) throws -> CoreWorkspaceCreateTransactionV1 {
        guard rawCatalogBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveCatalogBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              rawJournalBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveJournalBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              requestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              documentBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceCreateTransactionBeginV1(
            identity: context.identity,
            rawCatalogBytes: rawCatalogBytes,
            effectiveCatalogBytes: effectiveCatalogBytes,
            rawJournalBytes: rawJournalBytes,
            effectiveJournalBytes: effectiveJournalBytes,
            requestBytes: requestBytes,
            documentBytes: documentBytes
        )
    }

    public func beginDeleteTransaction(
        rawCatalogBytes: Data?,
        effectiveCatalogBytes: Data,
        effectiveJournalBytes: Data,
        requestBytes: Data
    ) throws -> CoreWorkspaceDeleteTransactionV1 {
        guard rawCatalogBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveCatalogBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveJournalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              requestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceDeleteTransactionBeginV1(
            identity: context.identity,
            rawCatalogBytes: rawCatalogBytes,
            effectiveCatalogBytes: effectiveCatalogBytes,
            effectiveJournalBytes: effectiveJournalBytes,
            requestBytes: requestBytes
        )
    }

    public func beginJournalMutationTransaction(
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data,
        requestBytes: Data,
        candidateDocumentBytes: Data,
        diskDocumentBytes: Data?
    ) throws -> CoreWorkspaceJournalMutationTransactionV1 {
        guard rawJournalBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveJournalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              requestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              candidateDocumentBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes,
              diskDocumentBytes?.count ?? 0 <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceJournalMutationTransactionBeginV1(
            identity: context.identity,
            rawJournalBytes: rawJournalBytes,
            effectiveJournalBytes: effectiveJournalBytes,
            requestBytes: requestBytes,
            candidateDocumentBytes: candidateDocumentBytes,
            diskDocumentBytes: diskDocumentBytes
        )
    }

    public func beginSaveTransaction(
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data,
        requestBytes: Data,
        candidateDocumentBytes: Data,
        diskDocumentBytes: Data?
    ) throws -> CoreWorkspaceSaveTransactionV1 {
        guard rawJournalBytes?.count ?? 0 <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              effectiveJournalBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              requestBytes.count <= CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes,
              candidateDocumentBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes,
              diskDocumentBytes?.count ?? 0 <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
        else {
            throw CoreWorkspaceWorkingJournalValidationError.inputTooLarge
        }
        return try context.transport.workspaceSaveTransactionBeginV1(
            identity: context.identity,
            rawJournalBytes: rawJournalBytes,
            effectiveJournalBytes: effectiveJournalBytes,
            requestBytes: requestBytes,
            candidateDocumentBytes: candidateDocumentBytes,
            diskDocumentBytes: diskDocumentBytes
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

    func workspaceCatalogPlanTransitionV1(
        identity: CoreRuntimeIdentity,
        currentCatalogBytes: Data?,
        transitionBytes: Data
    ) throws -> CoreWorkspaceCatalogValidationV1 {
        throw CoreTransportError.unexpected("workspace catalog transition transport is unavailable")
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

    func workspaceCreateTransactionBeginV1(
        identity: CoreRuntimeIdentity,
        rawCatalogBytes: Data?,
        effectiveCatalogBytes: Data,
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data?,
        requestBytes: Data,
        documentBytes: Data
    ) throws -> CoreWorkspaceCreateTransactionV1 {
        throw CoreTransportError.unexpected("workspace create transaction transport is unavailable")
    }

    func workspaceDeleteTransactionBeginV1(
        identity: CoreRuntimeIdentity,
        rawCatalogBytes: Data?,
        effectiveCatalogBytes: Data,
        effectiveJournalBytes: Data,
        requestBytes: Data
    ) throws -> CoreWorkspaceDeleteTransactionV1 {
        throw CoreTransportError.unexpected("workspace delete transaction transport is unavailable")
    }

    func workspaceJournalMutationTransactionBeginV1(
        identity: CoreRuntimeIdentity,
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data,
        requestBytes: Data,
        candidateDocumentBytes: Data,
        diskDocumentBytes: Data?
    ) throws -> CoreWorkspaceJournalMutationTransactionV1 {
        throw CoreTransportError.unexpected("workspace journal mutation transaction transport is unavailable")
    }

    func workspaceSaveTransactionBeginV1(
        identity: CoreRuntimeIdentity,
        rawJournalBytes: Data?,
        effectiveJournalBytes: Data,
        requestBytes: Data,
        candidateDocumentBytes: Data,
        diskDocumentBytes: Data?
    ) throws -> CoreWorkspaceSaveTransactionV1 {
        throw CoreTransportError.unexpected("workspace save transaction transport is unavailable")
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
}
