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
