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

struct DomainWorkspaceCommandAdmissionRecoveryReceipt: Sendable, Equatable {
    let catalogRevision: UInt64
    let catalogDigest: String
    let targetWorkspaceID: UUID?
    let diagnostics: DomainWorkspaceCommandAdmissionDiagnostics
}

enum DomainWorkspaceRecoveryArtifactEvidence: Sendable, Equatable {
    case absent
    case present(Data)
    case unavailable(reason: String)
}

struct DomainWorkspaceSemanticRecoveryEvidence: Sendable, Equatable {
    let workspaceID: UUID
    let journal: DomainWorkspaceRecoveryArtifactEvidence
    let savedDocument: DomainWorkspaceRecoveryArtifactEvidence
    let savedRevision: DomainWorkspaceRecoveryArtifactEvidence
}

struct DomainWorkspaceSemanticDeletionRecoveryEvidence: Sendable, Equatable {
    let workspaceID: UUID
    let sidecar: DomainWorkspaceRecoveryArtifactEvidence
}

struct DomainWorkspaceSemanticFullRecovery: Sendable, Equatable {
    let catalogBytes: Data
    let catalogRevision: UInt64
    let catalogDigest: String
    let workspaces: [DomainWorkspaceSemanticRecoveryEvidence]
    let deletions: [DomainWorkspaceSemanticDeletionRecoveryEvidence]
}

struct DomainWorkspaceSemanticTargetRecovery: Sendable, Equatable {
    let catalogBytes: Data
    let catalogRevision: UInt64
    let catalogDigest: String
    let workspaceID: UUID
    let journal: DomainWorkspaceRecoveryArtifactEvidence
    let savedDocument: DomainWorkspaceRecoveryArtifactEvidence
    let savedRevision: DomainWorkspaceRecoveryArtifactEvidence
    let deletionSidecar: DomainWorkspaceRecoveryArtifactEvidence
}

enum DomainWorkspaceSemanticRecoveryAdmissionDisposition: Sendable, Equatable {
    case installed
    case preserved
    case quarantined
}

struct DomainWorkspaceSemanticActiveRecovery: Sendable, Equatable {
    let document: DomainWorkspaceDocument
    let savedDigest: String
    let revisions: DomainRevisionState
    let contextRevisions: [UUID: DomainRevisionState]
    let contextTombstones: [UUID: UInt64]
    let operations: [DomainRecordedOperation]
    let health: DomainAuthorityHealth
    let externalDocument: DomainWorkspaceDocument?
}

struct DomainWorkspaceSemanticUnavailableRecovery: Sendable, Equatable {
    let workspaceID: UUID
    let fileURL: URL
    let reason: String
}

enum DomainWorkspaceSemanticRecoveryRow: Sendable, Equatable {
    case active(DomainWorkspaceSemanticActiveRecovery)
    case unavailable(DomainWorkspaceSemanticUnavailableRecovery)
    case deleted(workspaceID: UUID, fileURL: URL)
}

enum DomainWorkspaceSemanticTargetDirective: Sendable, Equatable {
    case upsert(DomainWorkspaceSemanticActiveRecovery)
    case unavailable(DomainWorkspaceSemanticUnavailableRecovery)
    case delete(workspaceID: UUID, fileURL: URL)
    case noChange
}

enum DomainWorkspaceSemanticRecoveryProjection: Sendable, Equatable {
    case full(rows: [DomainWorkspaceSemanticRecoveryRow])
    case target(directive: DomainWorkspaceSemanticTargetDirective)
}

struct DomainWorkspaceSemanticJournalRewrite: Sendable, Equatable {
    let workspaceID: UUID
    let expectedArtifactDigest: String
    let replacementCanonicalBytes: Data
    let replacementCanonicalDigest: String
}

struct DomainWorkspaceSemanticRecoveryPreview: Sendable, Equatable {
    let catalogRevision: UInt64
    let catalogDigest: String
    let targetWorkspaceID: UUID?
    let globalHealth: DomainAuthorityHealth
    let admissionDisposition: DomainWorkspaceSemanticRecoveryAdmissionDisposition
    let projection: DomainWorkspaceSemanticRecoveryProjection
    let journalRewrites: [DomainWorkspaceSemanticJournalRewrite]
    let projectionDigest: String
}

struct DomainWorkspaceSemanticRecoveryCommit: Sendable {
    let admission: DomainWorkspaceRustJournal.PreparedCommandAdmission?
    let admissionReceipt: DomainWorkspaceCommandAdmissionRecoveryReceipt?
    let catalogRevision: UInt64
    let catalogDigest: String
    let targetWorkspaceID: UUID?
    let admissionDisposition: DomainWorkspaceSemanticRecoveryAdmissionDisposition
    let projectionDigest: String
}

enum DomainWorkspaceCommandAdmissionLookupScope: Sendable, Equatable {
    case workspace
    case global
}

enum DomainWorkspaceCommandAdmissionAcquisition: Sendable {
    case claimed(fingerprint: String, claim: DomainWorkspaceRustJournal.PreparedExecutionClaim)
    case pending(fingerprint: String, generation: UInt64)
    case collision(fingerprint: String, scope: DomainWorkspaceCommandAdmissionLookupScope?)
    case replay(
        fingerprint: String,
        scope: DomainWorkspaceCommandAdmissionLookupScope,
        operation: DomainRecordedOperation
    )
}

enum DomainWorkspaceCommandLifecycleDirective: Sendable, Equatable {
    case continueExecution
    case cancelled
    case deadlineExceeded
    case shutdownRequested
}

enum DomainWorkspaceCommandLifecycleFinalizationError: Error, Sendable, Equatable {
    case cancelled
    case deadlineExceeded
    case shuttingDown
}

enum DomainWorkspaceCommandAdmissionError: Error, Sendable, Equatable {
    case invalidInput
    case invalidReceipt
    case capacityExceeded
    case deadlineExceeded
    case shuttingDown
    case unavailable
}

struct DomainWorkspaceCommandAdmissionDiagnostics: Sendable, Equatable {
    let globalOperationCount: UInt64
    let workspaceCount: UInt64
    let workspaceOperationCount: UInt64
}

enum DomainWorkspaceCommandFinalization: Sendable, Equatable {
    case notApplicable
    case reconciled
    case unreconciled
}

enum DomainWorkspaceCommandResultDisposition: Sendable, Equatable {
    case applied
    case unchanged
    case deleted
}

struct DomainWorkspaceCommandResult: Sendable, Equatable {
    let workspaceID: UUID
    let operation: DomainRecordedOperation
    let disposition: DomainWorkspaceCommandResultDisposition
    let before: DomainRevisionState?
    let after: DomainRevisionState?
    let resultingDigest: String?
    let catalogRevision: UInt64
    let publicationKind: DomainWorkspaceEventKind
    let contextID: UUID?
}

