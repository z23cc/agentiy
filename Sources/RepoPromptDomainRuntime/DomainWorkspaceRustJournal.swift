import AgentryCoreBridge
import Foundation

package typealias DomainWorkspaceCommandIdentityResolver = @Sendable (
    DomainWorkspaceCommandIdentityInput
) async throws -> String

package struct DomainWorkspaceCommandIdentityInput: Sendable, Equatable {
    package static let maximumProtectedAgentIdentityCount =
        CoreWorkspaceCommandIdentityRequestV1.maximumProtectedAgentIdentities
    package static let maximumRetainedBytes = 32 * 1024 * 1024

    package enum Command: Sendable, Equatable {
        case create(workspaceID: UUID, fileURL: URL, contentDigest: String)
        case replace(workspaceID: UUID, fileURL: URL, contentDigest: String)
        case save(workspaceID: UUID)
        case delete(workspaceID: UUID)
        case resolveExternalConflict(
            workspaceID: UUID,
            acceptExternal: Bool,
            protectedAgentIdentities: [DomainProtectedAgentIdentity]
        )
    }

    package let operationID: UUID
    package let expectedCatalogRevision: UInt64?
    package let expectedWorkspaceRevision: UInt64?
    package let expectedContextRevision: UInt64?
    package let origin: DomainCommandOrigin
    package let command: Command

    package init?(_ envelope: DomainWorkspaceCommandEnvelope) {
        let command: Command
        switch envelope.command {
        case let .createWorkspace(document):
            command = .create(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                contentDigest: document.contentDigest
            )
        case let .replaceWorkingDocument(document):
            command = .replace(
                workspaceID: document.workspaceID,
                fileURL: document.fileURL,
                contentDigest: document.contentDigest
            )
        case let .saveWorkspaceDocument(workspaceID):
            command = .save(workspaceID: workspaceID)
        case let .deleteWorkspace(workspaceID):
            command = .delete(workspaceID: workspaceID)
        case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
            guard protectedAgentIdentities.count <= Self.maximumProtectedAgentIdentityCount else {
                return nil
            }
            command = .resolveExternalConflict(
                workspaceID: workspaceID,
                acceptExternal: acceptExternal,
                protectedAgentIdentities: protectedAgentIdentities
            )
        }
        operationID = envelope.operationID
        expectedCatalogRevision = envelope.expectedCatalogRevision
        expectedWorkspaceRevision = envelope.expectedWorkspaceRevision
        expectedContextRevision = envelope.expectedContextRevision
        origin = envelope.origin
        self.command = command
    }

    package var estimatedRetainedBytes: Int? {
        // The compact identity retains no workspace/context document Data. Charge fixed value/array
        // storage plus every variable string and bounded protected-identity entry with checked math.
        var total = 512
        func add(_ count: Int) -> Bool {
            let next = total.addingReportingOverflow(count)
            guard !next.overflow else { return false }
            total = next.partialValue
            return true
        }
        func add(_ value: String) -> Bool {
            add(value.utf8.count)
        }
        func add(_ identities: [DomainProtectedAgentIdentity]) -> Bool {
            let bytes = identities.count.multipliedReportingOverflow(by: 96)
            return !bytes.overflow && add(bytes.partialValue)
        }

        switch command {
        case let .create(_, fileURL, contentDigest),
             let .replace(_, fileURL, contentDigest):
            guard add(fileURL.absoluteString), add(contentDigest) else { return nil }
        case .save, .delete:
            break
        case let .resolveExternalConflict(_, _, protectedAgentIdentities):
            guard add(protectedAgentIdentities) else { return nil }
        }
        return total
    }
}

struct DomainWorkspaceCommandAdmissionSeedRecord: Sendable {
    let workspaceID: UUID?
    let operation: DomainRecordedOperation
}

enum DomainWorkspaceCommandAdmissionLookupScope: Sendable, Equatable {
    case workspace
    case global
}

enum DomainWorkspaceCommandAdmissionDecision: Sendable, Equatable {
    case unseen
    case collision(scope: DomainWorkspaceCommandAdmissionLookupScope)
    case replay(
        scope: DomainWorkspaceCommandAdmissionLookupScope,
        operation: DomainRecordedOperation
    )
}

struct DomainWorkspaceCommandAdmissionPreflight: Sendable, Equatable {
    let fingerprint: String
    let decision: DomainWorkspaceCommandAdmissionDecision
}

enum DomainWorkspaceCommandAdmissionPreflightError: Error, Sendable, Equatable {
    case invalidInput
    case invalidReceipt
    case unavailable
}

struct DomainWorkspaceCommandAdmissionDiagnostics: Sendable, Equatable {
    let globalOperationCount: UInt64
    let workspaceCount: UInt64
    let workspaceOperationCount: UInt64
}

struct DomainWorkspaceWorkingJournalValidation: Sendable {
    let journal: DomainWorkingJournal
    let canonicalBytes: Data
    let contentDigest: String
}

struct DomainWorkspaceSavedRevisionValidation: Sendable {
    let record: DomainSavedRevisionRecord
    let canonicalBytes: Data
    let contentDigest: String
}

struct DomainWorkspaceDeletionTombstoneValidation: Sendable {
    let tombstone: DomainDeletionTombstone
    let canonicalBytes: Data
    let contentDigest: String
}

struct DomainWorkspaceCatalogValidation: Sendable {
    let catalog: DomainPersistenceCoordinator.RuntimeWorkspaceCatalog
    let canonicalBytes: Data
    let contentDigest: String
}

enum DomainWorkspaceJournalMutationFinalization: Sendable, Equatable {
    case finalized
    case revisionSidecarMissing
}

enum DomainWorkspaceJournalMutationDirective: Sendable {
    case writeJournal(
        actionID: UInt64,
        expectedRawDigest: String?,
        validation: DomainWorkspaceWorkingJournalValidation,
        logicalExpectedRevision: UInt64,
        authorityReceipt: DomainWorkspaceJournalMutationCommitReceipt,
        postAuthoritySuccessFinalization: DomainWorkspaceJournalMutationFinalization
    )
    case writeSavedRevision(
        actionID: UInt64,
        validation: DomainWorkspaceSavedRevisionValidation,
        postAuthoritySuccessFinalization: DomainWorkspaceJournalMutationFinalization,
        postAuthorityFailureFinalization: DomainWorkspaceJournalMutationFinalization
    )
    case committed(
        receipt: DomainWorkspaceJournalMutationCommitReceipt,
        finalization: DomainWorkspaceJournalMutationFinalization
    )
    case failed(DomainWorkspaceSaveFailure)
}

struct DomainWorkspaceJournalMutationCommitReceipt: Sendable {
    let workspaceID: UUID
    let requestDigest: String
    let catalogRevision: UInt64
    let committedJournal: DomainWorkspaceWorkingJournalValidation
    let savedRevision: DomainWorkspaceSavedRevisionValidation?
}

enum DomainWorkspaceSaveFinalization: Sendable, Equatable {
    case finalized
    case pendingJournalRetained
    case revisionSidecarMissing
}

enum DomainWorkspaceSaveFailure: Sendable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

struct DomainWorkspaceSaveCommitReceipt: Sendable {
    let workspaceID: UUID
    let operationID: UUID
    let requestDigest: String
    let catalogRevision: UInt64
    let documentDigest: String
    let committedJournal: DomainWorkspaceWorkingJournalValidation
    let savedRevision: DomainWorkspaceSavedRevisionValidation
}

enum DomainWorkspaceSaveDirective: Sendable {
    case writePendingJournal(
        actionID: UInt64,
        expectedRawDigest: String?,
        validation: DomainWorkspaceWorkingJournalValidation,
        logicalExpectedRevision: UInt64
    )
    case publishWorkspaceDocument(
        actionID: UInt64,
        bytes: Data,
        contentDigest: String,
        authorityReceipt: DomainWorkspaceSaveCommitReceipt,
        postAuthoritySuccessFinalization: DomainWorkspaceSaveFinalization
    )
    case writeCommittedJournal(
        actionID: UInt64,
        expectedRawDigest: String,
        validation: DomainWorkspaceWorkingJournalValidation,
        logicalExpectedRevision: UInt64,
        postAuthoritySuccessFinalization: DomainWorkspaceSaveFinalization,
        postAuthorityFailureFinalization: DomainWorkspaceSaveFinalization
    )
    case writeSavedRevision(
        actionID: UInt64,
        validation: DomainWorkspaceSavedRevisionValidation,
        postAuthoritySuccessFinalization: DomainWorkspaceSaveFinalization,
        postAuthorityFailureFinalization: DomainWorkspaceSaveFinalization
    )
    case committed(
        receipt: DomainWorkspaceSaveCommitReceipt,
        finalization: DomainWorkspaceSaveFinalization
    )
    case failed(DomainWorkspaceSaveFailure)
}

enum DomainWorkspaceCreateFailure: Sendable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

struct DomainWorkspaceCreateCommitReceipt: Sendable {
    let workspaceID: UUID
    let operationID: UUID
    let requestDigest: String
    let documentDigest: String
    let catalog: DomainWorkspaceCatalogValidation
    let committedJournal: DomainWorkspaceWorkingJournalValidation
    let savedRevision: DomainWorkspaceSavedRevisionValidation?
}

enum DomainWorkspaceCreateDirective: Sendable {
    case writePendingJournal(
        actionID: UInt64,
        expectedRawDigest: String?,
        validation: DomainWorkspaceWorkingJournalValidation,
        logicalExpectedRevision: UInt64
    )
    case publishWorkspaceDocument(
        actionID: UInt64,
        bytes: Data,
        contentDigest: String
    )
    case writeCommittedJournal(
        actionID: UInt64,
        expectedRawDigest: String,
        validation: DomainWorkspaceWorkingJournalValidation,
        logicalExpectedRevision: UInt64
    )
    case writeSavedRevision(
        actionID: UInt64,
        validation: DomainWorkspaceSavedRevisionValidation
    )
    case removeDeletionSidecar(actionID: UInt64, contentDigest: String)
    case publishCatalog(
        actionID: UInt64,
        expectedRawDigest: String?,
        catalog: DomainWorkspaceCatalogValidation,
        logicalExpectedRevision: UInt64,
        authorityReceipt: DomainWorkspaceCreateCommitReceipt
    )
    case committed(DomainWorkspaceCreateCommitReceipt)
    case failed(DomainWorkspaceCreateFailure)
}

enum DomainWorkspaceDeleteFailure: Sendable {
    case cancelled
    case stateConflict(expected: UInt64, actual: UInt64)
    case writeFailed
}

struct DomainWorkspaceDeleteCommitReceipt: Sendable {
    let workspaceID: UUID
    let operationID: UUID
    let requestDigest: String
    let catalog: DomainWorkspaceCatalogValidation
    let tombstone: DomainWorkspaceDeletionTombstoneValidation
}

enum DomainWorkspaceDeleteDirective: Sendable {
    case publishCatalog(
        actionID: UInt64,
        expectedRawDigest: String?,
        catalog: DomainWorkspaceCatalogValidation,
        logicalExpectedRevision: UInt64,
        authorityReceipt: DomainWorkspaceDeleteCommitReceipt
    )
    case committed(DomainWorkspaceDeleteCommitReceipt)
    case failed(DomainWorkspaceDeleteFailure)
}

