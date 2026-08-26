import AgentryCoreBridge
import Foundation

struct DomainWorkspaceWorkingJournalValidation: Sendable {
    let journal: DomainWorkingJournal
    let canonicalBytes: Data
    let contentDigest: String
}

struct DomainWorkspaceWorkingJournalTransitionPlan: Sendable {
    let primary: DomainWorkspaceWorkingJournalValidation
    let committed: DomainWorkspaceWorkingJournalValidation?
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

enum DomainWorkspaceSaveFinalization: Sendable {
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
        authorityReceipt: DomainWorkspaceSaveCommitReceipt
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
    case committed(
        receipt: DomainWorkspaceSaveCommitReceipt,
        finalization: DomainWorkspaceSaveFinalization
    )
    case failed(DomainWorkspaceSaveFailure)
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

enum DomainWorkspaceCatalogTransition: Sendable {
    case seed(
        entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry],
        updatedAt: Date
    )
    case upsert(
        expectedCatalogRevision: UInt64,
        workspaceID: UUID,
        fileURL: URL,
        updatedAt: Date
    )
    case delete(
        expectedCatalogRevision: UInt64,
        tombstone: DomainDeletionTombstone,
        updatedAt: Date
    )
    case recoverCreate(
        expectedCatalogRevision: UInt64,
        workspaceID: UUID,
        fileURL: URL,
        updatedAt: Date
    )

    fileprivate var encoded: EncodedTransition {
        switch self {
        case let .seed(entries, updatedAt):
            EncodedTransition(kind: "seed", entries: entries, updatedAt: updatedAt)
        case let .upsert(expectedCatalogRevision, workspaceID, fileURL, updatedAt):
            EncodedTransition(
                kind: "upsert",
                expectedCatalogRevision: expectedCatalogRevision,
                workspaceID: workspaceID,
                fileURL: fileURL,
                updatedAt: updatedAt
            )
        case let .delete(expectedCatalogRevision, tombstone, updatedAt):
            EncodedTransition(
                kind: "delete",
                expectedCatalogRevision: expectedCatalogRevision,
                tombstone: tombstone,
                updatedAt: updatedAt
            )
        case let .recoverCreate(expectedCatalogRevision, workspaceID, fileURL, updatedAt):
            EncodedTransition(
                kind: "recoverCreate",
                expectedCatalogRevision: expectedCatalogRevision,
                workspaceID: workspaceID,
                fileURL: fileURL,
                updatedAt: updatedAt
            )
        }
    }

    fileprivate struct EncodedTransition: Encodable {
        let kind: String
        var expectedCatalogRevision: UInt64?
        var workspaceID: UUID?
        var fileURL: URL?
        var entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry]?
        var tombstone: DomainDeletionTombstone?
        let updatedAt: Date

        init(
            kind: String,
            expectedCatalogRevision: UInt64? = nil,
            workspaceID: UUID? = nil,
            fileURL: URL? = nil,
            entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry]? = nil,
            tombstone: DomainDeletionTombstone? = nil,
            updatedAt: Date
        ) {
            self.kind = kind
            self.expectedCatalogRevision = expectedCatalogRevision
            self.workspaceID = workspaceID
            self.fileURL = fileURL
            self.entries = entries
            self.tombstone = tombstone
            self.updatedAt = updatedAt
        }
    }
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

    fileprivate var mapsInvalidRevisionToInvalidDocument: Bool {
        if case .conflictRebase = self {
            return true
        }
        return false
    }

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

/// P5-5 prepared Rust journal authority bound to one exact live runtime identity.
enum DomainWorkspaceRustJournal {
    private struct SavedRevisionPlanRequest: Encodable {
        let workspaceID: UUID
        let savedRevision: UInt64
        let documentDigest: String
        let operationID: UUID
        let updatedAt: Date
    }

    private struct DeletionTombstonePlanRequest: Encodable {
        let workspaceID: UUID
        let fileURL: URL
        let operation: DomainRecordedOperation
        let deletedAt: Date
        let cleanupWarnings: [String]
    }

    private struct DeleteTransactionRequest: Encodable {
        let expectedWorkspaceID: UUID
        let expectedFileURL: URL
        let expectedWorkingRevision: UInt64
        let expectedCatalogRevision: UInt64
        let operation: DomainRecordedOperation
        let deletedAt: Date
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

        func close() {
            core.close()
        }
    }