struct DomainWorkspaceCommandAuthorityFinalization: Sendable, Equatable {
    let commandFinalization: DomainWorkspaceCommandFinalization
    let commandResult: DomainWorkspaceCommandResult?
    let authorityPublication: DomainWorkspaceAuthorityPublicationReceipt?
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

struct DomainWorkspaceDeleteCleanupFinalization: Sendable {
    let tombstone: DomainWorkspaceDeletionTombstoneValidation?
    let authorityFinalization: DomainWorkspaceCommandAuthorityFinalization
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
    let commandResult: DomainWorkspaceCommandResult?
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
    let commandResult: DomainWorkspaceCommandResult?
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
    let commandResult: DomainWorkspaceCommandResult?
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
    let commandResult: DomainWorkspaceCommandResult?
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
        operationID: UUID,
        fingerprint: String,
        updatedAt: Date
    )
    case unchanged(
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        fingerprint: String,
        updatedAt: Date
    )
    case working(
        expectedWorkingRevision: UInt64,
        operationID: UUID?,
        fingerprint: String?,
        updatedAt: Date
    )
    case save(
        expectedWorkingRevision: UInt64,
        operationID: UUID,
        fingerprint: String,
        updatedAt: Date
    )
    case externalReload(
        expectedWorkingRevision: UInt64,
        operationID: UUID?,
        fingerprint: String?,
        updatedAt: Date
    )
    case conflictRebase(
        expectedRevisions: DomainRevisionState,
        externalSavedDigest: String,
        operationID: UUID?,
        fingerprint: String?,
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
        case let .create(workspaceID, fileURL, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "create",
                workspaceID: workspaceID,
                fileURL: fileURL,
                operationID: operationID,
                fingerprint: fingerprint,
                updatedAt: updatedAt
            )
        case let .unchanged(expectedWorkingRevision, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "unchanged",
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                fingerprint: fingerprint,
                updatedAt: updatedAt
            )
        case let .working(expectedWorkingRevision, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "working",
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                fingerprint: fingerprint,
                updatedAt: updatedAt
            )
        case let .save(expectedWorkingRevision, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "save",
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                fingerprint: fingerprint,
                updatedAt: updatedAt
            )
        case let .externalReload(expectedWorkingRevision, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "externalReload",
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID,
                fingerprint: fingerprint,
                updatedAt: updatedAt
            )
        case let .conflictRebase(expectedRevisions, externalSavedDigest, operationID, fingerprint, updatedAt):
            EncodedTransition(
                kind: "conflictRebase",
                expectedRevisions: expectedRevisions,
                externalSavedDigest: externalSavedDigest,
                operationID: operationID,
                fingerprint: fingerprint,
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
        var expectedWorkingRevision: UInt64?
        var savedDigest: String?
        var externalSavedDigest: String?
        var contextDigests: [UUID: String]?
        var operationID: UUID?
        var fingerprint: String?
        var updatedAt: Date?

        init(
            kind: String,
            workspaceID: UUID? = nil,
            fileURL: URL? = nil,
            expectedWorkspaceID: UUID? = nil,
            revisions: DomainRevisionState? = nil,
            expectedRevisions: DomainRevisionState? = nil,
            expectedWorkingRevision: UInt64? = nil,
            savedDigest: String? = nil,
            externalSavedDigest: String? = nil,
            contextDigests: [UUID: String]? = nil,
            operationID: UUID? = nil,
            fingerprint: String? = nil,
            updatedAt: Date? = nil
        ) {
            self.kind = kind
            self.workspaceID = workspaceID
            self.fileURL = fileURL
            self.expectedWorkspaceID = expectedWorkspaceID
            self.revisions = revisions
            self.expectedRevisions = expectedRevisions
            self.expectedWorkingRevision = expectedWorkingRevision
            self.savedDigest = savedDigest
            self.externalSavedDigest = externalSavedDigest
            self.contextDigests = contextDigests
            self.operationID = operationID
            self.fingerprint = fingerprint
            self.updatedAt = updatedAt
        }
    }
}

private extension DomainWorkspaceWorkingJournalTransition {
    var expectedWorkingRevision: UInt64 {
        switch self {
        case let .unchanged(revision, _, _, _),
             let .working(revision, _, _, _),
             let .externalReload(revision, _, _, _):
            revision
        case let .conflictRebase(revisions, _, _, _, _):
            revisions.workingRevision
        case .seed, .recoverPending, .create, .save:
            0
        }
    }

    var resultingWorkingRevision: UInt64 {
        switch self {
        case let .unchanged(revision, _, _, _): revision
        case let .working(revision, _, _, _):
            revision == UInt64.max ? revision : revision + 1
        case let .externalReload(revision, _, _, _):
            revision == UInt64.max ? revision : revision + 1
        case let .conflictRebase(revisions, _, _, _, _):
            revisions.workingRevision
        case .seed, .recoverPending, .create, .save: 0
        }
    }

    var resultingSavedRevision: UInt64? {
        if case let .externalReload(revision, _, _, _) = self {
            return revision == UInt64.max ? revision : revision + 1
        }
        return nil
    }

    func matches(
        journal: DomainWorkingJournal,
        documentDigest: String
    ) -> Bool {
        func contains(_ operationID: UUID?, _ fingerprint: String?) -> Bool {
            guard let operationID else { return true }
            return journal.operations.contains {
                $0.operationID == operationID && (fingerprint == nil || $0.fingerprint == fingerprint)
            }
        }

        switch self {
        case let .unchanged(expectedRevision, operationID, fingerprint, _):
            let effectiveDigest = journal.workingDocument.map(DomainContentDigest.sha256)
                ?? journal.savedDigest
            return journal.revisions.workingRevision == expectedRevision
                && effectiveDigest == documentDigest
                && journal.operations.contains {
                    $0.operationID == operationID
                        && (fingerprint == nil || $0.fingerprint == fingerprint)
                        && $0.resultingDigest == documentDigest
                }
        case let .working(_, operationID, fingerprint, _):
            return journal.revisions.workingRevision == resultingWorkingRevision
                && journal.revisions.dirtyRevision == resultingWorkingRevision
                && journal.workingDocument.map(DomainContentDigest.sha256) == documentDigest
                && contains(operationID, fingerprint)
        case let .externalReload(_, operationID, fingerprint, _):
            return journal.revisions.workingRevision == resultingWorkingRevision
                && journal.revisions.savedRevision == journal.revisions.workingRevision
                && journal.revisions.dirtyRevision == nil
                && journal.savedDigest == documentDigest
                && journal.workingDocument == nil
                && contains(operationID, fingerprint)
        case let .conflictRebase(expectedRevisions, externalSavedDigest, operationID, fingerprint, _):
            return (journal.revisions.workingRevision == expectedRevisions.workingRevision
                || journal.revisions.workingRevision == expectedRevisions.workingRevision + 1)
                && journal.savedDigest == externalSavedDigest
                && contains(operationID, fingerprint)
        case .seed, .recoverPending, .create, .save:
            return false
        }
    }
}

/// P5-5 prepared Rust journal authority bound to one exact live runtime identity.
enum DomainWorkspaceRustJournal {
    private struct CreateTransactionRequest: Encodable {
        let kind: String
        let semanticPlannerVersion: UInt16?
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedCatalogRevision: UInt64
        let operationID: UUID?
        let fingerprint: String?
        let updatedAt: Date
    }