enum DomainWorkspacePendingSaveRecovery: Sendable {
    case noPending(DomainWorkspaceWorkingJournalValidation)
    case pendingNotCommitted(DomainWorkspaceWorkingJournalValidation)
    case committed(
        cleanJournal: DomainWorkspaceWorkingJournalValidation,
        documentDigest: String
    )
}

private struct DomainWorkspaceCatalogSeedRequest: Encodable {
    let kind = "seed"
    let entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry]
    let updatedAt: Date
}

/// Rust-owned semantic transition request. Swift supplies command data and still owns the physical
/// transaction; Rust decides the complete V1 journal fields and returns canonical candidate bytes.
enum DomainWorkspaceWorkingJournalTransition: Sendable {
    case seed(
        workspaceID: UUID,
        fileURL: URL,
        revisions: DomainRevisionState,
        savedDigest: String,
        contextDigests: [UUID: String],
        updatedAt: Date
    )
    case recoverPending(expectedWorkspaceID: UUID)
    case create(
        workspaceID: UUID,
        fileURL: URL,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        operation: DomainRecordedOperation,
        operationID: UUID,
        updatedAt: Date
    )
    case unchanged(
        expectedWorkingRevision: UInt64,
        operation: DomainRecordedOperation,
        updatedAt: Date
    )
    case working(
        expectedWorkingRevision: UInt64,
        newRevisions: DomainRevisionState,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        updatedAt: Date
    )
    case save(
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        updatedAt: Date
    )
    case externalReload(
        expectedWorkingRevision: UInt64,
        newRevision: UInt64,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        updatedAt: Date
    )
    case conflictRebase(
        expectedRevisions: DomainRevisionState,
        newRevisions: DomainRevisionState,
        externalSavedDigest: String,
        contextRevisions: [UUID: DomainRevisionState],
        contextDigests: [UUID: String],
        contextTombstones: [UUID: UInt64],
        operations: [DomainRecordedOperation],
        updatedAt: Date
    )

    fileprivate var encoded: EncodedTransition {
        switch self {
        case let .seed(workspaceID, fileURL, revisions, savedDigest, contextDigests, updatedAt):
            EncodedTransition(
                kind: "seed",
                workspaceID: workspaceID,
                fileURL: fileURL,
                revisions: revisions,
                savedDigest: savedDigest,
                contextDigests: contextDigests,
                updatedAt: updatedAt
            )
        case let .recoverPending(expectedWorkspaceID):
            EncodedTransition(kind: "recoverPending", expectedWorkspaceID: expectedWorkspaceID)
        case let .create(
            workspaceID,
            fileURL,
            contextRevisions,
            contextDigests,
            operation,
            operationID,
            updatedAt
        ):
            EncodedTransition(
                kind: "create",
                workspaceID: workspaceID,
                fileURL: fileURL,
                contextRevisions: contextRevisions,
                contextDigests: contextDigests,
                operation: operation,
                operationID: operationID,
                updatedAt: updatedAt
            )
        case let .unchanged(expectedWorkingRevision, operation, updatedAt):
            EncodedTransition(
                kind: "unchanged",
                expectedWorkingRevision: expectedWorkingRevision,
                operation: operation,
                updatedAt: updatedAt
            )
        case let .working(
            expectedWorkingRevision,
            newRevisions,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            updatedAt
        ):
            EncodedTransition(
                kind: "working",
                newRevisions: newRevisions,
                expectedWorkingRevision: expectedWorkingRevision,
                contextRevisions: contextRevisions,
                contextDigests: contextDigests,
                contextTombstones: contextTombstones,
                operations: operations,
                updatedAt: updatedAt
            )
        case let .save(
            expectedWorkingRevision,
            operationID,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            updatedAt
        ):
            EncodedTransition(
                kind: "save",
                expectedWorkingRevision: expectedWorkingRevision,
                contextRevisions: contextRevisions,
                contextDigests: contextDigests,
                contextTombstones: contextTombstones,
                operations: operations,
                operationID: operationID,
                updatedAt: updatedAt
            )
        case let .externalReload(
            expectedWorkingRevision,
            newRevision,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            updatedAt
        ):
            EncodedTransition(
                kind: "externalReload",
                expectedWorkingRevision: expectedWorkingRevision,
                newRevision: newRevision,
                contextRevisions: contextRevisions,
                contextDigests: contextDigests,
                contextTombstones: contextTombstones,
                operations: operations,
                updatedAt: updatedAt
            )
        case let .conflictRebase(
            expectedRevisions,
            newRevisions,
            externalSavedDigest,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            updatedAt
        ):
            EncodedTransition(
                kind: "conflictRebase",
                expectedRevisions: expectedRevisions,
                newRevisions: newRevisions,
                externalSavedDigest: externalSavedDigest,
                contextRevisions: contextRevisions,
                contextDigests: contextDigests,
                contextTombstones: contextTombstones,
                operations: operations,
                updatedAt: updatedAt
            )
        }
    }

    fileprivate struct EncodedTransition: Encodable {
        let kind: String
        var workspaceID: UUID?
        var fileURL: URL?
        var expectedWorkspaceID: UUID?
        var revisions: DomainRevisionState?
        var expectedRevisions: DomainRevisionState?
        var newRevisions: DomainRevisionState?
        var expectedWorkingRevision: UInt64?
        var newRevision: UInt64?
        var savedDigest: String?
        var externalSavedDigest: String?
        var contextRevisions: [UUID: DomainRevisionState]?
        var contextDigests: [UUID: String]?
        var contextTombstones: [UUID: UInt64]?
        var operations: [DomainRecordedOperation]?
        var operation: DomainRecordedOperation?
        var operationID: UUID?
        var updatedAt: Date?

        init(
            kind: String,
            workspaceID: UUID? = nil,
            fileURL: URL? = nil,
            expectedWorkspaceID: UUID? = nil,
            revisions: DomainRevisionState? = nil,
            expectedRevisions: DomainRevisionState? = nil,
            newRevisions: DomainRevisionState? = nil,
            expectedWorkingRevision: UInt64? = nil,
            newRevision: UInt64? = nil,
            savedDigest: String? = nil,
            externalSavedDigest: String? = nil,
            contextRevisions: [UUID: DomainRevisionState]? = nil,
            contextDigests: [UUID: String]? = nil,
            contextTombstones: [UUID: UInt64]? = nil,
            operations: [DomainRecordedOperation]? = nil,
            operation: DomainRecordedOperation? = nil,
            operationID: UUID? = nil,
            updatedAt: Date? = nil
        ) {
            self.kind = kind
            self.workspaceID = workspaceID
            self.fileURL = fileURL
            self.expectedWorkspaceID = expectedWorkspaceID
            self.revisions = revisions
            self.expectedRevisions = expectedRevisions
            self.newRevisions = newRevisions
            self.expectedWorkingRevision = expectedWorkingRevision
            self.newRevision = newRevision
            self.savedDigest = savedDigest
            self.externalSavedDigest = externalSavedDigest
            self.contextRevisions = contextRevisions
            self.contextDigests = contextDigests
            self.contextTombstones = contextTombstones
            self.operations = operations
            self.operation = operation
            self.operationID = operationID
            self.updatedAt = updatedAt
        }
    }
}

private extension DomainWorkspaceWorkingJournalTransition {
    var expectedWorkingRevision: UInt64 {
        switch self {
        case let .unchanged(revision, _, _),
             let .working(revision, _, _, _, _, _, _),
             let .externalReload(revision, _, _, _, _, _, _):
            revision
        case let .conflictRebase(revisions, _, _, _, _, _, _, _):
            revisions.workingRevision
        case .seed, .recoverPending, .create, .save:
            0
        }
    }

    var resultingWorkingRevision: UInt64 {
        switch self {
        case let .unchanged(revision, _, _): revision
        case let .working(_, revisions, _, _, _, _, _): revisions.workingRevision
        case let .externalReload(_, revision, _, _, _, _, _): revision
        case let .conflictRebase(_, revisions, _, _, _, _, _, _): revisions.workingRevision
        case .seed, .recoverPending, .create, .save: 0
        }
    }

    var resultingSavedRevision: UInt64? {
        if case let .externalReload(_, revision, _, _, _, _, _) = self {
            return revision
        }
        return nil
    }

    func matches(
        journal: DomainWorkingJournal,
        documentDigest: String
    ) -> Bool {
        func contains(_ operations: [DomainRecordedOperation]) -> Bool {
            operations.allSatisfy(journal.operations.contains)
        }

        func workingDocumentMatches(_ revisions: DomainRevisionState) -> Bool {
            if revisions.dirtyRevision == nil {
                return journal.workingDocument == nil
            }
            return journal.workingDocument.map(DomainContentDigest.sha256) == documentDigest
        }

        func cleaned(_ revisions: [UUID: DomainRevisionState]) -> [UUID: DomainRevisionState] {
            revisions.mapValues { revision in
                DomainRevisionState(
                    workingRevision: revision.workingRevision,
                    savedRevision: revision.workingRevision,
                    dirtyRevision: nil
                )
            }
        }

        switch self {
        case let .unchanged(expectedRevision, operation, _):
            return journal.revisions.workingRevision == expectedRevision
                && journal.operations.contains(operation)
        case let .working(
            _,
            revisions,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            _
        ):
            return journal.revisions == revisions
                && journal.contextRevisions == contextRevisions
                && journal.contextDigests == contextDigests
                && journal.contextTombstones == contextTombstones
                && contains(operations)
                && workingDocumentMatches(revisions)
        case let .externalReload(
            _,
            revision,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            _
        ):
            return journal.revisions == DomainRevisionState(
                workingRevision: revision,
                savedRevision: revision,
                dirtyRevision: nil
            )
                && journal.savedDigest == documentDigest
                && journal.workingDocument == nil
                && journal.contextRevisions == cleaned(contextRevisions)
                && journal.contextDigests == contextDigests
                && journal.contextTombstones == contextTombstones
                && contains(operations)
        case let .conflictRebase(
            _,
            revisions,
            externalSavedDigest,
            contextRevisions,
            contextDigests,
            contextTombstones,
            operations,
            _
        ):
            return journal.revisions == revisions
                && journal.savedDigest == externalSavedDigest
                && journal.contextRevisions == contextRevisions
                && journal.contextDigests == contextDigests
                && journal.contextTombstones == contextTombstones
                && contains(operations)
                && workingDocumentMatches(revisions)
        case .seed, .recoverPending, .create, .save:
            return false
        }
    }
}

/// P5-5 prepared Rust journal authority bound to one exact live runtime identity.
enum DomainWorkspaceRustJournal {
    private struct CreateTransactionRequest: Encodable {
        let kind: String
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedCatalogRevision: UInt64
        let operationID: UUID?
        let contextRevisions: [UUID: DomainRevisionState]?
        let contextDigests: [UUID: String]?
        let operation: DomainRecordedOperation?
        let updatedAt: Date
    }

    private struct DeleteTransactionRequest: Encodable {
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedWorkingRevision: UInt64
        let expectedCatalogRevision: UInt64
        let operation: DomainRecordedOperation
        let deletedAt: Date
    }

    private struct JournalMutationTransactionRequest: Encodable {
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let catalogRevision: UInt64
        let revisionOperationID: UUID?
        let transition: DomainWorkspaceWorkingJournalTransition.EncodedTransition
    }

    private struct SaveTransactionRequest: Encodable {
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedWorkingRevision: UInt64
        let operationID: UUID
        let contextRevisions: [UUID: DomainRevisionState]
        let contextDigests: [UUID: String]
        let contextTombstones: [UUID: UInt64]
        let operations: [DomainRecordedOperation]
        let updatedAt: Date
        let catalogRevision: UInt64
    }

