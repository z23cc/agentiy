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
        case let .replaceSelection(request):
            command = .replace(
                workspaceID: request.workspaceID,
                fileURL: request.candidateDocument.fileURL,
                contentDigest: request.candidateDocument.contentDigest
            )
        case let .replaceContext(request):
            command = .replace(
                workspaceID: request.workspaceID,
                fileURL: request.candidateDocument.fileURL,
                contentDigest: request.candidateDocument.contentDigest
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

package enum DomainWorkspaceSemanticPreflightDisposition: Sendable, Equatable {
    case proceed
    case unchanged
    case conflict
    case missing
    case unavailable
}

package struct DomainWorkspaceSemanticPreflight: Sendable, Equatable {
    package let workspaceID: UUID
    package let command: DomainWorkspaceCommandIdentityInput.Command
    package let disposition: DomainWorkspaceSemanticPreflightDisposition
    package let catalogRevision: UInt64
    package let revisions: DomainRevisionState?
    package let health: DomainAuthorityHealth?
    package let contentDigest: String?
    package let changedContextIDs: [UUID]
    package let addedContextIDs: [UUID]
    package let removedContextIDs: [UUID]
    package let externalDocumentDigest: String?
    package let protectedContextIDs: [UUID]
    package let diagnostic: String?

    package init(
        workspaceID: UUID,
        command: DomainWorkspaceCommandIdentityInput.Command,
        disposition: DomainWorkspaceSemanticPreflightDisposition,
        catalogRevision: UInt64,
        revisions: DomainRevisionState?,
        health: DomainAuthorityHealth?,
        contentDigest: String?,
        changedContextIDs: [UUID] = [],
        addedContextIDs: [UUID] = [],
        removedContextIDs: [UUID] = [],
        externalDocumentDigest: String? = nil,
        protectedContextIDs: [UUID] = [],
        diagnostic: String?
    ) {
        self.workspaceID = workspaceID
        self.command = command
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

package enum DomainExternalObservationDisposition: Sendable, Equatable {
    case noChange
    case cleanReload
    case dirtyConflict
}

package enum DomainExternalObservationCandidate: Sendable, Equatable {
    case none
    case externalDocument
    case existingWorkingDocument
}

package enum DomainExternalObservationTransition: Sendable, Equatable {
    case none
    case externalReload
    case conflictRebase
}

package struct DomainExternalObservationRecoveryPlan: Sendable, Equatable {
    package let workspaceID: UUID
    package let expectedFileURL: URL
    package let catalogRevision: UInt64
    package let workspaceRevision: UInt64
    package let aggregateGeneration: UInt64
    package let semanticGeneration: UInt64
    package let publicationSequence: UInt64
    package let semanticProjectionDigest: String
    package let currentDocumentDigest: String
    package let savedDigest: String
    package let externalDocumentDigest: String
    package let changedContextIDs: [UUID]
    package let addedContextIDs: [UUID]
    package let removedContextIDs: [UUID]
    package let disposition: DomainExternalObservationDisposition
    package let candidate: DomainExternalObservationCandidate
    package let transition: DomainExternalObservationTransition
    package let updatedAt: Date
    package let revisionSidecarID: UUID?
    package let diagnostic: String?
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

/// Rust-owned semantic transition request. Swift supplies command data; Rust owns disk writes
/// and returns canonical candidate bytes.
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

/// P5-5 prepared Rust journal authority bound to one exact live runtime identity.
enum DomainWorkspaceRustJournal {

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

        func semanticPreflight(
            _ input: DomainWorkspaceCommandIdentityInput,
            candidateDocumentBytes: Data? = nil,
            externalDocumentBytes: Data? = nil
        ) throws -> DomainWorkspaceSemanticPreflight {
            let request = validator.coreCommandIdentityRequest(input)
            do {
                let preflight = try core.semanticPreflight(
                    request,
                    candidateDocumentBytes: candidateDocumentBytes,
                    externalDocumentBytes: externalDocumentBytes
                )
                let revisionsValid = preflight.revisions.map {
                    $0.savedRevision <= $0.workingRevision
                        && ($0.dirtyRevision == nil || $0.dirtyRevision == $0.workingRevision)
                } ?? true
                guard preflight.workspaceID == request.workspaceID,
                      preflight.commandKind == request.commandKind,
                      preflight.contentDigest.map(PreparedValidator.isSHA256Digest) ?? true,
                      preflight.externalDocumentDigest.map(PreparedValidator.isSHA256Digest) ?? true,
                      revisionsValid
                else {
                    throw DomainPersistenceError.journalCorruption()
                }
                if let externalDocumentBytes {
                    guard preflight.externalDocumentDigest
                        == DomainContentDigest.sha256(externalDocumentBytes)
                    else {
                        throw DomainPersistenceError.journalCorruption()
                    }
                } else {
                    guard preflight.externalDocumentDigest == nil else {
                        throw DomainPersistenceError.journalCorruption()
                    }
                }
                let disposition: DomainWorkspaceSemanticPreflightDisposition = switch preflight.disposition {
                case .proceed: .proceed
                case .unchanged: .unchanged
                case .conflict: .conflict
                case .missing: .missing
                case .unavailable: .unavailable
                }
                return DomainWorkspaceSemanticPreflight(
                    workspaceID: preflight.workspaceID,
                    command: input.command,
                    disposition: disposition,
                    catalogRevision: preflight.catalogRevision,
                    revisions: preflight.revisions.map {
                        DomainRevisionState(
                            workingRevision: $0.workingRevision,
                            savedRevision: $0.savedRevision,
                            dirtyRevision: $0.dirtyRevision
                        )
                    },
                    health: preflight.health.map {
                        switch $0.kind {
                        case .writable: .writable
                        case .externalConflict: .externalConflict(reason: $0.reason ?? "external_conflict")
                        case .degradedReadOnly: .degradedReadOnly(reason: $0.reason ?? "projection_unavailable")
                        case .removed: .removed
                        }
                    },
                    contentDigest: preflight.contentDigest,
                    changedContextIDs: preflight.changedContextIDs,
                    addedContextIDs: preflight.addedContextIDs,
                    removedContextIDs: preflight.removedContextIDs,
                    externalDocumentDigest: preflight.externalDocumentDigest,
                    protectedContextIDs: preflight.protectedContextIDs,
                    diagnostic: preflight.diagnostic
                )
            } catch let error as DomainPersistenceError {
                throw error
            } catch {
                throw validator.mapCommandAdmissionError(error)
            }
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
                    throw DomainPersistenceError.journalCorruption()
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

        func prepareExternalObservationRecovery(
            workspaceID: UUID,
            fileURL: URL,
            catalogRevision: UInt64,
            workspaceRevision: UInt64,
            currentDocumentDigest: String,
            savedDigest: String,
            externalDocumentBytes: Data,
            updatedAt: Date
        ) throws -> DomainExternalObservationRecoveryPlan {
            do {
                let plan = try core.prepareExternalObservationRecovery(
                    CoreWorkspaceExternalObservationRecoveryRequestV1(
                        workspaceID: workspaceID,
                        expectedFileURL: fileURL,
                        expectedCatalogRevision: catalogRevision,
                        expectedWorkspaceRevision: workspaceRevision,
                        currentDocumentDigest: currentDocumentDigest,
                        savedDigest: savedDigest,
                        externalDocumentBytes: externalDocumentBytes,
                        updatedAt: updatedAt
                    )
                )
                let disposition: DomainExternalObservationDisposition = switch plan.disposition {
                case .noChange: .noChange
                case .cleanReload: .cleanReload
                case .dirtyConflict: .dirtyConflict
                }
                let candidate: DomainExternalObservationCandidate = switch plan.candidate {
                case .none: .none
                case .externalDocument: .externalDocument
                case .existingWorkingDocument: .existingWorkingDocument
                }
                let transition: DomainExternalObservationTransition = switch plan.transition {
                case .none: .none
                case .externalReload: .externalReload
                case .conflictRebase: .conflictRebase
                }
                guard plan.workspaceID == workspaceID,
                      plan.expectedFileURL.standardizedFileURL == fileURL.standardizedFileURL,
                      plan.catalogRevision == catalogRevision,
                      plan.workspaceRevision == workspaceRevision,
                      plan.semanticGeneration > 0 || plan.publicationSequence == 0,
                      PreparedValidator.isSHA256Digest(plan.semanticProjectionDigest),
                      PreparedValidator.isSHA256Digest(plan.currentDocumentDigest),
                      PreparedValidator.isSHA256Digest(plan.savedDigest),
                      PreparedValidator.isSHA256Digest(plan.externalDocumentDigest),
                      abs(plan.updatedAt.timeIntervalSinceReferenceDate - updatedAt.timeIntervalSinceReferenceDate) <= 0.000001,
                      (transition == .externalReload) == (plan.revisionSidecarID != nil)
                else {
                    throw DomainPersistenceError.journalCorruption()
                }
                return DomainExternalObservationRecoveryPlan(
                    workspaceID: plan.workspaceID,
                    expectedFileURL: plan.expectedFileURL,
                    catalogRevision: plan.catalogRevision,
                    workspaceRevision: plan.workspaceRevision,
                    aggregateGeneration: plan.aggregateGeneration,
                    semanticGeneration: plan.semanticGeneration,
                    publicationSequence: plan.publicationSequence,
                    semanticProjectionDigest: plan.semanticProjectionDigest,
                    currentDocumentDigest: plan.currentDocumentDigest,
                    savedDigest: plan.savedDigest,
                    externalDocumentDigest: plan.externalDocumentDigest,
                    changedContextIDs: plan.changedContextIDs,
                    addedContextIDs: plan.addedContextIDs,
                    removedContextIDs: plan.removedContextIDs,
                    disposition: disposition,
                    candidate: candidate,
                    transition: transition,
                    updatedAt: plan.updatedAt,
                    revisionSidecarID: plan.revisionSidecarID,
                    diagnostic: plan.diagnostic
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

        func createWorkspaceDirect(
            storageDirectory: String,
            workspaceID: UUID,
            workspaceName: String,
            documentBytes: Data,
            expectedCatalogRevision: UInt64,
            operationID: UUID,
            fingerprint: String?
        ) throws -> CoreWorkspaceCommandResultV1 {
            try core.createWorkspaceDirect(
                storageDirectory: storageDirectory,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                documentBytes: documentBytes,
                expectedCatalogRevision: expectedCatalogRevision,
                operationID: operationID,
                fingerprint: fingerprint
            )
        }

        func saveWorkspaceDirect(
            storageDirectory: String,
            workspaceID: UUID,
            documentBytes: Data,
            expectedWorkingRevision: UInt64,
            expectedCatalogRevision: UInt64,
            operationID: UUID,
            fingerprint: String?
        ) throws -> CoreWorkspaceCommandResultV1 {
            try core.saveWorkspaceDirect(
                storageDirectory: storageDirectory,
                workspaceID: workspaceID,
                documentBytes: documentBytes,
                expectedWorkingRevision: expectedWorkingRevision,
                expectedCatalogRevision: expectedCatalogRevision,
                operationID: operationID,
                fingerprint: fingerprint
            )
        }

        func deleteWorkspaceDirect(
            storageDirectory: String,
            workspaceID: UUID,
            expectedCatalogRevision: UInt64,
            operationID: UUID
        ) throws -> CoreWorkspaceCommandResultV1 {
            try core.deleteWorkspaceDirect(
                storageDirectory: storageDirectory,
                workspaceID: workspaceID,
                expectedCatalogRevision: expectedCatalogRevision,
                operationID: operationID
            )
        }

        func mutateWorkingDirect(
            storageDirectory: String,
            workspaceID: UUID,
            candidateDocumentBytes: Data,
            expectedWorkingRevision: UInt64,
            operationID: UUID
        ) throws -> CoreWorkspaceCommandResultV1 {
            try core.mutateWorkingDirect(
                storageDirectory: storageDirectory,
                workspaceID: workspaceID,
                candidateDocumentBytes: candidateDocumentBytes,
                expectedWorkingRevision: expectedWorkingRevision,
                operationID: operationID
            )
        }

        func isWorkspaceQuarantined(
            storageDirectory: String,
            workspaceID: UUID
        ) throws -> (isQuarantined: Bool, reason: String?) {
            try core.isWorkspaceQuarantined(
                storageDirectory: storageDirectory,
                workspaceID: workspaceID
            )
        }

        func quarantinedWorkspaces(
            storageDirectory: String
        ) throws -> [(workspaceID: UUID, reason: String)] {
            try core.quarantinedWorkspaces(
                storageDirectory: storageDirectory
            )
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
                    throw DomainPersistenceError.journalCorruption()
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

        fileprivate static func datesEqual(_ lhs: Date, _ rhs: Date) -> Bool {
            abs(lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate) <= 0.000001
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
                throw DomainPersistenceError.journalCorruption()
            }
            let errorCode: DomainCommandErrorCode?
            if let rawErrorCode = operation.errorCode {
                guard let value = DomainCommandErrorCode(rawValue: rawErrorCode) else {
                    throw DomainPersistenceError.journalCorruption()
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
                throw DomainPersistenceError.journalCorruption()
            }
            let externalDocument = try active.externalDocumentBytes.map { bytes in
                let external = try DomainWorkspaceDocument.decode(
                    documentBytes: bytes,
                    fileURL: active.fileURL
                )
                guard external.workspaceID == active.workspaceID else {
                    throw DomainPersistenceError.journalCorruption()
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
                throw DomainPersistenceError.journalCorruption()
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
                    throw DomainPersistenceError.journalCorruption("catalog_validation_rejected")
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
                    throw DomainPersistenceError.journalCorruption()
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
                        throw DomainPersistenceError.journalCorruption()
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
                throw DomainPersistenceError.journalCorruption()
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
                throw DomainPersistenceError.journalCorruption()
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
                throw DomainPersistenceError.journalCorruption()
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
                  expectedUpdatedAt.map { Self.datesEqual(record.updatedAt, $0) } ?? true
            else {
                throw DomainPersistenceError.journalCorruption()
            }
            return DomainWorkspaceSavedRevisionValidation(
                record: record,
                canonicalBytes: validated.canonicalBytes,
                contentDigest: validated.contentDigest
            )
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
                throw DomainPersistenceError.journalCorruption("journal_validation_identity_or_digest")
            }
            let journal: DomainWorkingJournal
            do {
                journal = try JSONDecoder().decode(
                    DomainWorkingJournal.self,
                    from: validated.canonicalBytes
                )
            } catch {
                throw DomainPersistenceError.journalCorruption("journal_decode_failed")
            }
            guard journal.workspaceID == validated.workspaceID,
                  journal.version == DomainWorkingJournal.schemaVersion,
                  expectedFileURL == nil
                  || journal.fileURL.standardizedFileURL == expectedFileURL?.standardizedFileURL
            else {
                throw DomainPersistenceError.journalCorruption("journal_decoded_fields_mismatch")
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
                // Ten distinct Rust journal errors used to arrive here as one indistinguishable
                // value. Keeping the variant name is the difference between "the journal is broken
                // somewhere" and "the catalog has no entry for this workspace".
                return .journalCorruption("rust:\(error)")
            case .externalDocumentConflict:
                return .externalDocumentConflict
            case .staleRecoverySnapshot:
                return .admissionRecoveryStale
            case .fullRecoveryRequired:
                return .admissionFullRecoveryRequired
            case .invalidTransaction:
                return .writeFailed("workspace_save_transaction_invalid")
            case .workspaceQuarantined:
                return .journalCorruption("workspace_quarantined")
            case .persistenceIoError:
                return .writeFailed("persistence_io_error")
            case .unsupportedCatalogSchemaVersion:
                return .writeFailed("unsupported_catalog_schema_version")
            case .storageLeaseRequired:
                return .writeFailed("storage_lease_required")
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