    struct PreparedValidator: Sendable {
        private let core: CorePreparedWorkspaceWorkingJournalValidatorV1

        fileprivate init(core: CorePreparedWorkspaceWorkingJournalValidatorV1) {
            self.core = core
        }

        func planSavedRevision(
            workspaceID: UUID,
            savedRevision: UInt64,
            documentDigest: String,
            operationID: UUID,
            updatedAt: Date
        ) throws -> DomainWorkspaceSavedRevisionValidation {
            do {
                let bytes = try encode(SavedRevisionPlanRequest(
                    workspaceID: workspaceID,
                    savedRevision: savedRevision,
                    documentDigest: documentDigest,
                    operationID: operationID,
                    updatedAt: updatedAt
                ))
                return try materializeSavedRevision(
                    core.planSavedRevision(bytes),
                    expectedWorkspaceID: workspaceID,
                    expectedOperationID: operationID,
                    expectedSavedRevision: savedRevision,
                    expectedDocumentDigest: documentDigest,
                    expectedUpdatedAt: updatedAt
                )
            } catch {
                throw mapMetadataPlan(error)
            }
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

        func planDeletionTombstone(
            workspaceID: UUID,
            fileURL: URL,
            operation: DomainRecordedOperation,
            deletedAt: Date,
            cleanupWarnings: [String] = []
        ) throws -> DomainWorkspaceDeletionTombstoneValidation {
            do {
                let bytes = try encode(DeletionTombstonePlanRequest(
                    workspaceID: workspaceID,
                    fileURL: fileURL,
                    operation: operation,
                    deletedAt: deletedAt,
                    cleanupWarnings: cleanupWarnings
                ))
                let validated = try core.planDeletionTombstone(bytes)
                guard validated.workspaceID == workspaceID,
                      validated.operationID == operation.operationID,
                      validated.schemaVersion == UInt16(DomainDeletionTombstone.schemaVersion),
                      DomainContentDigest.sha256(validated.canonicalBytes) == validated.contentDigest
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                let tombstone = try JSONDecoder().decode(
                    DomainDeletionTombstone.self,
                    from: validated.canonicalBytes
                )
                let expectedDiagnostic = cleanupWarnings.isEmpty
                    ? operation.diagnostic
                    : "artifact_cleanup_incomplete: \(cleanupWarnings.joined(separator: "; "))"
                guard tombstone.workspaceID == workspaceID,
                      tombstone.fileURL.standardizedFileURL == fileURL.standardizedFileURL,
                      tombstone.version == DomainDeletionTombstone.schemaVersion,
                      tombstone.deletedAt == deletedAt,
                      tombstone.operation.operationID == operation.operationID,
                      tombstone.operation.fingerprint == operation.fingerprint,
                      tombstone.operation.recordedAt == operation.recordedAt,
                      tombstone.operation.disposition == operation.disposition,
                      tombstone.operation.before == operation.before,
                      tombstone.operation.after == operation.after,
                      tombstone.operation.catalogRevision == operation.catalogRevision,
                      tombstone.operation.resultingDigest == operation.resultingDigest,
                      tombstone.operation.errorCode == operation.errorCode,
                      tombstone.operation.diagnostic == expectedDiagnostic
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

        func planCatalogTransition(
            current: DomainWorkspaceCatalogValidation?,
            transition: DomainWorkspaceCatalogTransition
        ) throws -> DomainWorkspaceCatalogValidation {
            do {
                let encoded = transition.encoded
                let candidate = try materializeCatalog(core.planCatalogTransition(
                    currentCatalogBytes: current?.canonicalBytes,
                    transitionBytes: try encode(encoded)
                ))
                let expectedRevision: UInt64
                switch transition {
                case .seed:
                    expectedRevision = 0
                case let .upsert(expected, _, _, _),
                     let .delete(expected, _, _),
                     let .recoverCreate(expected, _, _, _):
                    let advanced = expected.addingReportingOverflow(1)
                    guard !advanced.overflow else {
                        throw DomainPersistenceError.writeFailed("workspace_catalog_transition_invalid")
                    }
                    expectedRevision = advanced.partialValue
                }
                guard candidate.catalog.revision == expectedRevision,
                      candidate.catalog.updatedAt == encoded.updatedAt
                else {
                    throw DomainPersistenceError.corruptJournal
                }
                switch transition {
                case let .seed(entries, _):
                    guard candidate.catalog.entries == entries,
                          candidate.catalog.deletions?.isEmpty == true
                    else { throw DomainPersistenceError.corruptJournal }
                case let .upsert(_, workspaceID, fileURL, _):
                    guard candidate.catalog.entries.contains(where: {
                        $0.workspaceID == workspaceID
                            && $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL
                    }),
                    candidate.catalog.deletions?.contains(where: {
                        $0.workspaceID == workspaceID
                    }) != true
                    else { throw DomainPersistenceError.corruptJournal }
                case let .delete(_, tombstone, _):
                    guard !candidate.catalog.entries.contains(where: {
                        $0.workspaceID == tombstone.workspaceID
                    }),
                    candidate.catalog.deletions?.contains(tombstone) == true
                    else { throw DomainPersistenceError.corruptJournal }
                case let .recoverCreate(_, workspaceID, fileURL, _):
                    guard candidate.catalog.entries.contains(where: {
                        $0.workspaceID == workspaceID
                            && $0.fileURL.standardizedFileURL == fileURL.standardizedFileURL
                    }),
                    candidate.catalog.deletions?.contains(where: {
                        $0.workspaceID == workspaceID
                    }) != true
                    else { throw DomainPersistenceError.corruptJournal }
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

        func beginDeleteTransaction(
            rawCatalogBytes: Data?,
            effectiveCatalog: DomainWorkspaceCatalogValidation,
            effectiveJournal: DomainWorkspaceWorkingJournalValidation,
            document: DomainWorkspaceDocument,
            expectedWorkingRevision: UInt64,
            expectedCatalogRevision: UInt64,
            operation: DomainRecordedOperation,
            deletedAt: Date
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
                    requestBytes: try encode(request)
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
            diskDocumentBytes: Data?
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
                    diskDocumentBytes: diskDocumentBytes
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
                    authorityReceipt
                ):
                    switch kind {
                    case .writePendingJournal:
                        guard authorityReceipt == nil,
                              logicalExpectedRevision == expectedWorkingRevision
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
                            )
                        )
                    case .writeCommittedJournal:
                        guard authorityReceipt == nil,
                              let expectedRawJournalDigest,
                              logicalExpectedRevision == expectedWorkingRevision
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
                            logicalExpectedRevision: expectedWorkingRevision
                        )
                    case .writeSavedRevision:
                        guard authorityReceipt == nil,
                              expectedRawJournalDigest == nil,
                              logicalExpectedRevision == nil
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
                        return .writeSavedRevision(actionID: actionID, validation: validation)
                    }
                case let .committed(receipt, finalization):
                    let mappedFinalization: DomainWorkspaceSaveFinalization = switch finalization {
                    case .finalized: .finalized
                    case .pendingJournalRetained: .pendingJournalRetained
                    case .revisionSidecarMissing: .revisionSidecarMissing
                    }
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
                        finalization: mappedFinalization
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

        func planTransition(
            current: DomainWorkingJournal?,
            transition: DomainWorkspaceWorkingJournalTransition,
            documentBytes: Data? = nil
        ) throws -> DomainWorkspaceWorkingJournalTransitionPlan {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let currentBytes = try current.map { try encoder.encode($0) }
                let encodedTransition = transition.encoded
                let transitionBytes = try encoder.encode(encodedTransition)
                let plan = try core.planTransition(
                    currentJournalBytes: currentBytes,
                    transitionBytes: transitionBytes,
                    documentBytes: documentBytes
                )
                let expectedWorkspaceID = current?.workspaceID ?? encodedTransition.workspaceID
                    ?? encodedTransition.expectedWorkspaceID
                let expectedFileURL = current?.fileURL ?? encodedTransition.fileURL
                return DomainWorkspaceWorkingJournalTransitionPlan(
                    primary: try materialize(
                        plan.primary,
                        expectedWorkspaceID: expectedWorkspaceID,
                        expectedFileURL: expectedFileURL
                    ),
                    committed: try plan.committed.map {
                        try materialize(
                            $0,
                            expectedWorkspaceID: expectedWorkspaceID,
                            expectedFileURL: expectedFileURL
                        )
                    }
                )
            } catch {
                if transition.mapsInvalidRevisionToInvalidDocument,
                   error as? CoreWorkspaceWorkingJournalValidationError == .invalidRevisionState
                {
                    throw DomainPersistenceError.invalidWorkspaceDocument
                }
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