    private struct DeleteTransactionRequest: Encodable {
        let semanticPlannerVersion: UInt16
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedWorkingRevision: UInt64
        let expectedCatalogRevision: UInt64
        let operationID: UUID
        let fingerprint: String
        let deletedAt: Date
    }

    private struct JournalMutationTransactionRequest: Encodable {
        let semanticPlannerVersion: UInt16
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let catalogRevision: UInt64
        let revisionOperationID: UUID?
        let recoveryMode: Bool
        let transition: DomainWorkspaceWorkingJournalTransition.EncodedTransition
    }

    private struct SaveTransactionRequest: Encodable {
        let semanticPlannerVersion: UInt16
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedWorkingRevision: UInt64
        let operationID: UUID
        let fingerprint: String
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
            do {
                return try core.acquireAuthorityPermit()
            } catch CoreBridgeError.operationCancelled {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.deadlineExpired {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.shutdownRequested {
                throw DomainPersistenceError.runtimeShutdownRequested
            }
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

        func finishCommandAuthority() -> DomainWorkspaceCommandAuthorityFinalization {
            DomainWorkspaceRustJournal.commandAuthorityFinalization(core.finishCommandAuthority())
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
        private let isRecovery: Bool

        fileprivate init(
            core: CoreWorkspaceJournalMutationTransactionV1,
            validator: PreparedValidator,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedTransition: DomainWorkspaceWorkingJournalTransition,
            expectedCatalogRevision: UInt64,
            expectedDocumentDigest: String,
            revisionOperationID: UUID?,
            expectedUpdatedAt: Date,
            isRecovery: Bool
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
            self.isRecovery = isRecovery
        }

        func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
            do {
                return try core.acquireAuthorityPermit()
            } catch CoreBridgeError.operationCancelled {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.deadlineExpired {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.shutdownRequested {
                throw DomainPersistenceError.runtimeShutdownRequested
            }
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
                expectedUpdatedAt: expectedUpdatedAt,
                isRecovery: isRecovery
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
                expectedUpdatedAt: expectedUpdatedAt,
                isRecovery: isRecovery
            )
        }

        func finishCommandAuthority() -> DomainWorkspaceCommandAuthorityFinalization {
            DomainWorkspaceRustJournal.commandAuthorityFinalization(core.finishCommandAuthority())
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

        func acquireAuthorityPermit() throws -> CoreWorkspaceCreateAuthorityPermitV1 {
            do {
                return try core.acquireAuthorityPermit()
            } catch CoreBridgeError.operationCancelled {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.deadlineExpired {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.shutdownRequested {
                throw DomainPersistenceError.runtimeShutdownRequested
            }
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

        func finishCommandAuthority() -> DomainWorkspaceCommandAuthorityFinalization {
            DomainWorkspaceRustJournal.commandAuthorityFinalization(core.finishCommandAuthority())
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
            do {
                return try core.acquireAuthorityPermit()
            } catch CoreBridgeError.operationCancelled {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.deadlineExpired {
                throw DomainPersistenceError.cancelled
            } catch CoreBridgeError.shutdownRequested {
                throw DomainPersistenceError.runtimeShutdownRequested
            }
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

        func planCleanup(
            cleanupWarnings: [String]
        ) throws -> DomainWorkspaceDeletionTombstoneValidation {
            let validated = try core.planCleanup(
                cleanupWarningsBytes: validator.cleanupWarningsBytes(cleanupWarnings)
            )
            return try validator.materializeDeletionTombstoneCleanup(
                validated,
                expectedWorkspaceID: expectedWorkspaceID,
                expectedFileURL: expectedFileURL,
                expectedOperation: expectedOperation,
                expectedDeletedAt: expectedDeletedAt,
                cleanupWarnings: cleanupWarnings
            )
        }

        func finishCommandAuthority(
            cleanupWarnings: [String]?
        ) -> DomainWorkspaceDeleteCleanupFinalization {
            let normalizedWarnings = cleanupWarnings.flatMap { $0.isEmpty ? nil : $0 }
            let cleanupWarningsBytes: Data?
            do {
                cleanupWarningsBytes = try normalizedWarnings.map(validator.cleanupWarningsBytes)
            } catch {
                return DomainWorkspaceDeleteCleanupFinalization(
                    tombstone: nil,
                    authorityFinalization: .init(
                        commandFinalization: .unreconciled,
                        commandResult: nil,
                        authorityPublication: nil
                    )
                )
            }
            let finalized = core.finishCommandAuthority(
                cleanupWarningsBytes: cleanupWarningsBytes
            )
            let authorityFinalization = DomainWorkspaceRustJournal.commandAuthorityFinalization(
                finalized.authorityFinalization
            )
            guard let tombstone = finalized.tombstone,
                  let materialized = try? validator.materializeDeletionTombstoneCleanup(
                      tombstone,
                      expectedWorkspaceID: expectedWorkspaceID,
                      expectedFileURL: expectedFileURL,
                      expectedOperation: expectedOperation,
                      expectedDeletedAt: expectedDeletedAt,
                      cleanupWarnings: normalizedWarnings
                  )
            else {
                return DomainWorkspaceDeleteCleanupFinalization(
                    tombstone: nil,
                    authorityFinalization: .init(
                        commandFinalization: .unreconciled,
                        commandResult: nil,
                        authorityPublication: nil
                    )
                )
            }
            return DomainWorkspaceDeleteCleanupFinalization(
                tombstone: materialized,
                authorityFinalization: authorityFinalization
            )
        }

        func close() {
            core.close()
        }
    }

    struct PreparedExecutionClaim: Sendable {
        private let core: CoreWorkspaceCommandExecutionClaimV1
        private let validator: PreparedValidator

        fileprivate init(
            core: CoreWorkspaceCommandExecutionClaimV1,
            validator: PreparedValidator
        ) {
            self.core = core
            self.validator = validator
        }

        fileprivate var transactionBinding: CoreWorkspaceCommandExecutionClaimV1 {
            core
        }

        func checkpoint() throws -> DomainWorkspaceCommandLifecycleDirective {
            do {
                return switch try core.checkpoint() {
                case .continueExecution: .continueExecution
                case .cancelled: .cancelled
                case .deadlineExceeded: .deadlineExceeded
                case .shutdownRequested: .shutdownRequested
                }
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func finalizeTransient(
            operation: DomainRecordedOperation
        ) throws -> DomainRecordedOperation {
            do {
                let finalized = try core.finalizeTransient(
                    operation: validator.coreRecordedOperation(operation)
                )
                let materialized = try validator.materializeRecordedOperation(finalized)
                guard materialized == operation else {
                    throw DomainWorkspaceCommandAdmissionError.invalidReceipt
                }
                return materialized
            } catch let error as DomainWorkspaceCommandAdmissionError {
                throw error
            } catch CoreBridgeError.operationCancelled {
                throw DomainWorkspaceCommandLifecycleFinalizationError.cancelled
            } catch CoreBridgeError.deadlineExpired {
                throw DomainWorkspaceCommandLifecycleFinalizationError.deadlineExceeded
            } catch CoreBridgeError.runtimeStopped {
                throw DomainWorkspaceCommandLifecycleFinalizationError.shuttingDown
            } catch CoreBridgeError.shutdownRequested {
                throw DomainWorkspaceCommandLifecycleFinalizationError.shuttingDown
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        @discardableResult
        func abandon() throws -> Bool {
            do {
                return try core.abandon()
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func close() {
            core.close()
        }
    }

    struct PreparedSemanticRecovery: Sendable {
        private let core: CorePreparedWorkspaceSemanticRecoveryV1
        private let validator: PreparedValidator

        fileprivate init(
            core: CorePreparedWorkspaceSemanticRecoveryV1,
            validator: PreparedValidator
        ) {
            self.core = core
            self.validator = validator
        }

        func preview() throws -> DomainWorkspaceSemanticRecoveryPreview {
            do {
                return try validator.materializeSemanticRecoveryPreview(core.preview())
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func commit(
            expected preview: DomainWorkspaceSemanticRecoveryPreview
        ) throws -> DomainWorkspaceSemanticRecoveryCommit {
            do {
                let commit = try core.commit()
                guard commit.catalogRevision == preview.catalogRevision,
                      commit.catalogDigest == preview.catalogDigest,
                      commit.targetWorkspaceID == preview.targetWorkspaceID,
                      validator.materializeSemanticAdmissionDisposition(
                          commit.admissionDisposition
                      ) == preview.admissionDisposition,
                      commit.projectionDigest == preview.projectionDigest
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                let receipt = try commit.admissionReceipt.map {
                    try validator.materializeCommandAdmissionRecoveryReceipt(
                        $0,
                        expectedCatalogRevision: preview.catalogRevision,
                        expectedCatalogDigest: preview.catalogDigest,
                        expectedTargetWorkspaceID: preview.targetWorkspaceID
                    )
                }
                return DomainWorkspaceSemanticRecoveryCommit(
                    admission: commit.admission.map {
                        PreparedCommandAdmission(core: $0, validator: validator)
                    },
                    admissionReceipt: receipt,
                    catalogRevision: commit.catalogRevision,
                    catalogDigest: commit.catalogDigest,
                    targetWorkspaceID: commit.targetWorkspaceID,
                    admissionDisposition: preview.admissionDisposition,
                    projectionDigest: commit.projectionDigest
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

        func acquire(
            _ input: DomainWorkspaceCommandIdentityInput,
            deadlineUnixMilliseconds: UInt64? = nil
        ) throws -> DomainWorkspaceCommandAdmissionAcquisition {
            let request = validator.coreCommandIdentityRequest(input)
            do {
                switch try core.acquire(
                    request,
                    deadlineUnixMilliseconds: deadlineUnixMilliseconds
                ) {
                case let .claimed(identity, claim, _):
                    try validator.validateCommandAdmissionIdentity(identity, request: request)
                    return .claimed(
                        fingerprint: identity.fingerprint,
                        claim: PreparedExecutionClaim(core: claim, validator: validator)
                    )
                case let .pending(identity, generation):
                    try validator.validateCommandAdmissionIdentity(identity, request: request)
                    return .pending(fingerprint: identity.fingerprint, generation: generation)
                case let .collision(identity, scope):
                    try validator.validateCommandAdmissionIdentity(identity, request: request)
                    return .collision(
                        fingerprint: identity.fingerprint,
                        scope: scope.map(validator.materializeCommandAdmissionScope)
                    )
                case let .replay(identity, scope, operation):
                    try validator.validateCommandAdmissionIdentity(identity, request: request)
                    let recorded = try validator.materializeRecordedOperation(operation)
                    guard recorded.operationID == input.operationID,
                          recorded.fingerprint == identity.fingerprint
                    else {
                        throw DomainWorkspaceCommandAdmissionError.invalidReceipt
                    }
                    return .replay(
                        fingerprint: identity.fingerprint,
                        scope: validator.materializeCommandAdmissionScope(scope),
                        operation: recorded
                    )
                }
            } catch let error as DomainWorkspaceCommandAdmissionError {
                throw error
            } catch CoreBridgeError.queueLimitExceeded {
                throw DomainWorkspaceCommandAdmissionError.capacityExceeded
            } catch CoreBridgeError.deadlineExpired {
                throw DomainWorkspaceCommandAdmissionError.deadlineExceeded
            } catch CoreBridgeError.runtimeStopped {
                throw DomainWorkspaceCommandAdmissionError.shuttingDown
            } catch let error as CoreWorkspaceWorkingJournalValidationError {
                switch error {
                case .inputTooLarge,
                     .invalidIdentity,
                     .invalidFileURL,
                     .invalidDigest:
                    throw DomainWorkspaceCommandAdmissionError.invalidInput
                default:
                    throw DomainWorkspaceCommandAdmissionError.unavailable
                }
            } catch {
                throw DomainWorkspaceCommandAdmissionError.unavailable
            }
        }

        @discardableResult
        func cancel(operationID: UUID) throws -> CoreCancellation {
            do {
                return try core.cancel(OperationID(
                    rawValue: operationID.uuidString.lowercased()
                ))
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func prepareSemanticFullRecovery(
            _ recovery: DomainWorkspaceSemanticFullRecovery
        ) throws -> PreparedSemanticRecovery {
            do {
                return PreparedSemanticRecovery(
                    core: try core.prepareSemanticFullRecovery(
                        validator.coreSemanticFullRecovery(recovery)
                    ),
                    validator: validator
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func prepareSemanticTargetRecovery(
            _ recovery: DomainWorkspaceSemanticTargetRecovery
        ) throws -> PreparedSemanticRecovery {
            do {
                return PreparedSemanticRecovery(
                    core: try core.prepareSemanticTargetRecovery(
                        validator.coreSemanticTargetRecovery(recovery)
                    ),
                    validator: validator
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func synchronizeAuthorityProjection(
            workspaces: [DomainWorkspaceSnapshot]
        ) throws -> DomainWorkspaceAuthorityProjectionSyncReceipt {
            do {
                let receipt = try core.synchronizeAuthorityProjection(
                    workspaces: workspaces.map(DomainWorkspaceRustProjection.corePublishedWorkspace)
                )
                return DomainWorkspaceAuthorityProjectionSyncReceipt(
                    previousGeneration: receipt.previousGeneration,
                    generation: receipt.generation,
                    projectionChanged: receipt.projectionChanged,
                    workspaceCount: receipt.workspaceCount,
                    retainedBytes: receipt.retainedBytes,
                    catalogRevision: receipt.catalogRevision,
                    publicationSequence: receipt.publicationSequence,
                    projectionDigest: receipt.projectionDigest
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func publishAuthorityState(
            workspaces: [DomainWorkspaceSnapshot],
            catalogRevision: UInt64,
            kind: DomainWorkspaceEventKind,
            workspaceID: UUID?,
            contextID: UUID?,
            operationID: UUID?,
            revisions: DomainRevisionState?
        ) throws -> DomainWorkspaceAuthorityPublicationReceipt {
            do {
                let receipt = try core.publishAuthorityState(
                    workspaces: workspaces.map(DomainWorkspaceRustProjection.corePublishedWorkspace),
                    draft: CoreWorkspaceAuthorityPublicationDraft(
                        catalogRevision: catalogRevision,
                        kind: DomainWorkspaceRustProjection.corePublicationKind(kind),
                        workspaceID: workspaceID,
                        contextID: contextID,
                        operationID: operationID,
                        revisions: revisions.map(DomainWorkspaceRustProjection.coreRevisionState)
                    )
                )
                return DomainWorkspaceAuthorityPublicationReceipt(
                    event: DomainWorkspaceAuthorityPublicationEvent(
                        sequence: receipt.event.sequence,
                        catalogRevision: receipt.event.catalogRevision,
                        kind: DomainWorkspaceRustProjection.domainPublicationKind(receipt.event.kind),
                        workspaceID: receipt.event.workspaceID,
                        contextID: receipt.event.contextID,
                        operationID: receipt.event.operationID,
                        revisions: receipt.event.revisions.map(DomainWorkspaceRustProjection.domainRevisionState)
                    ),
                    previousGeneration: receipt.previousGeneration,
                    generation: receipt.generation,
                    projectionChanged: receipt.projectionChanged,
                    workspaceCount: receipt.workspaceCount,
                    retainedBytes: receipt.retainedBytes,
                    previousCatalogRevision: receipt.previousCatalogRevision,
                    previousPublicationSequence: receipt.previousPublicationSequence,
                    catalogRevision: receipt.catalogRevision,
                    publicationSequence: receipt.publicationSequence,
                    eventLogFloorSequence: receipt.eventLogFloorSequence,
                    eventLogCount: receipt.eventLogCount,
                    projectionDigest: receipt.projectionDigest
                )
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
        }

        func authorityRead(
            workspaceID: UUID
        ) throws -> DomainWorkspaceAuthoritativeProjectionRead {
            do {
                let read = try core.authorityRead(workspaceID: workspaceID)
                return DomainWorkspaceAuthoritativeProjectionRead(
                    projection: read.projection.map(DomainWorkspaceRustProjection.domainProjection),
                    authority: read.projection?.authority.map(DomainWorkspaceRustProjection.domainAuthorityState),
                    contentDigest: read.contentDigest,
                    generation: read.generation,
                    catalogRevision: read.catalogRevision,
                    publicationSequence: read.publicationSequence,
                    eventLogFloorSequence: read.eventLogFloorSequence,
                    eventLogCount: read.eventLogCount,
                    projectionDigest: read.projectionDigest
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

        func prepareInitialSemanticRecovery(
            _ recovery: DomainWorkspaceSemanticFullRecovery
        ) throws -> PreparedSemanticRecovery {
            do {
                return PreparedSemanticRecovery(
                    core: try core.prepareInitialSemanticRecovery(
                        coreSemanticFullRecovery(recovery)
                    ),
                    validator: self
                )
            } catch {
                throw map(error)
            }
        }

        fileprivate func coreSemanticFullRecovery(
            _ recovery: DomainWorkspaceSemanticFullRecovery
        ) -> CoreWorkspaceSemanticFullRecoveryV1 {
            .init(
                catalogBytes: recovery.catalogBytes,
                workspaces: recovery.workspaces.map {
                    .init(
                        workspaceID: $0.workspaceID,
                        journal: coreRecoveryArtifactEvidence($0.journal),
                        savedDocument: coreRecoveryArtifactEvidence($0.savedDocument),
                        savedRevision: coreRecoveryArtifactEvidence($0.savedRevision)
                    )
                },
                deletions: recovery.deletions.map {
                    .init(
                        workspaceID: $0.workspaceID,
                        sidecar: coreRecoveryArtifactEvidence($0.sidecar)
                    )
                }
            )
        }

        fileprivate func coreSemanticTargetRecovery(
            _ recovery: DomainWorkspaceSemanticTargetRecovery
        ) -> CoreWorkspaceSemanticTargetRecoveryV1 {
            .init(
                catalogBytes: recovery.catalogBytes,
                workspaceID: recovery.workspaceID,
                journal: coreRecoveryArtifactEvidence(recovery.journal),
                savedDocument: coreRecoveryArtifactEvidence(recovery.savedDocument),
                savedRevision: coreRecoveryArtifactEvidence(recovery.savedRevision),
                deletionSidecar: coreRecoveryArtifactEvidence(recovery.deletionSidecar)
            )
        }

        private func coreRecoveryArtifactEvidence(
            _ evidence: DomainWorkspaceRecoveryArtifactEvidence
        ) -> CoreWorkspaceRecoveryArtifactEvidenceV1 {
            switch evidence {
            case .absent:
                .absent
            case let .present(bytes):
                .present(bytes)
            case let .unavailable(reason):
                .unavailable(reason: reason)
            }
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

        fileprivate func validateCommandAdmissionIdentity(
            _ identity: CoreWorkspaceCommandIdentityV1,
            request: CoreWorkspaceCommandIdentityRequestV1
        ) throws {
            guard identity.workspaceID == request.workspaceID,
                  identity.commandKind == request.commandKind,
                  Self.isSHA256Digest(identity.fingerprint)
            else {
                throw DomainWorkspaceCommandAdmissionError.invalidReceipt
            }
        }

        fileprivate func materializeCommandAdmissionScope(
            _ scope: CoreWorkspaceCommandAdmissionLookupScopeV1
        ) -> DomainWorkspaceCommandAdmissionLookupScope {
            switch scope {
            case .workspace: .workspace
            case .global: .global
            }
        }

        fileprivate func materializeRecordedOperation(
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

        fileprivate func materializeSemanticRecoveryPreview(
            _ preview: CoreWorkspaceSemanticRecoveryPreviewV1
        ) throws -> DomainWorkspaceSemanticRecoveryPreview {
            let projection: DomainWorkspaceSemanticRecoveryProjection = switch preview.projection {
            case let .full(rows):
                .full(rows: try rows.map(materializeSemanticRecoveryRow))
            case let .target(directive):
                .target(directive: try materializeSemanticTargetDirective(directive))
            }
            return DomainWorkspaceSemanticRecoveryPreview(
                catalogRevision: preview.catalogRevision,
                catalogDigest: preview.catalogDigest,
                targetWorkspaceID: preview.targetWorkspaceID,
                globalHealth: materializeSemanticHealth(preview.globalHealth),
                admissionDisposition: materializeSemanticAdmissionDisposition(
                    preview.admissionDisposition
                ),
                projection: projection,
                journalRewrites: preview.journalRewrites.map {
                    DomainWorkspaceSemanticJournalRewrite(
                        workspaceID: $0.workspaceID,
                        expectedArtifactDigest: $0.expectedArtifactDigest,
                        replacementCanonicalBytes: $0.replacementCanonicalBytes,
                        replacementCanonicalDigest: $0.replacementCanonicalDigest
                    )
                },
                projectionDigest: preview.projectionDigest
            )
        }

        private func materializeSemanticRecoveryRow(
            _ row: CoreWorkspaceSemanticRecoveryRowV1
        ) throws -> DomainWorkspaceSemanticRecoveryRow {
            switch row {
            case let .active(active):
                .active(try materializeSemanticActiveRecovery(active))
            case let .unavailable(unavailable):
                .unavailable(materializeSemanticUnavailableRecovery(unavailable))
            case let .deleted(workspaceID, fileURL):
                .deleted(workspaceID: workspaceID, fileURL: fileURL)
            }
        }

        private func materializeSemanticTargetDirective(
            _ directive: CoreWorkspaceSemanticTargetDirectiveV1
        ) throws -> DomainWorkspaceSemanticTargetDirective {
            switch directive {
            case let .upsert(active):
                .upsert(try materializeSemanticActiveRecovery(active))
            case let .unavailable(unavailable):
                .unavailable(materializeSemanticUnavailableRecovery(unavailable))
            case let .delete(workspaceID, fileURL):
                .delete(workspaceID: workspaceID, fileURL: fileURL)
            case .noChange:
                .noChange
            }
        }

        private func materializeSemanticActiveRecovery(
            _ active: CoreWorkspaceSemanticActiveRecoveryV1
        ) throws -> DomainWorkspaceSemanticActiveRecovery {
            let document = try DomainWorkspaceDocument.decode(
                documentBytes: active.documentBytes,
                fileURL: active.fileURL
            )
            guard document.workspaceID == active.workspaceID,
                  document.contentDigest == active.documentDigest
            else {
                throw DomainPersistenceError.corruptJournal
            }
            let externalDocument = try active.externalDocumentBytes.map { bytes in
                let external = try DomainWorkspaceDocument.decode(
                    documentBytes: bytes,
                    fileURL: active.fileURL
                )
                guard external.workspaceID == active.workspaceID else {
                    throw DomainPersistenceError.corruptJournal
                }
                return external
            }
            return DomainWorkspaceSemanticActiveRecovery(
                document: document,
                savedDigest: active.savedDigest,
                revisions: domainRevisionState(active.revisions),
                contextRevisions: Dictionary(uniqueKeysWithValues: active.contextRevisions.map {
                    ($0.contextID, domainRevisionState($0.revisions))
                }),
                contextTombstones: active.contextTombstones,
                operations: try active.operations.map(materializeRecordedOperation),
                health: materializeSemanticHealth(active.health),
                externalDocument: externalDocument
            )
        }

        private func materializeSemanticUnavailableRecovery(
            _ unavailable: CoreWorkspaceSemanticUnavailableRecoveryV1
        ) -> DomainWorkspaceSemanticUnavailableRecovery {
            DomainWorkspaceSemanticUnavailableRecovery(
                workspaceID: unavailable.workspaceID,
                fileURL: unavailable.fileURL,
                reason: unavailable.reason
            )
        }

        fileprivate func materializeSemanticAdmissionDisposition(
            _ disposition: CoreWorkspaceSemanticRecoveryAdmissionDispositionV1
        ) -> DomainWorkspaceSemanticRecoveryAdmissionDisposition {
            switch disposition {
            case .installed: .installed
            case .preserved: .preserved
            case .quarantined: .quarantined
            }
        }

        private func materializeSemanticHealth(
            _ health: CoreWorkspaceProjectionHealth
        ) -> DomainAuthorityHealth {
            switch health.kind {
            case .writable:
                .writable
            case .externalConflict:
                .externalConflict(reason: health.reason ?? "external_workspace_changed")
            case .degradedReadOnly:
                .degradedReadOnly(reason: health.reason ?? "workspace_recovery_failed")
            case .removed:
                .removed
            }
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

        fileprivate func materializeCommandAdmissionRecoveryReceipt(
            _ receipt: CoreWorkspaceCommandAdmissionRecoveryReceiptV1,
            expectedCatalogRevision: UInt64,
            expectedCatalogDigest: String,
            expectedTargetWorkspaceID: UUID?
        ) throws -> DomainWorkspaceCommandAdmissionRecoveryReceipt {
            guard receipt.catalogRevision == expectedCatalogRevision,
                  receipt.catalogDigest == expectedCatalogDigest,
                  Self.isSHA256Digest(receipt.catalogDigest),
                  receipt.targetWorkspaceID == expectedTargetWorkspaceID
            else {
                throw DomainPersistenceError.corruptJournal
            }
            return DomainWorkspaceCommandAdmissionRecoveryReceipt(
                catalogRevision: receipt.catalogRevision,
                catalogDigest: receipt.catalogDigest,
                targetWorkspaceID: receipt.targetWorkspaceID,
                diagnostics: materializeCommandAdmissionDiagnostics(receipt.diagnostics)
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

        fileprivate func cleanupWarningsBytes(_ cleanupWarnings: [String]) throws -> Data {
            try encode(cleanupWarnings)
        }

        fileprivate func materializeDeletionTombstoneCleanup(
            _ validated: CoreWorkspacePersistenceMetadataValidationV1,
            expectedWorkspaceID: UUID,
            expectedFileURL: URL,
            expectedOperation: DomainRecordedOperation,
            expectedDeletedAt: Date,
            cleanupWarnings: [String]?
        ) throws -> DomainWorkspaceDeletionTombstoneValidation {
            do {
                guard validated.workspaceID == expectedWorkspaceID,
                      validated.operationID == expectedOperation.operationID,
                      validated.schemaVersion == UInt16(DomainDeletionTombstone.schemaVersion),
                      DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                let tombstone = try JSONDecoder().decode(
                    DomainDeletionTombstone.self,
                    from: validated.canonicalBytes
                )
                let expectedDiagnostic = cleanupWarnings.map {
                    "artifact_cleanup_incomplete: \($0.joined(separator: "; "))"
                } ?? expectedOperation.diagnostic
                let operation = tombstone.operation
                guard tombstone.version == DomainDeletionTombstone.schemaVersion,
                      tombstone.workspaceID == expectedWorkspaceID,
                      tombstone.fileURL == expectedFileURL,
                      tombstone.deletedAt == expectedDeletedAt,
                      operation.operationID == expectedOperation.operationID,
                      operation.fingerprint == expectedOperation.fingerprint,
                      operation.recordedAt == expectedOperation.recordedAt,
                      // Rust derives before/after revisions, catalog revision, and resulting digest
                      // from the authoritative journal/catalog candidate. Swift verifies only the
                      // command facts and terminal cleanup invariants here.
                      operation.disposition == .applied,
                      operation.errorCode == nil,
                      // Rust owns the first-terminal cleanup receipt; a retry may carry different
                      // warnings, so retain its original or canonical cleanup diagnostic form.
                      operation.diagnostic == expectedDiagnostic
                          || operation.diagnostic == expectedOperation.diagnostic
                          || (cleanupWarnings != nil
                              && operation.diagnostic.map {
                                  $0.hasPrefix("artifact_cleanup_incomplete: ")
                                      && $0.count > "artifact_cleanup_incomplete: ".count
                              } == true)
                else {
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
                case .writeFailed("working_journal_rust_unavailable"),
                     .writeFailed("duplicate_workspace_catalog_id"):
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
            operation: DomainRecordedOperation,
            updatedAt: Date,
            commandClaim: PreparedExecutionClaim
        ) throws -> PreparedCreateTransaction {
            try beginCreateTransaction(
                rawCatalogBytes: rawCatalogBytes,
                effectiveCatalog: effectiveCatalog,
                rawJournalBytes: nil,
                effectiveJournal: nil,
                document: document,
                request: CreateTransactionRequest(
                    kind: "create",
                    semanticPlannerVersion: 1,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedCatalogRevision: effectiveCatalog.catalog.revision,
                    operationID: operation.operationID,
                    fingerprint: operation.fingerprint,
                    updatedAt: updatedAt
                ),
                expectedOperation: operation,
                isRecovery: false,
                commandClaim: commandClaim
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
                    semanticPlannerVersion: nil,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedCatalogRevision: effectiveCatalog.catalog.revision,
                    operationID: nil,
                    fingerprint: nil,
                    updatedAt: updatedAt
                ),
                expectedOperation: nil,
                isRecovery: true,
                commandClaim: nil
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
            commandClaim: PreparedExecutionClaim?
        ) throws -> PreparedCreateTransaction {
            do {
                let transaction = try core.beginCreateTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalogBytes: effectiveCatalog.canonicalBytes,
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal?.canonicalBytes,
                    requestBytes: try encode(request),
                    documentBytes: document.documentBytes,
                    commandClaim: commandClaim?.transactionBinding
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
            commandClaim: PreparedExecutionClaim
        ) throws -> PreparedDeleteTransaction {
            do {
                let request = DeleteTransactionRequest(
                    semanticPlannerVersion: 1,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedWorkingRevision: expectedWorkingRevision,
                    expectedCatalogRevision: expectedCatalogRevision,
                    operationID: operation.operationID,
                    fingerprint: operation.fingerprint,
                    deletedAt: deletedAt
                )
                let transaction = try core.beginDeleteTransaction(
                    rawCatalogBytes: rawCatalogBytes,
                    effectiveCatalogBytes: effectiveCatalog.canonicalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    commandClaim: commandClaim.transactionBinding
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
            commandClaim: PreparedExecutionClaim?,
            recoveryMode: Bool
        ) throws -> PreparedJournalMutationTransaction {
            do {
                let request = JournalMutationTransactionRequest(
                    semanticPlannerVersion: 1,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    catalogRevision: catalogRevision,
                    revisionOperationID: revisionOperationID,
                    recoveryMode: recoveryMode,
                    transition: transition.encoded
                )
                let transaction = try core.beginJournalMutationTransaction(
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    candidateDocumentBytes: document.documentBytes,
                    diskDocumentBytes: diskDocumentBytes,
                    commandClaim: commandClaim?.transactionBinding
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
                    expectedUpdatedAt: updatedAt,
                    isRecovery: recoveryMode
                )
            } catch {
                if error as? CoreWorkspaceWorkingJournalValidationError == .invalidRevisionState {
                    let expected: UInt64 = switch transition {
                    case let .unchanged(revision, _, _, _),
                         let .working(revision, _, _, _),
                         let .externalReload(revision, _, _, _):
                        revision
                    case let .conflictRebase(revisions, _, _, _, _):
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
            fingerprint: String,
            updatedAt: Date,
            catalogRevision: UInt64,
            diskDocumentBytes: Data?,
            commandClaim: PreparedExecutionClaim
        ) throws -> PreparedSaveTransaction {
            do {
                let request = SaveTransactionRequest(
                    semanticPlannerVersion: 1,
                    expectedWorkspaceID: document.workspaceID,
                    expectedFileURL: document.fileURL.standardizedFileURL,
                    expectedWorkingRevision: expectedWorkingRevision,
                    operationID: operationID,
                    fingerprint: fingerprint,
                    updatedAt: updatedAt,
                    catalogRevision: catalogRevision
                )
                let transaction = try core.beginSaveTransaction(
                    rawJournalBytes: rawJournalBytes,
                    effectiveJournalBytes: effectiveJournal.canonicalBytes,
                    requestBytes: try encode(request),
                    candidateDocumentBytes: document.documentBytes,
                    diskDocumentBytes: diskDocumentBytes,
                    commandClaim: commandClaim.transactionBinding
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
                        guard journal.journal.operations.contains(where: {
                            $0.operationID == expectedOperation.operationID
                                && $0.fingerprint == expectedOperation.fingerprint
                                && $0.recordedAt == expectedOperation.recordedAt
                        }) else {
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
            let marker = journal.journal.operations.first(where: {
                $0.operationID == receipt.operationID
                    && $0.disposition == .applied
                    && $0.errorCode == nil
                    && $0.diagnostic == nil
            })
            let operationMatches = expectedOperation == nil || marker.map { marker in
                guard let expectedOperation else { return false }
                return marker.fingerprint == expectedOperation.fingerprint
                    && marker.recordedAt == expectedOperation.recordedAt
            } == true
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
                  operationMatches,
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
            let commandResult = try receipt.commandResult.map(
                DomainWorkspaceRustJournal.materializeCommandResult
            )
            if isRecovery {
                guard commandResult == nil else {
                    throw DomainPersistenceError.corruptJournal
                }
            } else {
                guard let commandResult,
                      let expectedOperation,
                      commandResult.workspaceID == expectedWorkspaceID,
                      commandResult.operation.operationID == receipt.operationID,
                      commandResult.operation.fingerprint == expectedOperation.fingerprint,
                      commandResult.operation.recordedAt == expectedOperation.recordedAt,
                      commandResult.catalogRevision == catalog.catalog.revision
                else { throw DomainPersistenceError.corruptJournal }
            }
            return DomainWorkspaceCreateCommitReceipt(
                workspaceID: expectedWorkspaceID,
                operationID: receipt.operationID,
                requestDigest: receipt.requestDigest,
                documentDigest: expectedDocumentDigest,
                catalog: catalog,
                committedJournal: journal,
                savedRevision: savedRevision,
                commandResult: commandResult
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
            guard let commandResult = try receipt.commandResult.map(
                DomainWorkspaceRustJournal.materializeCommandResult
            ) else { throw DomainPersistenceError.corruptJournal }
            guard commandResult.workspaceID == expectedWorkspaceID,
                  commandResult.operation.operationID == expectedOperation.operationID,
                  commandResult.operation.fingerprint == expectedOperation.fingerprint,
                  commandResult.operation.recordedAt == expectedOperation.recordedAt,
                  commandResult.catalogRevision == catalog.catalog.revision,
                  tombstone.workspaceID == expectedWorkspaceID,
                  tombstone.fileURL.standardizedFileURL == expectedFileURL.standardizedFileURL,
                  tombstone.deletedAt == expectedDeletedAt,
                  tombstone.operation.operationID == expectedOperation.operationID,
                  tombstone.operation.fingerprint == expectedOperation.fingerprint,
                  tombstone.operation.recordedAt == expectedOperation.recordedAt,
                  tombstone.operation.disposition == .applied,
                  tombstone.operation.errorCode == nil,
                  tombstone.operation.diagnostic == nil,
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
                ),
                commandResult: commandResult
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
            expectedUpdatedAt: Date,
            isRecovery: Bool
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
                            expectedUpdatedAt: expectedUpdatedAt,
                            isRecovery: isRecovery
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
                            expectedUpdatedAt: expectedUpdatedAt,
                            isRecovery: isRecovery
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
            expectedUpdatedAt: Date,
            isRecovery: Bool
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
            if journal.revisions.workingRevision != receipt.resultingWorkingRevision
                || journal.revisions.savedRevision != receipt.resultingSavedRevision
                || journal.updatedAt != expectedUpdatedAt
                || journal.revisions.workingRevision != expectedTransition.resultingWorkingRevision
            {
                throw DomainPersistenceError.corruptJournal
            }

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
            guard (savedRevision != nil) == (revisionOperationID != nil) else {
                throw DomainPersistenceError.corruptJournal
            }
            guard expectedTransition.matches(
                journal: journal,
                documentDigest: expectedDocumentDigest
            ) else {
                throw DomainPersistenceError.corruptJournal
            }
            let commandResult = try receipt.commandResult.map(
                DomainWorkspaceRustJournal.materializeCommandResult
            )
            if isRecovery {
                guard commandResult == nil else {
                    throw DomainPersistenceError.corruptJournal
                }
            } else {
                guard let commandResult,
                      commandResult.workspaceID == expectedWorkspaceID,
                      commandResult.catalogRevision == expectedCatalogRevision
                else { throw DomainPersistenceError.corruptJournal }
            }
            return DomainWorkspaceJournalMutationCommitReceipt(
                workspaceID: expectedWorkspaceID,
                requestDigest: receipt.requestDigest,
                catalogRevision: expectedCatalogRevision,
                committedJournal: validation,
                savedRevision: savedRevision,
                commandResult: commandResult
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
            guard let commandResult = try receipt.commandResult.map(
                DomainWorkspaceRustJournal.materializeCommandResult
            ) else { throw DomainPersistenceError.corruptJournal }
            guard commandResult.workspaceID == expectedWorkspaceID,
                  commandResult.operation.operationID == expectedOperationID,
                  commandResult.catalogRevision == expectedCatalogRevision
            else { throw DomainPersistenceError.corruptJournal }
            return DomainWorkspaceSaveCommitReceipt(
                workspaceID: expectedWorkspaceID,
                operationID: expectedOperationID,
                requestDigest: receipt.requestDigest,
                catalogRevision: expectedCatalogRevision,
                documentDigest: expectedDocumentDigest,
                committedJournal: journal,
                savedRevision: revision,
                commandResult: commandResult
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
            case .duplicateCatalogIdentity:
                return .writeFailed("duplicate_workspace_catalog_id")
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
            case .staleRecoverySnapshot:
                return .admissionRecoveryStale
            case .fullRecoveryRequired:
                return .admissionFullRecoveryRequired
            case .invalidTransaction:
                return .writeFailed("workspace_save_transaction_invalid")
            }
        }
    }

    static func materializeCommandResult(
        _ value: CoreWorkspaceCommandResultV1
    ) throws -> DomainWorkspaceCommandResult {
        guard value.operation.before == value.before,
              value.operation.after == value.after,
              value.operation.catalogRevision == value.catalogRevision,
              value.operation.resultingDigest == value.resultingDigest,
              value.operation.errorCode == nil,
              value.operation.diagnostic == nil
        else {
            throw DomainPersistenceError.corruptJournal
        }
        let disposition: DomainWorkspaceCommandResultDisposition = switch value.disposition {
        case .applied: .applied
        case .unchanged: .unchanged
        case .deleted: .deleted
        }
        let expectedOperationDisposition: String = switch disposition {
        case .applied, .deleted: "applied"
        case .unchanged: "unchanged"
        }
        guard value.operation.disposition == expectedOperationDisposition,
              let operationDisposition = DomainCommandDisposition(rawValue: value.operation.disposition)
        else {
            throw DomainPersistenceError.corruptJournal
        }
        let operation = DomainRecordedOperation(
            fingerprint: value.operation.fingerprint,
            recordedAt: Date(timeIntervalSinceReferenceDate: value.operation.recordedAt),
            outcome: DomainCommandOutcome(
                operationID: value.operation.operationID,
                disposition: operationDisposition,
                before: value.operation.before.map(DomainWorkspaceRustProjection.domainRevisionState),
                after: value.operation.after.map(DomainWorkspaceRustProjection.domainRevisionState),
                catalogRevision: value.operation.catalogRevision,
                resultingDigest: value.operation.resultingDigest,
                workspace: nil
            )
        )
        return DomainWorkspaceCommandResult(
            workspaceID: value.workspaceID,
            operation: operation,
            disposition: disposition,
            before: value.before.map(DomainWorkspaceRustProjection.domainRevisionState),
            after: value.after.map(DomainWorkspaceRustProjection.domainRevisionState),
            resultingDigest: value.resultingDigest,
            catalogRevision: value.catalogRevision,
            publicationKind: DomainWorkspaceRustProjection.domainPublicationKind(value.publicationKind),
            contextID: value.contextID
        )
    }

    private static func commandAuthorityFinalization(
        _ value: CoreWorkspaceCommandAuthorityFinalizationV1
    ) -> DomainWorkspaceCommandAuthorityFinalization {
        let publication = value.authorityPublication.map(
            DomainWorkspaceRustProjection.authorityPublicationReceipt
        )
        let commandResult: DomainWorkspaceCommandResult?
        do {
            commandResult = try value.commandResult.map(materializeCommandResult)
        } catch {
            return DomainWorkspaceCommandAuthorityFinalization(
                commandFinalization: .unreconciled,
                commandResult: nil,
                authorityPublication: publication
            )
        }
        let commandFinalization = commandFinalization(value.commandFinalization)
        guard commandFinalization == .reconciled
              ? commandResult != nil
              : commandResult == nil
        else {
            return DomainWorkspaceCommandAuthorityFinalization(
                commandFinalization: .unreconciled,
                commandResult: nil,
                authorityPublication: publication
            )
        }
        return DomainWorkspaceCommandAuthorityFinalization(
            commandFinalization: commandFinalization,
            commandResult: commandResult,
            authorityPublication: publication
        )
    }

    private static func commandFinalization(
        _ value: CoreWorkspaceCommandFinalizationV1
    ) -> DomainWorkspaceCommandFinalization {
        switch value {
        case .notApplicable:
            .notApplicable
        case .reconciled:
            .reconciled
        case .unreconciled:
            .unreconciled
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