    struct PreparedCreateTransaction: Sendable {
        private let core: CoreWorkspaceCreateTransactionV1
        private let validator: PreparedValidator
        private let expectedWorkspaceID: UUID
        private let expectedFileURL: URL
        private let expectedOperation: DomainRecordedOperation?
        private let expectedCatalogRevision: UInt64
        private let expectedDocumentDigest: String
        private let expectedUpdatedAt: Date
        private let isRecovery: Bool

        fileprivate init(
            core: CoreWorkspaceCreateTransactionV1,
            validator: PreparedValidator,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation?,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedUpdatedAt: Date,
            isRecovery: Bool
        ) {
            self.core = core
            self.validator = validator
            self.expectedWorkspaceID = expectedWorkspaceID
            self.expectedFileURL = expectedFileURL
            self.expectedOperation = expectedOperation
            self.expectedCatalogRevision = expectedCatalogRevision
            self.expectedDocumentDigest = expectedDocumentDigest
            self.expectedUpdatedAt = expectedUpdatedAt
            self.isRecovery = isRecovery
        }

        func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
            try core.acquireAuthorityPermit()
        }

        func nextDirective() throws -> DomainWorkspaceCreateDirective {
            try validator.materializeCreateDirective(
                core.nextDirective(),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperation: expectedOperation,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                expectedUpdatedAt: expectedUpdatedAt,
                isRecovery: isRecovery
            )
        }

        func report(
            _ report: CoreWorkspaceSaveActionReportV1
        ) throws -> DomainWorkspaceCreateDirective {
            try validator.materializeCreateDirective(
                core.report(report),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperation: expectedOperation,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                expectedUpdatedAt: expectedUpdatedAt,
                isRecovery: isRecovery
            )
        }

        func close() {
            core.close()
        }
    }

    struct PreparedJournalMutationTransaction: Sendable {
        private let core: CoreWorkspaceJournalMutationTransactionV1
        private let validator: PreparedValidator
        private let expectedWorkspaceID: UUID
        private let expectedFileURL: URL
        private let expectedTransition: DomainWorkspaceWorkingJournalTransition
        private let expectedCatalogRevision: UInt64
        private let expectedDocumentDigest: String
        private let revisionOperationID: UUID?
        private let expectedUpdatedAt: Date

        fileprivate init(
            core: CoreWorkspaceJournalMutationTransactionV1,
            validator: PreparedValidator,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedTransition: DomainWorkspaceWorkingJournalTransition,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            revisionOperationID: UUID?,
            expectedUpdatedAt: Date
        ) {
            self.core = core
            self.validator = validator
            self.expectedWorkspaceID = expectedWorkspaceID
            self.expectedFileURL = expectedFileURL
            self.expectedTransition = expectedTransition
            self.expectedCatalogRevision = expectedCatalogRevision
            self.expectedDocumentDigest = expectedDocumentDigest
            self.revisionOperationID = revisionOperationID
            self.expectedUpdatedAt = expectedUpdatedAt
        }

        func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
            try core.acquireAuthorityPermit()
        }

        func nextDirective() throws -> DomainWorkspaceJournalMutationDirective {
            try validator.materializeJournalMutationDirective(
                core.nextDirective(),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedTransition: expectedTransition,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                revisionOperationID: revisionOperationID,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }

        func report(
            _ report: CoreWorkspaceSaveActionReportV1
        ) throws -> DomainWorkspaceJournalMutationDirective {
            try validator.materializeJournalMutationDirective(
                core.report(report),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedTransition: expectedTransition,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                revisionOperationID: revisionOperationID,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }

        func close() {
            core.close()
        }
    }

    struct PreparedSaveTransaction: Sendable {
        private let core: CoreWorkspaceSaveTransactionV1
        private let validator: PreparedValidator
        private let expectedWorkspaceID: UUID
        private let expectedFileURL: URL
        private let expectedOperationID: UUID
        private let expectedCatalogRevision: UInt64
        private let expectedDocumentDigest: String
        private let expectedWorkingRevision: UInt64
        private let expectedUpdatedAt: Date

        fileprivate init(
            core: CoreWorkspaceSaveTransactionV1,
            validator: PreparedValidator,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperationID: UUID,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedWorkingRevision: UInt64,
            expectedUpdatedAt: Date
        ) {
            self.core = core
            self.validator = validator
            self.expectedWorkspaceID = expectedWorkspaceID
            self.expectedFileURL = expectedFileURL
            self.expectedOperationID = expectedOperationID
            self.expectedCatalogRevision = expectedCatalogRevision
            self.expectedDocumentDigest = expectedDocumentDigest
            self.expectedWorkingRevision = expectedWorkingRevision
            self.expectedUpdatedAt = expectedUpdatedAt
        }

        func nextDirective() throws -> DomainWorkspaceSaveDirective {
            try validator.materializeSaveDirective(
                core.nextDirective(),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperationID: expectedOperationID,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }

        func report(
            _ report: CoreWorkspaceSaveActionReportV1
        ) throws -> DomainWorkspaceSaveDirective {
            try validator.materializeSaveDirective(
                core.report(report),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperationID: expectedOperationID,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedUpdatedAt: expectedUpdatedAt
            )
        }

        func close() {
            core.close()
        }
    }

    struct PreparedDeleteTransaction: Sendable {
        private let core: CoreWorkspaceDeleteTransactionV1
        private let validator: PreparedValidator
        private let expectedWorkspaceID: UUID
        private let expectedFileURL: URL
        private let expectedOperation: DomainRecordedOperation
        private let expectedWorkingRevision: UInt64
        private let expectedCatalogRevision: UInt64
        private let expectedDeletedAt: Date

        fileprivate init(
            core: CoreWorkspaceDeleteTransactionV1,
            validator: PreparedValidator,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation,
            expectedWorkingRevision: UInt64,
            expectedCatalogRevision: UInt64,
            expectedDeletedAt: Date
        ) {
            self.core = core
            self.validator = validator
            self.expectedWorkspaceID = expectedWorkspaceID
            self.expectedFileURL = expectedFileURL
            self.expectedOperation = expectedOperation
            self.expectedWorkingRevision = expectedWorkingRevision
            self.expectedCatalogRevision = expectedCatalogRevision
            self.expectedDeletedAt = expectedDeletedAt
        }

        func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
            try core.acquireAuthorityPermit()
        }

        func nextDirective() throws -> DomainWorkspaceDeleteDirective {
            try validator.materializeDeleteDirective(
                core.nextDirective(),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperation: expectedOperation,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDeletedAt: expectedDeletedAt
            )
        }

        func report(
            _ report: CoreWorkspaceSaveActionReportV1
        ) throws -> DomainWorkspaceDeleteDirective {
            try validator.materializeDeleteDirective(
                core.report(report),
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperation: expectedOperation,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                expectedDeletedAt: expectedDeletedAt
            )
        }

        func reconcileAdmissionFinalization(
            operation: DomainRecordedOperation
        ) throws {
            do {
                try core.reconcileAdmissionFinalization(
                    operation: validator.coreRecordedOperation(operation)
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func close() {
            core.close()
        }
    }

    struct PreparedCommandAdmission: Sendable {
        private let core: CorePreparedWorkspaceCommandAdmissionV1
        private let validator: PreparedValidator

        fileprivate init(
            core: CorePreparedWorkspaceCommandAdmissionV1,
            validator: PreparedValidator
        ) {
            self.core = core
            self.validator = validator
        }

        fileprivate var transactionBinding: CorePreparedWorkspaceCommandAdmissionV1 {
            core
        }

        func preflight(
            _ input: DomainWorkspaceCommandIdentityInput
        ) throws -> DomainWorkspaceCommandAdmissionPreflight {
            let request = validator.coreCommandIdentityRequest(input)
            do {
                let receipt = try core.preflight(request)
                guard receipt.identity.workspaceID == request.workspaceID,
                      receipt.identity.commandKind == request.commandKind,
                      PreparedValidator.isSHA256Digest(receipt.identity.fingerprint)
                else {
                    throw DomainWorkspaceCommandAdmissionPreflightError.invalidReceipt
                }
                let decision = try validator.materializeCommandAdmissionDecision(receipt.decision)
                if case let .replay(_, operation) = decision {
                    guard operation.operationID == input.operationID,
                          operation.fingerprint == receipt.identity.fingerprint
                    else {
                        throw DomainWorkspaceCommandAdmissionPreflightError.invalidReceipt
                    }
                }
                return DomainWorkspaceCommandAdmissionPreflight(
                    fingerprint: receipt.identity.fingerprint,
                    decision: decision
                )
            } catch let error as DomainWorkspaceCommandAdmissionPreflightError {
                throw error
            } catch let error as CoreWorkspaceWorkingJournalValidationError {
                switch error {
                case .inputTooLarge,
                     .invalidIdentity,
                     .invalidFileURL,
                     .invalidDigest:
                    throw DomainWorkspaceCommandAdmissionPreflightError.invalidInput
                default:
                    throw DomainWorkspaceCommandAdmissionPreflightError.unavailable
                }
            } catch {
                throw DomainWorkspaceCommandAdmissionPreflightError.unavailable
            }
        }

        func decision(
            workspaceID: UUID,
            operationID: UUID,
            fingerprint: String
        ) throws -> DomainWorkspaceCommandAdmissionDecision {
            do {
                return try validator.materializeCommandAdmissionDecision(core.decision(
                    workspaceID: workspaceID,
                    operationID: operationID,
                    fingerprint: fingerprint
                ))
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        @discardableResult
        func reconcileDurable(
            _ records: [DomainWorkspaceCommandAdmissionSeedRecord]
        ) throws -> DomainWorkspaceCommandAdmissionDiagnostics {
            do {
                return validator.materializeCommandAdmissionDiagnostics(
                    try core.reconcileDurable(records.map(validator.coreCommandAdmissionSeedRecord))
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        @discardableResult
        func reconcileWorkspace(
            workspaceID: UUID,
            operations: [DomainRecordedOperation],
            deletedOperation: DomainRecordedOperation?
        ) throws -> DomainWorkspaceCommandAdmissionDiagnostics {
            do {
                return validator.materializeCommandAdmissionDiagnostics(
                    try core.reconcileWorkspace(
                        workspaceID: workspaceID,
                        operations: operations.map(validator.coreRecordedOperation),
                        deletedOperation: deletedOperation.map(validator.coreRecordedOperation)
                    )
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        @discardableResult
        func insertTransient(
            operation: DomainRecordedOperation
        ) throws -> DomainWorkspaceCommandAdmissionDiagnostics {
            do {
                return validator.materializeCommandAdmissionDiagnostics(
                    try core.insertTransient(
                        operation: validator.coreRecordedOperation(operation)
                    )
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func diagnostics() throws -> DomainWorkspaceCommandAdmissionDiagnostics {
            do {
                return validator.materializeCommandAdmissionDiagnostics(try core.diagnostics())
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func close() {
            core.close()
        }
    }

    struct PreparedValidator: Sendable {
        private let core: CorePreparedWorkspaceWorkingJournalValidatorV1

        fileprivate init(core: CorePreparedWorkspaceWorkingJournalValidatorV1) {
            self.core = core
        }

        func commandIdentity(
            _ envelope: DomainWorkspaceCommandEnvelope
        ) throws -> String {
            guard let input = DomainWorkspaceCommandIdentityInput(envelope) else {
                throw DomainPersistenceError.writeFailed("working_journal_too_large")
            }
            return try commandIdentity(input)
        }

        func commandIdentity(
            _ input: DomainWorkspaceCommandIdentityInput
        ) throws -> String {
            let request = coreCommandIdentityRequest(input)
            do {
                let identity = try core.commandIdentity(request)
                guard identity.workspaceID == request.workspaceID,
                      identity.commandKind == request.commandKind,
                      Self.isSHA256Digest(identity.fingerprint)
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                return identity.fingerprint
            } catch {
                throw map(error)
            }
        }

        fileprivate func coreCommandIdentityRequest(
            _ input: DomainWorkspaceCommandIdentityInput
        ) -> CoreWorkspaceCommandIdentityRequestV1 {
            let origin: CoreWorkspaceCommandOriginV1 = switch input.origin {
            case let .appPresentation(windowID):
                .appPresentation(windowID: Int64(windowID))
            case let .appMCP(connectionID):
                .appMCP(connectionID: connectionID)
            case .standalone:
                .standalone
            case .externalReload:
                .externalReload
            }
            let command: (
                kind: CoreWorkspaceCommandKindV1,
                workspaceID: UUID,
                fileURL: URL?,
                contentDigest: String?,
                acceptExternal: Bool?,
                protectedAgentIdentities: [CoreWorkspaceProtectedAgentIdentityV1]
            ) = switch input.command {
            case let .create(workspaceID, fileURL, contentDigest):
                (.create, workspaceID, fileURL, contentDigest, nil, [])
            case let .replace(workspaceID, fileURL, contentDigest):
                (.replace, workspaceID, fileURL, contentDigest, nil, [])
            case let .save(workspaceID):
                (.save, workspaceID, nil, nil, nil, [])
            case let .delete(workspaceID):
                (.delete, workspaceID, nil, nil, nil, [])
            case let .resolveExternalConflict(workspaceID, acceptExternal, protectedAgentIdentities):
                (
                    .resolveExternalConflict,
                    workspaceID,
                    nil,
                    nil,
                    acceptExternal,
                    protectedAgentIdentities.map { identity in
                        let location: CoreWorkspaceTabLocationV1 = switch identity.location {
                        case .composed: .composed
                        case .stashed: .stashed
                        }
                        return CoreWorkspaceProtectedAgentIdentityV1(
                            tabID: identity.tabID,
                            location: location,
                            activeAgentSessionID: identity.activeAgentSessionID,
                            isPinned: identity.isPinned
                        )
                    }
                )
            }
            return CoreWorkspaceCommandIdentityRequestV1(
                operationID: input.operationID,
                expectedCatalogRevision: input.expectedCatalogRevision,
                expectedWorkspaceRevision: input.expectedWorkspaceRevision,
                expectedContextRevision: input.expectedContextRevision,
                origin: origin,
                commandKind: command.kind,
                workspaceID: command.workspaceID,
                fileURL: command.fileURL,
                contentDigest: command.contentDigest,
                acceptExternal: command.acceptExternal,
                protectedAgentIdentities: command.protectedAgentIdentities
            )
        }

        fileprivate static func isSHA256Digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
            }
        }

        func beginCommandAdmission(
            records: [DomainWorkspaceCommandAdmissionSeedRecord]
        ) throws -> PreparedCommandAdmission {
            do {
                return PreparedCommandAdmission(
                    core: try core.beginCommandAdmission(
                        records: records.map(coreCommandAdmissionSeedRecord)
                    ),
                    validator: self
                )
            } catch {
                throw mapCommandAdmissionError(error)
            }
        }

        fileprivate func coreCommandAdmissionSeedRecord(
            _ record: DomainWorkspaceCommandAdmissionSeedRecord
        ) -> CoreWorkspaceCommandAdmissionSeedRecordV1 {
            .init(
                workspaceID: record.workspaceID,
                operation: coreRecordedOperation(record.operation)
            )
        }

        fileprivate func coreRecordedOperation(
            _ operation: DomainRecordedOperation
        ) -> CoreWorkspaceRecordedOperationV1 {
            .init(
                operationID: operation.operationID,
                fingerprint: operation.fingerprint,
                recordedAt: operation.recordedAt.timeIntervalSinceReferenceDate,
                disposition: operation.disposition.rawValue,
                before: operation.before.map(coreRevisionState),
                after: operation.after.map(coreRevisionState),
                catalogRevision: operation.catalogRevision,
                resultingDigest: operation.resultingDigest,
                errorCode: operation.errorCode?.rawValue,
                diagnostic: operation.diagnostic
            )
        }

        private func coreRevisionState(
            _ state: DomainRevisionState
        ) -> CoreWorkspaceProjectionRevisionState {
            .init(
                workingRevision: state.workingRevision,
                savedRevision: state.savedRevision,
                dirtyRevision: state.dirtyRevision
            )
        }

        fileprivate func materializeCommandAdmissionDecision(
            _ decision: CoreWorkspaceCommandAdmissionDecisionV1
        ) throws -> DomainWorkspaceCommandAdmissionDecision {
            switch decision {
            case .unseen:
                return .unseen
            case let .collision(scope):
                return .collision(scope: materializeCommandAdmissionScope(scope))
            case let .replay(scope, operation):
                return .replay(
                    scope: materializeCommandAdmissionScope(scope),
                    operation: try materializeRecordedOperation(operation)
                )
            }
        }

        private func materializeCommandAdmissionScope(
            _ scope: CoreWorkspaceCommandAdmissionLookupScopeV1
        ) -> DomainWorkspaceCommandAdmissionLookupScope {
            switch scope {
            case .workspace: .workspace
            case .global: .global
            }
        }

        private func materializeRecordedOperation(
            _ operation: CoreWorkspaceRecordedOperationV1
        ) throws -> DomainRecordedOperation {
            guard let disposition = DomainCommandDisposition(rawValue: operation.disposition) else {
                throw DomainPersistenceError.corruptJournal
            }
            let errorCode: DomainCommandErrorCode?
            if let rawErrorCode = operation.errorCode {
                guard let value = DomainCommandErrorCode(rawValue: rawErrorCode) else {
                    throw DomainPersistenceError.corruptJournal
                }
                errorCode = value
            } else {
                errorCode = nil
            }
            let outcome = DomainCommandOutcome(
                operationID: operation.operationID,
                disposition: disposition,
                before: operation.before.map(domainRevisionState),
                after: operation.after.map(domainRevisionState),
                catalogRevision: operation.catalogRevision,
                resultingDigest: operation.resultingDigest,
                errorCode: errorCode,
                diagnostic: operation.diagnostic,
                workspace: nil
            )
            return DomainRecordedOperation(
                fingerprint: operation.fingerprint,
                recordedAt: Date(timeIntervalSinceReferenceDate: operation.recordedAt),
                outcome: outcome
            )
        }

        private func domainRevisionState(
            _ state: CoreWorkspaceProjectionRevisionState
        ) -> DomainRevisionState {
            DomainRevisionState(
                workingRevision: state.workingRevision,
                savedRevision: state.savedRevision,
                dirtyRevision: state.dirtyRevision
            )
        }

        fileprivate func materializeCommandAdmissionDiagnostics(
            _ diagnostics: CoreWorkspaceCommandAdmissionDiagnosticsV1
        ) -> DomainWorkspaceCommandAdmissionDiagnostics {
            DomainWorkspaceCommandAdmissionDiagnostics(
                globalOperationCount: diagnostics.globalOperationCount,
                workspaceCount: diagnostics.workspaceCount,
                workspaceOperationCount: diagnostics.workspaceOperationCount
            )
        }

        fileprivate func mapCommandAdmissionError(_ error: Error) -> DomainPersistenceError {
            map(error)
        }

        func validateSavedRevision(
            _ bytes: Data,
            expectedWorkspaceID: UUID,
            expectedDocumentDigest: String
        ) throws -> DomainWorkspaceSavedRevisionValidation {
            do {
                return try materializeSavedRevision(
                    core.validateSavedRevision(bytes),
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedOperationID: nil,
                    expectedSavedRevision: nil,
                    expectedDocumentDigest: expectedDocumentDigest,
                    expectedUpdatedAt: nil
                )
            } catch {
                let mapped = map(error)
                switch mapped {
                case .writeFailed("working_journal_too_large"),
                     .writeFailed("working_journal_rust_unavailable"):
                    throw mapped
                default:
                    throw DomainPersistenceError.corruptJournal
                }
            }
        }

        func amendDeletionTombstoneCleanup(
            authoritative: DomainWorkspaceDeletionTombstoneValidation,
            cleanupWarnings: [String]
        ) throws -> DomainWorkspaceDeletionTombstoneValidation {
            do {
                let original = authoritative.tombstone
                guard DomainContentDigest.sha256(authoritative.canonicalBytes) == authoritative.contentDigest else {
                    throw DomainPersistenceError.corruptJournal
                }
                let validated = try core.amendDeletionTombstoneCleanup(
                    authoritativeTombstoneBytes: authoritative.canonicalBytes,
                    cleanupWarningsBytes: try encode(cleanupWarnings)
                )
                guard validated.workspaceID == original.workspaceID,
                      validated.operationID == original.operation.operationID,
                      validated.schemaVersion == UInt16(DomainDeletionTombstone.schemaVersion),
                      DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                let tombstone = try JSONDecoder().decode(
                    DomainDeletionTombstone.self,
                    from: validated.canonicalBytes
                )
                let expectedDiagnostic =
                    "artifact_cleanup_incomplete: \(cleanupWarnings.joined(separator: "; "))"
                guard let originalJSON = try JSONSerialization.jsonObject(
                    with: authoritative.canonicalBytes
                ) as? [String: Any],
                    var amendedJSON = try JSONSerialization.jsonObject(
                        with: validated.canonicalBytes
                    ) as? [String: Any],
                    let originalOperation = originalJSON["operation"] as? [String: Any],
                    var amendedOperation = amendedJSON["operation"] as? [String: Any],
                    amendedOperation["diagnostic"] as? String == expectedDiagnostic,
                    tombstone.operation.diagnostic == expectedDiagnostic
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                amendedOperation["diagnostic"] = originalOperation["diagnostic"] ?? NSNull()
                amendedJSON["operation"] = amendedOperation
                guard (amendedJSON as NSDictionary).isEqual(originalJSON as NSDictionary) else {
                    throw DomainPersistenceError.corruptJournal
                }
                return DomainWorkspaceDeletionTombstoneValidation(
                    tombstone: tombstone,
                    canonicalBytes: validated.canonicalBytes,
                    contentDigest: validated.contentDigest
                )
            } catch {
                throw mapMetadataPlan(error)
            }
        }

        func validateDeletionTombstone(
            _ bytes: Data
        ) throws -> DomainWorkspaceDeletionTombstoneValidation {
            do {
                let validated = try core.validateDeletionTombstone(bytes)
                guard validated.schemaVersion == UInt16(DomainDeletionTombstone.schemaVersion),
                      DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                let tombstone = try JSONDecoder().decode(
                    DomainDeletionTombstone.self,
                    from: validated.canonicalBytes
                )
                guard tombstone.version == DomainDeletionTombstone.schemaVersion,
                      tombstone.workspaceID == validated.workspaceID,
                      tombstone.operation.operationID == validated.operationID
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                return DomainWorkspaceDeletionTombstoneValidation(
                    tombstone: tombstone,
                    canonicalBytes: validated.canonicalBytes,
                    contentDigest: validated.contentDigest
                )
            } catch {
                let mapped = map(error)
                switch mapped {
                case .writeFailed("working_journal_too_large"),
                     .writeFailed("working_journal_rust_unavailable"):
                    throw mapped
                default:
                    throw DomainPersistenceError.corruptJournal
                }
            }
        }

        func validateCatalog(
            _ bytes: Data
        ) throws -> DomainWorkspaceCatalogValidation {
            do {
                return try materializeCatalog(core.validateCatalog(bytes))
            } catch {
                let mapped = map(error)
                if mapped == .writeFailed("working_journal_too_large") {
                    throw DomainPersistenceError.writeFailed("workspace_catalog_too_large")
                }
                throw mapped
            }
        }

        func seedCatalog(
            entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry],
            updatedAt: Date
        ) throws -> DomainWorkspaceCatalogValidation {
            do {
                let candidate = try materializeCatalog(core.seedCatalog(
                    seedRequestBytes: try encode(DomainWorkspaceCatalogSeedRequest(
                        entries: entries,
                        updatedAt: updatedAt
                    ))
                ))
                guard candidate.catalog.revision == 0,
                      candidate.catalog.updatedAt == updatedAt,
                      candidate.catalog.entries == entries,
                      candidate.catalog.deletions?.isEmpty == true
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                return candidate
            } catch {
                let mapped = map(error)
                switch mapped {
                case .writeFailed("working_journal_too_large"):
                    throw DomainPersistenceError.writeFailed("workspace_catalog_too_large")
                case .writeFailed("working_journal_rust_unavailable"):
                    throw mapped
                default:
                    throw DomainPersistenceError.writeFailed("workspace_catalog_transition_invalid")
                }
            }
        }

        func beginCreateTransaction(
            rawCatalogBytes: Data?,
            effectiveCatalog: DomainWorkspaceCatalogValidation,
            document: DomainWorkspaceDocument,
            contextRevisions: [UUID: DomainRevisionState],
            operation: DomainRecordedOperation,
            updatedAt: Date,
            commandAdmission: PreparedCommandAdmission
        ) throws -> PreparedCreateTransaction {
            try beginCreateTransaction(
                rawCatalogBytes: rawCatalogBytes,
                effectiveCatalog: effectiveCatalog,
                rawJournalBytes: nil,
                effectiveJournal: nil,
                document: document,
                request: CreateTransactionRequest(
                    kind: "create",
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedCatalogRevision: effectiveCatalog.catalog.revision,
                    operationID: operation.operationID,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    operation: operation,
                    updatedAt: updatedAt
                ),
                expectedOperation: operation,
                isRecovery: false,
                commandAdmission: commandAdmission
            )
        }

        func beginCreateRecoveryTransaction(
            rawCatalogBytes: Data?,
            effectiveCatalog: DomainWorkspaceCatalogValidation,
            rawJournalBytes: Data,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation,
            document: DomainWorkspaceDocument,
            updatedAt: Date
        ) throws -> PreparedCreateTransaction {
            try beginCreateTransaction(
                rawCatalogBytes: rawCatalogBytes,
                effectiveCatalog: effectiveCatalog,
                rawJournalBytes: rawJournalBytes,
                effectiveJournal: effectiveJournal,
                document: document,
                request: CreateTransactionRequest(
                    kind: "recover",
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedCatalogRevision: effectiveCatalog.catalog.revision,
                    operationID: nil,
                    contextRevisions: nil,
                    contextDigests: nil,
                    operation: nil,
                    updatedAt: updatedAt
                ),
                expectedOperation: nil,
                isRecovery: true,
                commandAdmission: nil
            )
        }

        private func beginCreateTransaction(
            rawCatalogBytes: Data?,
            effectiveCatalog: DomainWorkspaceCatalogValidation,
            rawJournalBytes: Data?,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation?,
            document: DomainWorkspaceDocument,
            request: CreateTransactionRequest,
            expectedOperation: DomainRecordedOperation?,
            isRecovery: Bool,
            commandAdmission: PreparedCommandAdmission?
        ) throws -> PreparedCreateTransaction {
            do {
                let transaction = try core.beginCreateTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalogBytes: effectiveCatalog.canonicalBytes,
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal?.canonicalBytes,
                    requestBytes: try encode(request),
                    documentBytes: document.documentBytes,
                    commandAdmission: commandAdmission?.transactionBinding
                )
                return PreparedCreateTransaction(
                    core: transaction,
                    validator: self,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedOperation: expectedOperation,
                    expectedCatalogRevision: effectiveCatalog.catalog.revision,
                    expectedDocumentDigest: document.contentDigest,
                    expectedUpdatedAt: request.updatedAt,
                    isRecovery: isRecovery
                )
            } catch {
                if let validationError = error as? CoreWorkspaceWorkingJournalValidationError,
                   validationError == .invalidRevisionState
                {
                    throw DomainPersistenceError.stateConflict(
                        expected: request.expectedCatalogRevision,
                        actual: effectiveCatalog.catalog.revision
                    )
                }
                throw map(error)
            }
        }

        func beginDeleteTransaction(
            rawCatalogBytes: Data?,
            effectiveCatalog: DomainWorkspaceCatalogValidation,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation,
            document: DomainWorkspaceDocument,
            expectedWorkingRevision: UInt64,
            expectedCatalogRevision: UInt64,
            operation: DomainRecordedOperation,
            deletedAt: Date,
            commandAdmission: PreparedCommandAdmission
        ) throws -> PreparedDeleteTransaction {
            do {
                let request = DeleteTransactionRequest(
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedWorkingRevision: expectedWorkingRevision,
                    expectedCatalogRevision: expectedCatalogRevision,
                    operation: operation,
                    deletedAt: deletedAt
                )
                let transaction = try core.beginDeleteTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalogBytes: effectiveCatalog.canonicalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    commandAdmission: commandAdmission.transactionBinding
                )
                return PreparedDeleteTransaction(
                    core: transaction,
                    validator: self,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedOperation: operation,
                    expectedWorkingRevision: expectedWorkingRevision,
                    expectedCatalogRevision: expectedCatalogRevision,
                    expectedDeletedAt: deletedAt
                )
            } catch {
                if let validationError = error as? CoreWorkspaceWorkingJournalValidationError {
                    if validationError == .invalidRevisionState {
                        if effectiveCatalog.catalog.revision != expectedCatalogRevision {
                            throw DomainPersistenceError.stateConflict(
                                expected: expectedCatalogRevision,
                                actual: effectiveCatalog.catalog.revision
                            )
                        }
                        throw DomainPersistenceError.stateConflict(
                            expected: expectedWorkingRevision,
                            actual: effectiveJournal.journal.revisions.workingRevision
                        )
                    }
                    if validationError == .invalidTransaction {
                        throw DomainPersistenceError.writeFailed(
                            "workspace_delete_transaction_invalid"
                        )
                    }
                }
                throw map(error)
            }
        }

        func beginJournalMutationTransaction(
            rawJournalBytes: Data?,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation,
            document: DomainWorkspaceDocument,
            transition: DomainWorkspaceWorkingJournalTransition,
            catalogRevision: UInt64,
            revisionOperationID: UUID?,
            updatedAt: Date,
            diskDocumentBytes: Data?,
            commandAdmission: PreparedCommandAdmission?
        ) throws -> PreparedJournalMutationTransaction {
            do {
                let request = JournalMutationTransactionRequest(
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    catalogRevision: catalogRevision,
                    revisionOperationID: revisionOperationID,
                    transition: transition.encoded
                )
                let transaction = try core.beginJournalMutationTransaction(
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    candidateDocumentBytes: document.documentBytes,
                    diskDocumentBytes: diskDocumentBytes,
                    commandAdmission: commandAdmission?.transactionBinding
                )
                return PreparedJournalMutationTransaction(
                    core: transaction,
                    validator: self,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedTransition: transition,
                    expectedCatalogRevision: catalogRevision,
                    expectedDocumentDigest: document.contentDigest,
                    revisionOperationID: revisionOperationID,
                    expectedUpdatedAt: updatedAt
                )
            } catch {
                if error as? CoreWorkspaceWorkingJournalValidationError == .invalidRevisionState {
                    let expected: UInt64 = switch transition {
                    case let .unchanged(revision, _, _),
                         let .working(revision, _, _, _, _, _, _),
                         let .externalReload(revision, _, _, _, _, _, _):
                        revision
                    case let .conflictRebase(revisions, _, _, _, _, _, _, _):
                        revisions.workingRevision
                    case .seed, .recoverPending, .create, .save:
                        effectiveJournal.journal.revisions.workingRevision
                    }
                    throw DomainPersistenceError.stateConflict(
                        expected: expected,
                        actual: effectiveJournal.journal.revisions.workingRevision
                    )
                }
                throw map(error)
            }
        }

        func beginSaveTransaction(
            rawJournalBytes: Data?,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation,
            document: DomainWorkspaceDocument,
            expectedWorkingRevision: UInt64,
            operationID: UUID,
            contextRevisions: [UUID: DomainRevisionState],
            contextTombstones: [UUID: UInt64],
            operations: [DomainRecordedOperation],
            updatedAt: Date,
            catalogRevision: UInt64,
            diskDocumentBytes: Data?,
            commandAdmission: PreparedCommandAdmission
        ) throws -> PreparedSaveTransaction {
            do {
                let request = SaveTransactionRequest(
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedWorkingRevision: expectedWorkingRevision,
                    operationID: operationID,
                    contextRevisions: contextRevisions,
                    contextDigests: Dictionary(uniqueKeysWithValues: document.metadata.contexts.map {
                        ($0.identity.contextID, $0.contentDigest)
                    }),
                    contextTombstones: contextTombstones,
                    operations: operations,
                    updatedAt: updatedAt,
                    catalogRevision: catalogRevision
                )
                let transaction = try core.beginSaveTransaction(
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    candidateDocumentBytes: document.documentBytes,
                    diskDocumentBytes: diskDocumentBytes,
                    commandAdmission: commandAdmission.transactionBinding
                )
                return PreparedSaveTransaction(
                    core: transaction,
                    validator: self,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedOperationID: operationID,
                    expectedCatalogRevision: catalogRevision,
                    expectedDocumentDigest: document.contentDigest,
                    expectedWorkingRevision: expectedWorkingRevision,
                    expectedUpdatedAt: updatedAt
                )
            } catch {
                throw map(error)
            }
        }

        func resolvePendingSave(
            rawJournalBytes: Data,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            documentBytes: Data?
        ) throws -> DomainWorkspacePendingSaveRecovery {
            do {
                let result = try core.resolvePendingSave(
                    rawJournalBytes: rawJournalBytes,
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedFileURL: expectedFileURL.standardizedFileURL,
                    documentBytes: documentBytes
                )
                switch result {
                case let .noPending(validation):
                    return .noPending(try materialize(
                        validation,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL
                    ))
                case let .pendingNotCommitted(validation):
                    return .pendingNotCommitted(try materialize(
                        validation,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL
                    ))
                case let .committed(validation, documentDigest):
                    let clean = try materialize(
                        validation,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL
                    )
                    guard clean.journal.pendingSave == nil,
                          clean.journal.savedDigest == documentDigest
                    else {
                        throw DomainPersistenceError.corruptJournal
                    }
                    return .committed(
                        cleanJournal: clean,
                        documentDigest: documentDigest
                    )
                }
            } catch {
                throw map(error)
            }
        }

        fileprivate func materializeCreateDirective(
            _ directive: CoreWorkspaceCreateDirectiveV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation?,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedUpdatedAt: Date,
            isRecovery: Bool
        ) throws -> DomainWorkspaceCreateDirective {
            do {
                switch directive {
                case let .action(
                    actionID,
                    requestDigest,
                    kind,
                    expectedRawDigest,
                    canonicalBytes,
                    contentDigest,
                    logicalExpectedRevision,
                    authorityReceipt
                ):
                    switch kind {
                    case .writePendingJournal, .writeCommittedJournal:
                        guard !isRecovery,
                              authorityReceipt == nil,
                              let expectedOperation,
                              let logicalExpectedRevision
                        else { throw DomainPersistenceError.corruptJournal }
                        let journal = try materialize(
                            CoreWorkspaceWorkingJournalValidationV1(
                                workspaceID: expectedWorkspaceID,
                                journalVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL
                        )
                        guard journal.journal.operations.contains(expectedOperation) else {
                            throw DomainPersistenceError.corruptJournal
                        }
                        if kind == .writePendingJournal {
                            return .writePendingJournal(
                                actionID: actionID,
                                expectedRawDigest: expectedRawDigest,
                                validation: journal,
                                logicalExpectedRevision: logicalExpectedRevision
                            )
                        }
                        guard let expectedRawDigest else {
                            throw DomainPersistenceError.corruptJournal
                        }
                        return .writeCommittedJournal(
                            actionID: actionID,
                            expectedRawDigest: expectedRawDigest,
                            validation: journal,
                            logicalExpectedRevision: logicalExpectedRevision
                        )
                    case .writeSavedRevision:
                        guard !isRecovery,
                              authorityReceipt == nil,
                              let expectedOperation,
                              expectedRawDigest == nil,
                              logicalExpectedRevision == nil
                        else { throw DomainPersistenceError.corruptJournal }
                        let validation = try materializeSavedRevision(
                            CoreWorkspacePersistenceMetadataValidationV1(
                                workspaceID: expectedWorkspaceID,
                                operationID: expectedOperation.operationID,
                                schemaVersion: UInt16(DomainSavedRevisionRecord.schemaVersion),
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedOperationID: expectedOperation.operationID,
                            expectedSavedRevision: 1,
                            expectedDocumentDigest: expectedDocumentDigest,
                            expectedUpdatedAt: expectedUpdatedAt
                        )
                        return .writeSavedRevision(actionID: actionID, validation: validation)
                    case .publishWorkspaceDocument:
                        guard !isRecovery,
                              authorityReceipt == nil,
                              expectedRawDigest == nil,
                              logicalExpectedRevision == nil,
                              contentDigest == expectedDocumentDigest,
                              canonicalBytes.count <= CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes
                        else { throw DomainPersistenceError.corruptJournal }
                        return .publishWorkspaceDocument(
                            actionID: actionID,
                            bytes: canonicalBytes,
                            contentDigest: contentDigest
                        )
                    case .removeDeletionSidecar:
                        guard !isRecovery,
                              authorityReceipt == nil,
                              expectedRawDigest == nil,
                              logicalExpectedRevision == nil,
                              canonicalBytes.isEmpty
                        else { throw DomainPersistenceError.corruptJournal }
                        return .removeDeletionSidecar(
                            actionID: actionID,
                            contentDigest: contentDigest
                        )
                    case .publishCatalog:
                        guard let authorityReceipt,
                              authorityReceipt.requestDigest == requestDigest,
                              let logicalExpectedRevision
                        else { throw DomainPersistenceError.corruptJournal }
                        let receipt = try materializeCreateCommitReceipt(
                            authorityReceipt,
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL,
                            expectedOperation: expectedOperation,
                            expectedCatalogRevision: expectedCatalogRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            expectedUpdatedAt: expectedUpdatedAt,
                            isRecovery: isRecovery
                        )
                        guard receipt.catalog.canonicalBytes == canonicalBytes,
                              receipt.catalog.contentDigest == contentDigest,
                              logicalExpectedRevision == expectedCatalogRevision
                        else { throw DomainPersistenceError.corruptJournal }
                        return .publishCatalog(
                            actionID: actionID,
                            expectedRawDigest: expectedRawDigest,
                            catalog: receipt.catalog,
                            logicalExpectedRevision: logicalExpectedRevision,
                            authorityReceipt: receipt
                        )
                    }
                case let .committed(receipt):
                    return .committed(try materializeCreateCommitReceipt(
                        receipt,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL,
                        expectedOperation: expectedOperation,
                        expectedCatalogRevision: expectedCatalogRevision,
                        expectedDocumentDigest: expectedDocumentDigest,
                        expectedUpdatedAt: expectedUpdatedAt,
                        isRecovery: isRecovery
                    ))
                case let .failed(failure):
                    let mapped: DomainWorkspaceCreateFailure = switch failure {
                    case .cancelled: .cancelled
                    case let .stateConflict(expected, actual):
                        .stateConflict(expected: expected, actual: actual)
                    case .writeFailed: .writeFailed
                    }
                    return .failed(mapped)
                }
            } catch {
                throw map(error)
            }
        }

        private func materializeCreateCommitReceipt(
            _ receipt: CoreWorkspaceCreateCommitReceiptV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation?,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedUpdatedAt: Date,
            isRecovery: Bool
        ) throws -> DomainWorkspaceCreateCommitReceipt {
            let nextRevision = expectedCatalogRevision.addingReportingOverflow(1)
            guard !nextRevision.overflow,
                  receipt.workspaceID == expectedWorkspaceID,
                  receipt.documentDigest == expectedDocumentDigest
            else { throw DomainPersistenceError.corruptJournal }
            let catalog = try materializeCatalog(receipt.catalog)
            let journal = try materialize(
                receipt.committedJournal,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL
            )
            guard catalog.catalog.revision == nextRevision.partialValue,
                  catalog.catalog.updatedAt == expectedUpdatedAt,
                  catalog.catalog.entries.contains(where: {
                      $0.workspaceID == expectedWorkspaceID
                          && $0.fileURL.standardizedFileURL == expectedFileURL.standardizedFileURL
                  }),
                  catalog.catalog.deletions?.contains(where: {
                      $0.workspaceID == expectedWorkspaceID
                  }) != true,
                  journal.journal.pendingSave == nil,
                  journal.journal.workingDocument == nil,
                  journal.journal.revisions.dirtyRevision == nil,
                  journal.journal.savedDigest == expectedDocumentDigest,
                  let marker = journal.journal.operations.first(where: {
                      $0.operationID == receipt.operationID
                          && $0.disposition == .applied
                          && $0.before == nil
                          && $0.after == journal.journal.revisions
                          && $0.catalogRevision == nextRevision.partialValue
                          && $0.resultingDigest == expectedDocumentDigest
                          && $0.errorCode == nil
                          && $0.diagnostic == nil
                  }),
                  expectedOperation == nil || marker == expectedOperation,
                  receipt.savedRevision == nil ? isRecovery : !isRecovery
            else { throw DomainPersistenceError.corruptJournal }
            let savedRevision = try receipt.savedRevision.map {
                try materializeSavedRevision(
                    $0,
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedOperationID: receipt.operationID,
                    expectedSavedRevision: journal.journal.revisions.savedRevision,
                    expectedDocumentDigest: expectedDocumentDigest,
                    expectedUpdatedAt: expectedUpdatedAt
                )
            }
            return DomainWorkspaceCreateCommitReceipt(
                workspaceID: expectedWorkspaceID,
                operationID: receipt.operationID,
                requestDigest: receipt.requestDigest,
                documentDigest: expectedDocumentDigest,
                catalog: catalog,
                committedJournal: journal,
                savedRevision: savedRevision
            )
        }

        fileprivate func materializeDeleteDirective(
            _ directive: CoreWorkspaceDeleteDirectiveV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation,
            expectedWorkingRevision: UInt64,
            expectedCatalogRevision: UInt64,
            expectedDeletedAt: Date
        ) throws -> DomainWorkspaceDeleteDirective {
            do {
                switch directive {
                case let .publishCatalog(
                    actionID,
                    requestDigest,
                    expectedRawCatalogDigest,
                    catalog,
                    logicalExpectedRevision,
                    authorityReceipt
                ):
                    guard logicalExpectedRevision == expectedCatalogRevision,
                          authorityReceipt.requestDigest == requestDigest
                    else { throw DomainPersistenceError.corruptJournal }
                    let receipt = try materializeDeleteCommitReceipt(
                        authorityReceipt,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL,
                        expectedOperation: expectedOperation,
                        expectedCatalogRevision: expectedCatalogRevision,
                        expectedDeletedAt: expectedDeletedAt
                    )
                    let materializedCatalog = try materializeCatalog(catalog)
                    guard materializedCatalog.canonicalBytes == receipt.catalog.canonicalBytes,
                          materializedCatalog.contentDigest == receipt.catalog.contentDigest
                    else { throw DomainPersistenceError.corruptJournal }
                    return .publishCatalog(
                        actionID: actionID,
                        expectedRawDigest: expectedRawCatalogDigest,
                        catalog: materializedCatalog,
                        logicalExpectedRevision: logicalExpectedRevision,
                        authorityReceipt: receipt
                    )
                case let .committed(receipt):
                    return .committed(try materializeDeleteCommitReceipt(
                        receipt,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL,
                        expectedOperation: expectedOperation,
                        expectedCatalogRevision: expectedCatalogRevision,
                        expectedDeletedAt: expectedDeletedAt
                    ))
                case let .failed(failure):
                    let mapped: DomainWorkspaceDeleteFailure = switch failure {
                    case .cancelled: .cancelled
                    case let .stateConflict(expected, actual):
                        .stateConflict(expected: expected, actual: actual)
                    case .writeFailed: .writeFailed
                    }
                    return .failed(mapped)
                }
            } catch {
                throw map(error)
            }
        }

        private func materializeDeleteCommitReceipt(
            _ receipt: CoreWorkspaceDeleteCommitReceiptV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation,
            expectedCatalogRevision: UInt64,
            expectedDeletedAt: Date
        ) throws -> DomainWorkspaceDeleteCommitReceipt {
            let nextRevision = expectedCatalogRevision.addingReportingOverflow(1)
            guard !nextRevision.overflow,
                  receipt.workspaceID == expectedWorkspaceID,
                  receipt.operationID == expectedOperation.operationID
            else { throw DomainPersistenceError.corruptJournal }
            let catalog = try materializeCatalog(receipt.catalog)
            guard catalog.catalog.revision == nextRevision.partialValue,
                  catalog.catalog.updatedAt == expectedDeletedAt
            else { throw DomainPersistenceError.corruptJournal }
            let tombstoneBytes = receipt.tombstone.canonicalBytes
            guard receipt.tombstone.workspaceID == expectedWorkspaceID,
                  receipt.tombstone.operationID == expectedOperation.operationID,
                  receipt.tombstone.schemaVersion == UInt16(DomainDeletionTombstone.schemaVersion),
                  DomainContentDigest.sha256(tombstoneBytes) == receipt.tombstone.contentDigest
            else { throw DomainPersistenceError.corruptJournal }
            let tombstone = try JSONDecoder().decode(
                DomainDeletionTombstone.self,
                from: tombstoneBytes
            )
            guard tombstone.workspaceID == expectedWorkspaceID,
                  tombstone.fileURL.standardizedFileURL == expectedFileURL.standardizedFileURL,
                  tombstone.deletedAt == expectedDeletedAt,
                  tombstone.operation == expectedOperation,
                  !catalog.catalog.entries.contains(where: {
                      $0.workspaceID == expectedWorkspaceID
                  }),
                  catalog.catalog.deletions?.contains(tombstone) == true
            else { throw DomainPersistenceError.corruptJournal }
            return DomainWorkspaceDeleteCommitReceipt(
                workspaceID: expectedWorkspaceID,
                operationID: expectedOperation.operationID,
                requestDigest: receipt.requestDigest,
                catalog: catalog,
                tombstone: DomainWorkspaceDeletionTombstoneValidation(
                    tombstone: tombstone,
                    canonicalBytes: tombstoneBytes,
                    contentDigest: receipt.tombstone.contentDigest
                )
            )
        }

        private func materializeJournalMutationFinalization(
            _ value: CoreWorkspaceJournalMutationFinalizationV1
        ) -> DomainWorkspaceJournalMutationFinalization {
            switch value {
            case .finalized: .finalized
            case .revisionSidecarMissing: .revisionSidecarMissing
            }
        }

        private func materializeSaveFinalization(
            _ value: CoreWorkspaceSaveFinalizationV1
        ) -> DomainWorkspaceSaveFinalization {
            switch value {
            case .finalized: .finalized
            case .pendingJournalRetained: .pendingJournalRetained
            case .revisionSidecarMissing: .revisionSidecarMissing
            }
        }

        fileprivate func materializeJournalMutationDirective(
            _ directive: CoreWorkspaceJournalMutationDirectiveV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedTransition: DomainWorkspaceWorkingJournalTransition,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            revisionOperationID: UUID?,
            expectedUpdatedAt: Date
        ) throws -> DomainWorkspaceJournalMutationDirective {
            do {
                switch directive {
                case let .action(
                    actionID,
                    requestDigest,
                    kind,
                    expectedRawJournalDigest,
                    canonicalBytes,
                    contentDigest,
                    logicalExpectedRevision,
                    authorityReceipt,
                    postAuthoritySuccessFinalization,
                    postAuthorityFailureFinalization
                ):
                    let successFinalization = postAuthoritySuccessFinalization.map(
                        materializeJournalMutationFinalization
                    )
                    let failureFinalization = postAuthorityFailureFinalization.map(
                        materializeJournalMutationFinalization
                    )
                    switch kind {
                    case .writeJournal:
                        guard let logicalExpectedRevision,
                              let authorityReceipt,
                              let successFinalization,
                              authorityReceipt.requestDigest == requestDigest
                        else { throw DomainPersistenceError.corruptJournal }
                        let receipt = try materializeJournalMutationCommitReceipt(
                            authorityReceipt,
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL,
                            expectedTransition: expectedTransition,
                            expectedCatalogRevision: expectedCatalogRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            revisionOperationID: revisionOperationID,
                            expectedUpdatedAt: expectedUpdatedAt
                        )
                        let validation = try materialize(
                            CoreWorkspaceWorkingJournalValidationV1(
                                workspaceID: expectedWorkspaceID,
                                journalVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL
                        )
                        guard validation.canonicalBytes == receipt.committedJournal.canonicalBytes,
                              validation.contentDigest == receipt.committedJournal.contentDigest,
                              logicalExpectedRevision == expectedTransition.expectedWorkingRevision,
                              successFinalization == (
                                  receipt.savedRevision == nil ? .finalized : .revisionSidecarMissing
                              ),
                              failureFinalization == nil
                        else { throw DomainPersistenceError.corruptJournal }
                        return .writeJournal(
                            actionID: actionID,
                            expectedRawDigest: expectedRawJournalDigest,
                            validation: validation,
                            logicalExpectedRevision: logicalExpectedRevision,
                            authorityReceipt: receipt,
                            postAuthoritySuccessFinalization: successFinalization
                        )
                    case .writeSavedRevision:
                        guard authorityReceipt == nil,
                              expectedRawJournalDigest == nil,
                              logicalExpectedRevision == nil,
                              let successFinalization,
                              let failureFinalization,
                              successFinalization == .finalized,
                              failureFinalization == .revisionSidecarMissing,
                              let revisionOperationID,
                              let expectedSavedRevision = expectedTransition.resultingSavedRevision
                        else { throw DomainPersistenceError.corruptJournal }
                        let validation = try materializeSavedRevision(
                            CoreWorkspacePersistenceMetadataValidationV1(
                                workspaceID: expectedWorkspaceID,
                                operationID: revisionOperationID,
                                schemaVersion: UInt16(DomainSavedRevisionRecord.schemaVersion),
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedOperationID: revisionOperationID,
                            expectedSavedRevision: expectedSavedRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            expectedUpdatedAt: expectedUpdatedAt
                        )
                        return .writeSavedRevision(
                            actionID: actionID,
                            validation: validation,
                            postAuthoritySuccessFinalization: successFinalization,
                            postAuthorityFailureFinalization: failureFinalization
                        )
                    }
                case let .committed(receipt, finalization):
                    return .committed(
                        receipt: try materializeJournalMutationCommitReceipt(
                            receipt,
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL,
                            expectedTransition: expectedTransition,
                            expectedCatalogRevision: expectedCatalogRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            revisionOperationID: revisionOperationID,
                            expectedUpdatedAt: expectedUpdatedAt
                        ),
                        finalization: materializeJournalMutationFinalization(finalization)
                    )
                case let .failed(failure):
                    let mapped: DomainWorkspaceSaveFailure = switch failure {
                    case .cancelled: .cancelled
                    case let .stateConflict(expected, actual):
                        .stateConflict(expected: expected, actual: actual)
                    case .writeFailed: .writeFailed
                    }
                    return .failed(mapped)
                }
            } catch {
                throw map(error)
            }
        }

        private func materializeJournalMutationCommitReceipt(
            _ receipt: CoreWorkspaceJournalMutationCommitReceiptV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedTransition: DomainWorkspaceWorkingJournalTransition,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            revisionOperationID: UUID?,
            expectedUpdatedAt: Date
        ) throws -> DomainWorkspaceJournalMutationCommitReceipt {
            guard receipt.workspaceID == expectedWorkspaceID,
                  receipt.catalogRevision == expectedCatalogRevision
            else { throw DomainPersistenceError.corruptJournal }
            let validation = try materialize(
                receipt.committedJournal,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL
            )
            let journal = validation.journal
            guard journal.revisions.workingRevision == receipt.resultingWorkingRevision,
                  journal.revisions.savedRevision == receipt.resultingSavedRevision,
                  journal.updatedAt == expectedUpdatedAt,
                  journal.revisions.workingRevision == expectedTransition.resultingWorkingRevision
            else { throw DomainPersistenceError.corruptJournal }

            let expectedSavedRevision = expectedTransition.resultingSavedRevision
            let savedRevision = try receipt.savedRevision.map { raw in
                guard let revisionOperationID,
                      let expectedSavedRevision
                else { throw DomainPersistenceError.corruptJournal }
                return try materializeSavedRevision(
                    raw,
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedOperationID: revisionOperationID,
                    expectedSavedRevision: expectedSavedRevision,
                    expectedDocumentDigest: expectedDocumentDigest,
                    expectedUpdatedAt: expectedUpdatedAt
                )
            }
            guard (savedRevision != nil) == (revisionOperationID != nil),
                  expectedTransition.matches(
                      journal: journal,
                      documentDigest: expectedDocumentDigest
                  )
            else { throw DomainPersistenceError.corruptJournal }
            return DomainWorkspaceJournalMutationCommitReceipt(
                workspaceID: expectedWorkspaceID,
                requestDigest: receipt.requestDigest,
                catalogRevision: expectedCatalogRevision,
                committedJournal: validation,
                savedRevision: savedRevision
            )
        }

        fileprivate func materializeSaveDirective(
            _ directive: CoreWorkspaceSaveDirectiveV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperationID: UUID,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedWorkingRevision: UInt64,
            expectedUpdatedAt: Date
        ) throws -> DomainWorkspaceSaveDirective {
            do {
                switch directive {
                case let .action(
                    actionID,
                    requestDigest,
                    kind,
                    expectedRawJournalDigest,
                    canonicalBytes,
                    contentDigest,
                    logicalExpectedRevision,
                    authorityReceipt,
                    postAuthoritySuccessFinalization,
                    postAuthorityFailureFinalization
                ):
                    let successFinalization = postAuthoritySuccessFinalization.map(
                        materializeSaveFinalization
                    )
                    let failureFinalization = postAuthorityFailureFinalization.map(
                        materializeSaveFinalization
                    )
                    switch kind {
                    case .writePendingJournal:
                        guard authorityReceipt == nil,
                              logicalExpectedRevision == expectedWorkingRevision,
                              successFinalization == nil,
                              failureFinalization == nil
                        else { throw DomainPersistenceError.corruptJournal }
                        let validation = try materialize(
                            CoreWorkspaceWorkingJournalValidationV1(
                                workspaceID: expectedWorkspaceID,
                                journalVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL
                        )
                        guard validation.journal.pendingSave?.operationID == expectedOperationID else {
                            throw DomainPersistenceError.corruptJournal
                        }
                        return .writePendingJournal(
                            actionID: actionID,
                            expectedRawDigest: expectedRawJournalDigest,
                            validation: validation,
                            logicalExpectedRevision: expectedWorkingRevision
                        )
                    case .publishWorkspaceDocument:
                        guard expectedRawJournalDigest == nil,
                              logicalExpectedRevision == nil,
                              contentDigest == expectedDocumentDigest,
                              let receipt = authorityReceipt,
                              let successFinalization,
                              successFinalization == .pendingJournalRetained,
                              failureFinalization == nil,
                              receipt.requestDigest == requestDigest
                        else { throw DomainPersistenceError.corruptJournal }
                        return .publishWorkspaceDocument(
                            actionID: actionID,
                            bytes: canonicalBytes,
                            contentDigest: contentDigest,
                            authorityReceipt: try materializeSaveCommitReceipt(
                                receipt,
                                expectedWorkspaceID: expectedWorkspaceID,
                                expectedFileURL: expectedFileURL,
                                expectedOperationID: expectedOperationID,
                                expectedCatalogRevision: expectedCatalogRevision,
                                expectedDocumentDigest: expectedDocumentDigest,
                                expectedWorkingRevision: expectedWorkingRevision,
                                expectedUpdatedAt: expectedUpdatedAt
                            ),
                            postAuthoritySuccessFinalization: successFinalization
                        )
                    case .writeCommittedJournal:
                        guard authorityReceipt == nil,
                              let expectedRawJournalDigest,
                              logicalExpectedRevision == expectedWorkingRevision,
                              let successFinalization,
                              let failureFinalization,
                              successFinalization == .revisionSidecarMissing,
                              failureFinalization == .pendingJournalRetained
                        else { throw DomainPersistenceError.corruptJournal }
                        let validation = try materialize(
                            CoreWorkspaceWorkingJournalValidationV1(
                                workspaceID: expectedWorkspaceID,
                                journalVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL
                        )
                        guard validation.journal.pendingSave == nil,
                              validation.journal.savedDigest == expectedDocumentDigest
                        else { throw DomainPersistenceError.corruptJournal }
                        return .writeCommittedJournal(
                            actionID: actionID,
                            expectedRawDigest: expectedRawJournalDigest,
                            validation: validation,
                            logicalExpectedRevision: expectedWorkingRevision,
                            postAuthoritySuccessFinalization: successFinalization,
                            postAuthorityFailureFinalization: failureFinalization
                        )
                    case .writeSavedRevision:
                        guard authorityReceipt == nil,
                              expectedRawJournalDigest == nil,
                              logicalExpectedRevision == nil,
                              let successFinalization,
                              let failureFinalization,
                              successFinalization == .finalized,
                              failureFinalization == .revisionSidecarMissing
                        else { throw DomainPersistenceError.corruptJournal }
                        let validation = try materializeSavedRevision(
                            CoreWorkspacePersistenceMetadataValidationV1(
                                workspaceID: expectedWorkspaceID,
                                operationID: expectedOperationID,
                                schemaVersion: CoreWorkspaceWorkingJournalValidationV1.contractVersion,
                                contentDigest: contentDigest,
                                canonicalBytes: canonicalBytes
                            ),
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedOperationID: expectedOperationID,
                            expectedSavedRevision: expectedWorkingRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            expectedUpdatedAt: expectedUpdatedAt
                        )
                        return .writeSavedRevision(
                            actionID: actionID,
                            validation: validation,
                            postAuthoritySuccessFinalization: successFinalization,
                            postAuthorityFailureFinalization: failureFinalization
                        )
                    }
                case let .committed(receipt, finalization):
                    return .committed(
                        receipt: try materializeSaveCommitReceipt(
                            receipt,
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL,
                            expectedOperationID: expectedOperationID,
                            expectedCatalogRevision: expectedCatalogRevision,
                            expectedDocumentDigest: expectedDocumentDigest,
                            expectedWorkingRevision: expectedWorkingRevision,
                            expectedUpdatedAt: expectedUpdatedAt
                        ),
                        finalization: materializeSaveFinalization(finalization)
                    )
                case let .failed(failure):
                    let mapped: DomainWorkspaceSaveFailure = switch failure {
                    case .cancelled: .cancelled
                    case let .stateConflict(expected, actual):
                        .stateConflict(expected: expected, actual: actual)
                    case .writeFailed: .writeFailed
                    }
                    return .failed(mapped)
                }
            } catch {
                throw map(error)
            }
        }

        private func materializeSaveCommitReceipt(
            _ receipt: CoreWorkspaceSaveCommitReceiptV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperationID: UUID,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            expectedWorkingRevision: UInt64,
            expectedUpdatedAt: Date
        ) throws -> DomainWorkspaceSaveCommitReceipt {
            guard receipt.workspaceID == expectedWorkspaceID,
                  receipt.operationID == expectedOperationID,
                  receipt.catalogRevision == expectedCatalogRevision,
                  receipt.documentDigest == expectedDocumentDigest,
                  receipt.resultingWorkingRevision == expectedWorkingRevision,
                  receipt.resultingSavedRevision == expectedWorkingRevision
            else { throw DomainPersistenceError.corruptJournal }
            let journal = try materialize(
                receipt.committedJournal,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL
            )
            guard journal.journal.revisions.workingRevision == expectedWorkingRevision,
                  journal.journal.revisions.savedRevision == expectedWorkingRevision,
                  journal.journal.revisions.dirtyRevision == nil,
                  journal.journal.pendingSave == nil,
                  journal.journal.savedDigest == expectedDocumentDigest
            else { throw DomainPersistenceError.corruptJournal }
            let revision = try materializeSavedRevision(
                receipt.savedRevision,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedOperationID: expectedOperationID,
                expectedSavedRevision: expectedWorkingRevision,
                expectedDocumentDigest: expectedDocumentDigest,
                expectedUpdatedAt: expectedUpdatedAt
            )
            return DomainWorkspaceSaveCommitReceipt(
                workspaceID: expectedWorkspaceID,
                operationID: expectedOperationID,
                requestDigest: receipt.requestDigest,
                catalogRevision: expectedCatalogRevision,
                documentDigest: expectedDocumentDigest,
                committedJournal: journal,
                savedRevision: revision
            )
        }

        func requireRuntimeAvailability() throws {
            do {
                try core.requireRuntimeAvailability()
            } catch {
                throw map(error)
            }
        }

        func validateSynchronously(
            _ bytes: Data,
            expectedWorkspaceID: UUID? = nil,
            expectedFileURL: URL? = nil
        ) throws -> DomainWorkspaceWorkingJournalValidation {
            do {
                return try materialize(
                    core.validate(bytes),
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedFileURL: expectedFileURL
                )
            } catch {
                throw map(error)
            }
        }

        func seedWorkingJournal(
            workspaceID: UUID,
            fileURL: URL,
            revisions: DomainRevisionState,
            savedDigest: String,
            contextDigests: [UUID: String],
            updatedAt: Date
        ) throws -> DomainWorkspaceWorkingJournalValidation {
            let transition = DomainWorkspaceWorkingJournalTransition.seed(
                workspaceID: workspaceID,
                fileURL: fileURL,
                revisions: revisions,
                savedDigest: savedDigest,
                contextDigests: contextDigests,
                updatedAt: updatedAt
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let seedRequestBytes = try encoder.encode(transition.encoded)
                return try materialize(
                    core.seedWorkingJournal(seedRequestBytes: seedRequestBytes),
                    expectedWorkspaceID: workspaceID,
                    expectedFileURL: fileURL
                )
            } catch {
                let mapped = map(error)
                switch mapped {
                case .writeFailed("working_journal_too_large"),
                     .writeFailed("working_journal_rust_unavailable"):
                    throw mapped
                default:
                    throw DomainPersistenceError.writeFailed("working_journal_transition_invalid")
                }
            }
        }

        private func encode(_ value: some Encodable) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        }

        private func materializeCatalog(
            _ validated: CoreWorkspaceCatalogValidationV1
        ) throws -> DomainWorkspaceCatalogValidation {
            guard validated.catalogVersion <= UInt16(
                DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.schemaVersion
            ),
            DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
            else {
                throw DomainPersistenceError.corruptJournal
            }
            let catalog = try JSONDecoder().decode(
                DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.self,
                from: validated.canonicalBytes
            )
            guard catalog.version == Int(validated.catalogVersion),
                  catalog.revision == validated.revision,
                  UInt64(catalog.entries.count) == validated.entryCount,
                  UInt64(catalog.deletions?.count ?? 0) == validated.deletionCount
            else {
                throw DomainPersistenceError.corruptJournal
            }
            return DomainWorkspaceCatalogValidation(
                catalog: catalog,
                canonicalBytes: validated.canonicalBytes,
                contentDigest: validated.contentDigest
            )
        }

        private func materializeSavedRevision(
            _ validated: CoreWorkspacePersistenceMetadataValidationV1,
            expectedWorkspaceID: UUID,
            expectedOperationID: UUID?,
            expectedSavedRevision: UInt64?,
            expectedDocumentDigest: String,
            expectedUpdatedAt: Date?
        ) throws -> DomainWorkspaceSavedRevisionValidation {
            guard validated.workspaceID == expectedWorkspaceID,
                  expectedOperationID == nil || validated.operationID == expectedOperationID,
                  validated.schemaVersion == UInt16(DomainSavedRevisionRecord.schemaVersion),
                  DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
            else {
                throw DomainPersistenceError.corruptJournal
            }
            let record = try JSONDecoder().decode(
                DomainSavedRevisionRecord.self,
                from: validated.canonicalBytes
            )
            guard record.version == DomainSavedRevisionRecord.schemaVersion,
                  record.workspaceID == expectedWorkspaceID,
                  record.operationID == validated.operationID,
                  record.documentDigest == expectedDocumentDigest,
                  expectedSavedRevision == nil || record.savedRevision == expectedSavedRevision,
                  expectedUpdatedAt == nil || record.updatedAt == expectedUpdatedAt
            else {
                throw DomainPersistenceError.corruptJournal
            }
            return DomainWorkspaceSavedRevisionValidation(
                record: record,
                canonicalBytes: validated.canonicalBytes,
                contentDigest: validated.contentDigest
            )
        }

        private func mapMetadataPlan(_ error: Error) -> DomainPersistenceError {
            let mapped = map(error)
            return switch mapped {
            case .writeFailed("working_journal_too_large"),
                 .writeFailed("working_journal_rust_unavailable"):
                mapped
            default:
                .writeFailed("workspace_persistence_metadata_invalid")
            }
        }

        private func materialize(
            _ validated: CoreWorkspaceWorkingJournalValidationV1,
            expectedWorkspaceID: UUID?,
            expectedFileURL: URL?
        ) throws -> DomainWorkspaceWorkingJournalValidation {
            guard expectedWorkspaceID == nil || validated.workspaceID == expectedWorkspaceID,
                  validated.journalVersion == UInt16(DomainWorkingJournal.schemaVersion),
                  DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
            else {
                throw DomainPersistenceError.corruptJournal
            }
            let journal: DomainWorkingJournal
            do {
                journal = try JSONDecoder().decode(
                    DomainWorkingJournal.self,
                    from: validated.canonicalBytes
                )
            } catch {
                throw DomainPersistenceError.corruptJournal
            }
            guard journal.workspaceID == validated.workspaceID,
                  journal.version == DomainWorkingJournal.schemaVersion,
                  expectedFileURL == nil
                  || journal.fileURL.standardizedFileURL == expectedFileURL?.standardizedFileURL
            else {
                throw DomainPersistenceError.corruptJournal
            }
            return DomainWorkspaceWorkingJournalValidation(
                journal: journal,
                canonicalBytes: validated.canonicalBytes,
                contentDigest: validated.contentDigest
            )
        }

        private func map(_ error: Error) -> DomainPersistenceError {
            if let error = error as? DomainPersistenceError {
                return error
            }
            guard let error = error as? CoreWorkspaceWorkingJournalValidationError else {
                return .writeFailed("working_journal_rust_unavailable")
            }
            switch error {
            case let .futureSchema(version):
                return .futureJournal(Int(version))
            case .inputTooLarge, .outputTooLarge:
                return .writeFailed("working_journal_too_large")
            case .malformed,
                 .invalidIdentity,
                 .invalidFileURL,
                 .invalidRevisionState,
                 .invalidDigest,
                 .invalidWorkingDocument,
                 .invalidContextTable,
                 .invalidOperationLedger,
                 .invalidPendingSave,
                 .invalidTimestamp:
                return .corruptJournal
            case .externalDocumentConflict:
                return .externalDocumentConflict
            case .invalidTransaction:
                return .writeFailed("workspace_save_transaction_invalid")
            }
        }
    }

    static func prepare(
        coreService: AgentryCoreService = .shared
    ) async throws -> PreparedValidator {
        try Task.checkCancellation()
        do {
            let client = try await coreService.computeClient()
            let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
            try Task.checkCancellation()
            return PreparedValidator(core: prepared)
        } catch is CancellationError {
            throw DomainPersistenceError.cancelled
        } catch {
            throw DomainPersistenceError.writeFailed("working_journal_rust_unavailable")
        }
    }

    static func validate(
        _ bytes: Data,
        expectedWorkspaceID: UUID? = nil,
        expectedFileURL: URL? = nil,
        coreService: AgentryCoreService = .shared
    ) async throws -> DomainWorkspaceWorkingJournalValidation {
        let prepared = try await prepare(coreService: coreService)
        do {
            return try await Task.detached(priority: nil) {
                try prepared.validateSynchronously(
                    bytes,
                    expectedWorkspaceID: expectedWorkspaceID,
                    expectedFileURL: expectedFileURL
                )
            }.value
        } catch is CancellationError {
            throw DomainPersistenceError.cancelled
        }
    }
}
