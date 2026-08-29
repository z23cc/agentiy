import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceRustJournalTests: XCTestCase {
    func testRustValidationRoundTripsSwiftV1JournalAndRejectsIdentityMismatch() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let revisions = DomainRevisionState(
            workingRevision: 1,
            savedRevision: 0,
            dirtyRevision: 1
        )
        let documentBytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Workspace",
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": "working",
                "selectedPaths": []
            ]]
        ], options: [.sortedKeys])
        let operationID = UUID()
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "c", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 41.5),
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: .initial,
                after: revisions,
                catalogRevision: 1,
                resultingDigest: DomainContentDigest.sha256(documentBytes)
            )
        )
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/Workspace.json"),
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: documentBytes,
            contextRevisions: [contextID: revisions],
            contextDigests: [contextID: String(repeating: "b", count: 64)],
            contextTombstones: [:],
            operations: [operation],
            pendingSave: DomainPendingSave(
                operationID: operationID,
                documentDigest: DomainContentDigest.sha256(documentBytes)
            ),
            updatedAt: Date(timeIntervalSinceReferenceDate: 42.5)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(journal)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }

        let validated = try await DomainWorkspaceRustJournal.validate(
            bytes,
            expectedWorkspaceID: workspaceID,
            coreService: service
        )

        XCTAssertEqual(validated.journal.workspaceID, workspaceID)
        XCTAssertEqual(validated.journal.revisions, revisions)
        XCTAssertEqual(validated.journal.operations, [operation])
        XCTAssertEqual(validated.journal.pendingSave?.operationID, operationID)
        XCTAssertEqual(
            DomainContentDigest.sha256(validated.canonicalBytes),
            validated.contentDigest
        )
        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                bytes,
                expectedWorkspaceID: UUID(),
                coreService: service
            )
            XCTFail("mismatched workspace identity unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }
    }

    func testPreparedCommandIdentityIsStableAndCanonicalForEveryCommandAndOrigin() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/CommandIdentity-\(workspaceID.uuidString).json")
        func document(_ marker: String) -> DomainWorkspaceDocument {
            DomainWorkspaceDocument(
                workspaceID: workspaceID,
                fileURL: fileURL,
                documentBytes: Data(marker.utf8),
                metadata: DomainWorkspaceMetadata(
                    workspaceID: workspaceID,
                    schemaVersion: 1,
                    name: "Workspace",
                    repoPaths: [],
                    customStoragePath: nil,
                    isSystemWorkspace: false,
                    isHiddenInMenus: false,
                    isEphemeral: false,
                    activeContextID: nil,
                    contexts: []
                )
            )
        }
        let protected = [
            DomainProtectedAgentIdentity(
                tabID: try XCTUnwrap(UUID(
                    uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"
                )),
                location: .stashed,
                activeAgentSessionID: nil,
                isPinned: false
            ),
            DomainProtectedAgentIdentity(
                tabID: try XCTUnwrap(UUID(
                    uuidString: "00000000-0000-0000-0000-000000000001"
                )),
                location: .composed,
                activeAgentSessionID: try XCTUnwrap(UUID(
                    uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab"
                )),
                isPinned: true
            )
        ]
        let operationID = UUID()
        let envelopes = [
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: nil,
                expectedWorkspaceRevision: nil,
                expectedContextRevision: nil,
                origin: .appPresentation(windowID: 42),
                command: .createWorkspace(document("create"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: 7,
                expectedWorkspaceRevision: 8,
                expectedContextRevision: 9,
                origin: .appMCP(connectionID: UUID()),
                command: .replaceWorkingDocument(document("replace"))
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 3,
                origin: .appMCP(connectionID: nil),
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedCatalogRevision: 4,
                expectedWorkspaceRevision: 5,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 6,
                expectedContextRevision: 7,
                origin: .externalReload,
                command: .resolveExternalConflict(
                    workspaceID: workspaceID,
                    acceptExternal: false,
                    protectedAgentIdentities: protected
                )
            )
        ]
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let fingerprints = try envelopes.map { envelope in
            let fingerprint = try prepared.commandIdentity(envelope)
            XCTAssertEqual(try prepared.commandIdentity(envelope), fingerprint)
            XCTAssertEqual(fingerprint.count, 64)
            XCTAssertNotNil(fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            return fingerprint
        }
        XCTAssertEqual(Set(fingerprints).count, envelopes.count)

        let fieldIsolationEnvelopes = [
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .standalone,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .externalReload,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                expectedWorkspaceRevision: 1,
                origin: .standalone,
                command: .saveWorkspaceDocument(workspaceID: workspaceID)
            ),
            DomainWorkspaceCommandEnvelope(
                operationID: operationID,
                origin: .standalone,
                command: .deleteWorkspace(workspaceID: workspaceID)
            )
        ]
        XCTAssertEqual(
            Set(try fieldIsolationEnvelopes.map(prepared.commandIdentity)).count,
            fieldIsolationEnvelopes.count,
            "command kind, origin, and revision fences must each affect Rust identity"
        )
        let reversed = DomainWorkspaceCommandEnvelope(
            operationID: envelopes[4].operationID,
            expectedWorkspaceRevision: 6,
            expectedContextRevision: 7,
            origin: .externalReload,
            command: .resolveExternalConflict(
                workspaceID: workspaceID,
                acceptExternal: false,
                protectedAgentIdentities: Array(protected.reversed())
            )
        )
        XCTAssertEqual(try prepared.commandIdentity(reversed), fingerprints[4])
    }

    func testPreparedCommandAdmissionRoundTripsClaimBoundDomainReceipt() async throws {
        let workspaceID = UUID()
        let revisions = DomainRevisionState(
            workingRevision: 3,
            savedRevision: 2,
            dirtyRevision: 3
        )
        let seededOperation = DomainRecordedOperation(
            fingerprint: String(repeating: "f", count: 64),
            recordedAt: Date(timeIntervalSinceReferenceDate: 42.5),
            outcome: DomainCommandOutcome(
                operationID: UUID(),
                disposition: .applied,
                before: nil,
                after: revisions,
                catalogRevision: 7,
                resultingDigest: DomainContentDigest.sha256(Data())
            )
        )
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let validator = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        let fileURL = URL(fileURLWithPath: "/tmp/Admission-\(workspaceID).json")
        let admission = try beginDomainCommandAdmission(
            validator: validator,
            workspaces: [(workspaceID, fileURL, [seededOperation])]
        )
        defer { admission.close() }
        XCTAssertEqual(try admission.diagnostics().globalOperationCount, 1)

        let transientEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 7,
            expectedWorkspaceRevision: 3,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let transientInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(transientEnvelope))
        let transientFingerprint: String
        let transientClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
        let transientGeneration: UInt64
        switch try admission.acquire(transientInput) {
        case let .claimed(fingerprint, claim):
            transientFingerprint = fingerprint
            transientClaim = claim
        default:
            return XCTFail("Expected initial execution claim")
        }
        let preflight = try transientClaim.semanticPreflight(transientInput)
        XCTAssertEqual(preflight.workspaceID, workspaceID)
        XCTAssertEqual(preflight.disposition, .conflict)
        XCTAssertEqual(preflight.diagnostic, "catalog_revision_mismatch")
        XCTAssertNil(preflight.revisions)
        XCTAssertNil(preflight.health)
        XCTAssertEqual(try transientClaim.checkpoint(), .continueExecution)
        switch try admission.acquire(transientInput) {
        case let .pending(fingerprint, generation):
            XCTAssertEqual(fingerprint, transientFingerprint)
            transientGeneration = generation
        default:
            return XCTFail("Expected matching execution to remain pending")
        }
        XCTAssertGreaterThan(transientGeneration, 0)
        let collisionEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: transientEnvelope.operationID,
            expectedCatalogRevision: 7,
            expectedWorkspaceRevision: 3,
            origin: .externalReload,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let collisionInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(collisionEnvelope))
        switch try admission.acquire(collisionInput) {
        case let .collision(fingerprint, scope):
            XCTAssertNotEqual(fingerprint, transientFingerprint)
            XCTAssertNil(scope)
        default:
            XCTFail("Expected in-flight operation identity collision")
        }

        let transientOperation = DomainRecordedOperation(
            fingerprint: transientFingerprint,
            recordedAt: Date(timeIntervalSinceReferenceDate: 43),
            outcome: DomainCommandOutcome(
                operationID: transientEnvelope.operationID,
                disposition: .conflict,
                before: revisions,
                after: revisions,
                catalogRevision: 7,
                resultingDigest: nil,
                errorCode: .stateConflict,
                diagnostic: "transient"
            )
        )
        XCTAssertEqual(
            try transientClaim.finalizeTransient(operation: transientOperation),
            transientOperation
        )
        switch try admission.acquire(transientInput) {
        case let .replay(fingerprint, scope, operation):
            XCTAssertEqual(fingerprint, transientFingerprint)
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, transientOperation)
        default:
            XCTFail("Expected transient claim finalization to replay globally")
        }

        let durableEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedCatalogRevision: 8,
            expectedWorkspaceRevision: 3,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let durableInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(durableEnvelope))
        let durableFingerprint: String
        let durableClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
        switch try admission.acquire(durableInput) {
        case let .claimed(fingerprint, claim):
            durableFingerprint = fingerprint
            durableClaim = claim
        default:
            return XCTFail("Expected durable execution claim")
        }
        let durableOperation = DomainRecordedOperation(
            fingerprint: durableFingerprint,
            recordedAt: Date(timeIntervalSinceReferenceDate: 44),
            outcome: DomainCommandOutcome(
                operationID: durableEnvelope.operationID,
                disposition: .unchanged,
                before: revisions,
                after: revisions,
                catalogRevision: 8,
                resultingDigest: nil
            )
        )
        let durableRecovery = try domainSemanticRecovery(
            validator: validator,
            workspaces: [(workspaceID, fileURL, [durableOperation])]
        )
        let durableEvidence = try XCTUnwrap(durableRecovery.workspaces.first)
        let targetRecovery = try admission.prepareSemanticTargetRecovery(.init(
            catalogBytes: durableRecovery.catalogBytes,
            catalogRevision: durableRecovery.catalogRevision,
            catalogDigest: durableRecovery.catalogDigest,
            workspaceID: workspaceID,
            journal: durableEvidence.journal,
            savedDocument: durableEvidence.savedDocument,
            savedRevision: durableEvidence.savedRevision,
            deletionSidecar: .absent
        ))
        let targetPreview = try targetRecovery.preview()
        let targetCommit = try targetRecovery.commit(expected: targetPreview)
        XCTAssertEqual(targetCommit.targetWorkspaceID, workspaceID)
        XCTAssertFalse(try durableClaim.abandon())
        switch try admission.acquire(durableInput) {
        case let .replay(fingerprint, scope, operation):
            XCTAssertEqual(fingerprint, durableFingerprint)
            XCTAssertEqual(scope, .workspace)
            XCTAssertEqual(operation, durableOperation)
        default:
            XCTFail("Expected reconciled receipt to replay in workspace scope")
        }

        let fullRecovery = try admission.prepareSemanticFullRecovery(durableRecovery)
        let fullPreview = try fullRecovery.preview()
        let fullCommit = try fullRecovery.commit(expected: fullPreview)
        let reconciled = try XCTUnwrap(fullCommit.admissionReceipt)
        XCTAssertEqual(reconciled.diagnostics.globalOperationCount, 3)
        XCTAssertEqual(reconciled.diagnostics.workspaceOperationCount, 1)
        let emptyRecovery = try domainSemanticRecovery(
            validator: validator,
            workspaces: [(workspaceID, fileURL, [])]
        )
        let emptyEvidence = try XCTUnwrap(emptyRecovery.workspaces.first)
        let emptyTargetRecovery = try admission.prepareSemanticTargetRecovery(.init(
            catalogBytes: emptyRecovery.catalogBytes,
            catalogRevision: emptyRecovery.catalogRevision,
            catalogDigest: emptyRecovery.catalogDigest,
            workspaceID: workspaceID,
            journal: emptyEvidence.journal,
            savedDocument: emptyEvidence.savedDocument,
            savedRevision: emptyEvidence.savedRevision,
            deletionSidecar: .absent
        ))
        let emptyPreview = try emptyTargetRecovery.preview()
        _ = try emptyTargetRecovery.commit(expected: emptyPreview)
        switch try admission.acquire(durableInput) {
        case let .replay(_, scope, operation):
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, durableOperation)
        default:
            XCTFail("Removing workspace scope must retain global replay")
        }
        admission.close()
        XCTAssertThrowsError(try admission.diagnostics()) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("workspace_save_transaction_invalid")
            )
        }
    }

    func testPreparedCommandAdmissionCarriesRuntimeCancellationAndDeadline() async throws {
        let workspaceID = UUID()
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let validator = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        let admission = try beginDomainCommandAdmission(validator: validator)
        defer { admission.close() }
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let input = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(envelope))

        _ = try admission.cancel(operationID: envelope.operationID)
        switch try admission.acquire(input) {
        case let .claimed(_, claim):
            XCTAssertEqual(try claim.checkpoint(), .cancelled)
            XCTAssertTrue(try claim.abandon())
        default:
            XCTFail("A runtime cancellation tombstone must materialize a stopped exact claim")
        }

        let racedEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let racedInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(racedEnvelope))
        let racedFingerprint: String
        let racedClaim: DomainWorkspaceRustJournal.PreparedExecutionClaim
        switch try admission.acquire(racedInput) {
        case let .claimed(fingerprint, claim):
            racedFingerprint = fingerprint
            racedClaim = claim
        default:
            return XCTFail("Expected finalization-race claim")
        }
        _ = try admission.cancel(operationID: racedEnvelope.operationID)
        let semanticOperation = DomainRecordedOperation(
            fingerprint: racedFingerprint,
            recordedAt: Date(),
            outcome: DomainCommandOutcome(
                operationID: racedEnvelope.operationID,
                disposition: .conflict,
                before: nil,
                after: nil,
                catalogRevision: 0,
                resultingDigest: nil,
                errorCode: .stateConflict,
                diagnostic: "semantic_result_lost_race"
            )
        )
        XCTAssertThrowsError(try racedClaim.finalizeTransient(operation: semanticOperation)) { error in
            XCTAssertEqual(
                error as? DomainWorkspaceCommandLifecycleFinalizationError,
                .cancelled
            )
        }
        let cancelledOperation = DomainRecordedOperation(
            fingerprint: racedFingerprint,
            recordedAt: Date(),
            outcome: DomainCommandOutcome(
                operationID: racedEnvelope.operationID,
                disposition: .failed,
                before: nil,
                after: nil,
                catalogRevision: 0,
                resultingDigest: nil,
                errorCode: .cancelled,
                diagnostic: "workspace_command_identity_cancelled"
            )
        )
        XCTAssertEqual(
            try racedClaim.finalizeTransient(operation: cancelledOperation),
            cancelledOperation
        )
        switch try admission.acquire(racedInput) {
        case let .replay(_, scope, operation):
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, cancelledOperation)
        default:
            XCTFail("The cancellation race must establish one replay receipt")
        }

        let deadlineEnvelope = DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: workspaceID)
        )
        let deadlineInput = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(deadlineEnvelope))
        XCTAssertThrowsError(
            try admission.acquire(deadlineInput, deadlineUnixMilliseconds: 1)
        ) { error in
            XCTAssertEqual(
                error as? DomainWorkspaceCommandAdmissionError,
                .deadlineExceeded
            )
        }
        switch try admission.acquire(deadlineInput) {
        case let .claimed(_, claim):
            XCTAssertEqual(try claim.checkpoint(), .continueExecution)
            XCTAssertTrue(try claim.abandon())
        default:
            XCTFail("Deadline rejection must roll the exact workspace claim back")
        }
    }

    func testPreparedValidatorRunsSynchronouslyAndMatchesAsyncBoundary() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Prepared-\(workspaceID.uuidString).json")
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 7.5)
        )
        let bytes = try JSONEncoder().encode(journal)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let synchronous = try await Task.detached {
            try prepared.validateSynchronously(
                bytes,
                expectedWorkspaceID: workspaceID,
                expectedFileURL: fileURL
            )
        }.value
        let asynchronous = try await DomainWorkspaceRustJournal.validate(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: fileURL,
            coreService: service
        )

        XCTAssertEqual(synchronous.journal, journal)
        XCTAssertEqual(synchronous.canonicalBytes, asynchronous.canonicalBytes)
        XCTAssertEqual(synchronous.contentDigest, asynchronous.contentDigest)
        XCTAssertThrowsError(try prepared.validateSynchronously(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: URL(fileURLWithPath: "/tmp/other.json")
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }
    }

    func testPreparedValidatorSeedsMissingJournalWithRustOwnedScalarValidation() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Seeded-\(workspaceID.uuidString).json")
        let savedDigest = String(repeating: "a", count: 64)
        let contextDigests = [contextID: String(repeating: "b", count: 64)]
        let updatedAt = Date(timeIntervalSinceReferenceDate: 12)
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let seeded = try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )
        let repeated = try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: .initial,
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )

        XCTAssertEqual(seeded.journal, repeated.journal)
        XCTAssertEqual(seeded.canonicalBytes, repeated.canonicalBytes)
        XCTAssertEqual(seeded.contentDigest, repeated.contentDigest)
        XCTAssertEqual(seeded.journal.workspaceID, workspaceID)
        XCTAssertEqual(seeded.journal.fileURL, fileURL)
        XCTAssertEqual(seeded.journal.revisions, .initial)
        XCTAssertEqual(seeded.journal.savedDigest, savedDigest)
        XCTAssertEqual(seeded.journal.contextDigests, contextDigests)
        XCTAssertNil(seeded.journal.pendingSave)
        XCTAssertNil(seeded.journal.workingDocument)

        XCTAssertThrowsError(try prepared.seedWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: DomainRevisionState(
                workingRevision: 0,
                savedRevision: 1,
                dirtyRevision: nil
            ),
            savedDigest: savedDigest,
            contextDigests: contextDigests,
            updatedAt: updatedAt
        )) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_transition_invalid")
            )
        }
    }

    func testPreparedValidatorValidatesPersistenceMetadata() async throws {
        let workspaceID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Deleted-\(workspaceID.uuidString).json")
        let documentDigest = DomainContentDigest.sha256(Data("saved document".utf8))
        let timestamp = Date(timeIntervalSinceReferenceDate: 21.5)
        let operation = DomainRecordedOperation(
            fingerprint: String(repeating: "d", count: 64),
            recordedAt: timestamp,
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: DomainRevisionState(
                    workingRevision: 9,
                    savedRevision: 9,
                    dirtyRevision: nil
                ),
                after: nil,
                catalogRevision: 7,
                resultingDigest: documentDigest
            )
        )
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let savedRecord = DomainSavedRevisionRecord(
            version: DomainSavedRevisionRecord.schemaVersion,
            workspaceID: workspaceID,
            savedRevision: 9,
            documentDigest: documentDigest,
            operationID: operationID,
            updatedAt: timestamp
        )
        let validatedSaved = try prepared.validateSavedRevision(
            encoder.encode(savedRecord),
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: documentDigest
        )
        XCTAssertEqual(validatedSaved.record, savedRecord)
        XCTAssertEqual(DomainContentDigest.sha256(validatedSaved.canonicalBytes), validatedSaved.contentDigest)
        XCTAssertThrowsError(try prepared.validateSavedRevision(
            validatedSaved.canonicalBytes,
            expectedWorkspaceID: workspaceID,
            expectedDocumentDigest: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }

        let originalTombstone = DomainDeletionTombstone(
            version: DomainDeletionTombstone.schemaVersion,
            workspaceID: workspaceID,
            fileURL: fileURL,
            operation: operation,
            deletedAt: timestamp
        )
        let authoritative = try prepared.validateDeletionTombstone(
            encoder.encode(originalTombstone)
        )
        XCTAssertEqual(authoritative.tombstone, originalTombstone)
        XCTAssertNil(authoritative.tombstone.operation.diagnostic)
        XCTAssertEqual(
            DomainContentDigest.sha256(authoritative.canonicalBytes),
            authoritative.contentDigest
        )
    }

    func testDeleteTransactionOwnsCleanupPlanningFinalizationAndReplay() async throws {
        let workspaceID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Delete-\(workspaceID.uuidString).json")
        let now = Date(timeIntervalSinceReferenceDate: 31)
        let documentBytes = Data("authoritative workspace".utf8)
        let document = DomainWorkspaceDocument(
            workspaceID: workspaceID,
            fileURL: fileURL,
            documentBytes: documentBytes,
            metadata: DomainWorkspaceMetadata(
                workspaceID: workspaceID,
                schemaVersion: 1,
                name: "Workspace",
                repoPaths: [],
                customStoragePath: nil,
                isSystemWorkspace: false,
                isHiddenInMenus: false,
                isEphemeral: false,
                activeContextID: nil,
                contexts: []
            )
        )
        let revisions = DomainRevisionState(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: revisions,
            savedDigest: document.contentDigest,
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            pendingSave: nil,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let validator = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        let effectiveJournal = try validator.validateSynchronously(
            encoder.encode(journal),
            expectedWorkspaceID: workspaceID,
            expectedFileURL: fileURL
        )
        let catalog = try validator.seedCatalog(
            entries: [.init(workspaceID: workspaceID, fileURL: fileURL)],
            updatedAt: now
        )
        let admission = try beginDomainCommandAdmission(validator: validator)
        defer { admission.close() }
        let envelope = DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            origin: .standalone,
            command: .deleteWorkspace(workspaceID: workspaceID)
        )
        let input = try XCTUnwrap(DomainWorkspaceCommandIdentityInput(envelope))
        let fingerprint: String
        let claim: DomainWorkspaceRustJournal.PreparedExecutionClaim
        switch try admission.acquire(input) {
        case let .claimed(receiptFingerprint, executionClaim):
            fingerprint = receiptFingerprint
            claim = executionClaim
        default:
            return XCTFail("expected an exact delete execution claim")
        }
        let operation = DomainRecordedOperation(
            fingerprint: fingerprint,
            recordedAt: now,
            outcome: DomainCommandOutcome(
                operationID: operationID,
                disposition: .applied,
                before: revisions,
                after: nil,
                catalogRevision: 1,
                resultingDigest: nil
            )
        )
        let transaction = try validator.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalog: catalog,
            effectiveJournal: effectiveJournal,
            document: document,
            expectedWorkingRevision: 0,
            expectedCatalogRevision: 0,
            operation: operation,
            deletedAt: now,
            commandClaim: claim
        )
        defer { transaction.close() }
        switch try transaction.nextDirective() {
        case let .publishCatalog(actionID, _, candidate, logicalExpectedRevision, authorityReceipt):
            XCTAssertEqual(logicalExpectedRevision, 0)
            XCTAssertEqual(authorityReceipt.tombstone.tombstone.operation, operation)
            let permit = try transaction.acquireAuthorityPermit()
            defer { permit.close() }
            guard case let .committed(receipt) = try transaction.report(.success(
                actionID: actionID,
                writtenDigest: candidate.contentDigest
            )) else {
                return XCTFail("delete catalog authority did not commit")
            }
            XCTAssertEqual(receipt.tombstone.tombstone.operation, operation)
        default:
            return XCTFail("expected the delete catalog-authority action")
        }

        let warnings = ["revision sidecar: denied", "workspace document: busy"]
        let firstPlan = try transaction.planCleanup(cleanupWarnings: warnings)
        let repeatedPlan = try transaction.planCleanup(cleanupWarnings: warnings)
        XCTAssertEqual(firstPlan.canonicalBytes, repeatedPlan.canonicalBytes)
        XCTAssertEqual(
            firstPlan.tombstone.operation.diagnostic,
            "artifact_cleanup_incomplete: \(warnings.joined(separator: "; "))"
        )
        let finalized = transaction.finishCommandAuthority(cleanupWarnings: warnings)
        XCTAssertEqual(
            finalized.authorityFinalization.commandFinalization,
            .reconciled,
            String(describing: finalized)
        )
        let commandResult = try XCTUnwrap(
            finalized.authorityFinalization.commandResult,
            String(describing: finalized)
        )
        XCTAssertEqual(commandResult.workspaceID, workspaceID)
        XCTAssertEqual(commandResult.operation.operationID, operationID)
        XCTAssertEqual(commandResult.operation.fingerprint, fingerprint)
        XCTAssertEqual(commandResult.disposition, .deleted)
        XCTAssertEqual(commandResult.before, revisions)
        XCTAssertNil(commandResult.after)
        XCTAssertEqual(commandResult.catalogRevision, 1)
        XCTAssertEqual(commandResult.publicationKind, .workspaceDeleted)
        XCTAssertNil(commandResult.contextID)
        XCTAssertEqual(finalized.authorityFinalization.authorityPublication?.catalogRevision, 1)
        XCTAssertEqual(finalized.tombstone?.canonicalBytes, firstPlan.canonicalBytes)
        let retryWarnings = ["different retry must not replace the first terminal receipt"]
        let repeatedFinalization = transaction.finishCommandAuthority(cleanupWarnings: retryWarnings)
        XCTAssertEqual(
            repeatedFinalization.authorityFinalization.commandFinalization,
            .reconciled
        )
        XCTAssertEqual(
            repeatedFinalization.authorityFinalization.authorityPublication,
            finalized.authorityFinalization.authorityPublication
        )
        XCTAssertEqual(
            repeatedFinalization.authorityFinalization.commandResult,
            finalized.authorityFinalization.commandResult
        )
        XCTAssertEqual(repeatedFinalization.tombstone?.canonicalBytes, firstPlan.canonicalBytes)

        switch try admission.acquire(input) {
        case let .replay(replayFingerprint, scope, replayOperation):
            XCTAssertEqual(replayFingerprint, fingerprint)
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(replayOperation, firstPlan.tombstone.operation)
        default:
            XCTFail("finalized delete cleanup must replay through the exact amended receipt")
        }
    }

    func testPreparedValidatorSeedsAndValidatesRustOwnedCatalog() async throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Catalog-\(workspaceID.uuidString).json")
        let seedTime = Date(timeIntervalSinceReferenceDate: 30)
        let entries: [DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry] = [
            .init(workspaceID: workspaceID, fileURL: fileURL)
        ]
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)

        let seed = try prepared.seedCatalog(entries: entries, updatedAt: seedTime)
        let repeated = try prepared.seedCatalog(entries: entries, updatedAt: seedTime)
        XCTAssertEqual(seed.catalog.revision, 0)
        XCTAssertEqual(seed.catalog.entries, entries)
        XCTAssertEqual(seed.catalog.deletions, [])
        XCTAssertEqual(seed.canonicalBytes, repeated.canonicalBytes)
        XCTAssertEqual(seed.contentDigest, repeated.contentDigest)
        XCTAssertEqual(
            try prepared.validateCatalog(seed.canonicalBytes).catalog,
            seed.catalog
        )
    }

    func testPreparedValidatorFailsClosedAfterItsExactRuntimeStops() async throws {
        let workspaceID = UUID()
        let journal = DomainWorkingJournal(
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/Stopped-\(workspaceID.uuidString).json"),
            revisions: .initial,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 9.5)
        )
        let bytes = try JSONEncoder().encode(journal)
        let service = AgentryCoreService()
        let prepared = try await DomainWorkspaceRustJournal.prepare(coreService: service)
        await service.shutdown()

        XCTAssertThrowsError(try prepared.requireRuntimeAvailability()) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_rust_unavailable")
            )
        }
        XCTAssertThrowsError(try prepared.validateSynchronously(
            bytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: journal.fileURL
        )) { error in
            XCTAssertEqual(
                error as? DomainPersistenceError,
                .writeFailed("working_journal_rust_unavailable")
            )
        }
    }

    func testInvalidAndFutureJournalFailuresRemainTypedWithoutSwiftSemanticFallback() async throws {
        let service = AgentryCoreService()
        defer { Task { await service.shutdown() } }

        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                Data("[]".utf8),
                coreService: service
            )
            XCTFail("invalid journal unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .corruptJournal)
        }

        let future = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "workspaceID": UUID().uuidString,
            "fileURL": "file:///tmp/Workspace.json",
            "revisions": ["workingRevision": 0, "savedRevision": 0],
            "savedDigest": String(repeating: "a", count: 64),
            "contextRevisions": [],
            "contextDigests": [],
            "contextTombstones": [],
            "operations": [],
            "updatedAt": 1.0
        ], options: [.sortedKeys])
        do {
            _ = try await DomainWorkspaceRustJournal.validate(
                future,
                coreService: service
            )
            XCTFail("future journal unexpectedly validated")
        } catch {
            XCTAssertEqual(error as? DomainPersistenceError, .futureJournal(2))
        }
    }

    func testInjectedResolverCannotOverrideProductionRustAdmissionIdentity() async throws {
        let directory = temporaryDirectory(name: "command-identity-authority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityAuthorityResolverScript(steps: [
            .value(String(repeating: "a", count: 64)),
            .value(String(repeating: "b", count: 64))
        ])
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()

        let first = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(first.disposition, .invalid)
        XCTAssertEqual(first.errorCode, .workspaceUnavailable)
        let second = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(second.disposition, .deduplicated)
        XCTAssertEqual(second.errorCode, .workspaceUnavailable)
        let invocationCount = await resolver.invocationCount
        XCTAssertEqual(invocationCount, 2)
        _ = await runtime.shutdown()
    }

    func testRustIdentityFailureDoesNotRecordOperationAndRetryCanProceed() async throws {
        let directory = temporaryDirectory(name: "command-identity-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rustFingerprint = String(repeating: "c", count: 64)
        let resolver = CommandIdentityAuthorityResolverScript(steps: [
            .failure,
            .value(rustFingerprint),
            .value(rustFingerprint)
        ])
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceCommandIdentityResolver: { input in
                try await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()

        let rejected = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(rejected.disposition, .readOnly)
        XCTAssertEqual(rejected.errorCode, .runtimeReadOnlyDegraded)
        XCTAssertEqual(rejected.diagnostic, "workspace_command_identity_rust_unavailable")
        let retried = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(retried.disposition, .invalid)
        XCTAssertEqual(retried.errorCode, .workspaceUnavailable)
        let deduplicated = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(deduplicated.disposition, .deduplicated)
        XCTAssertEqual(deduplicated.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    func testCancellationBeforeAcquireInstallsOperationWideTombstoneAndIsolatesNewIDs() async throws {
        let directory = temporaryDirectory(name: "command-identity-cancelled")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = CommandIdentityAuthorityCancellationResolver()
        let runtime = MCPDomainRuntime(
            configuration: commandIdentityConfiguration(directory: directory),
            workspaceCommandIdentityResolver: { input in
                await resolver.resolve(input)
            }
        )
        try await runtime.start()
        let envelope = commandIdentityEnvelope()
        let cancelledTask = Task { await runtime.workspaceStore.execute(envelope) }
        let resolverStarted = await waitForCommandIdentityResolver { await resolver.hasStarted }
        XCTAssertTrue(resolverStarted)

        cancelledTask.cancel()
        await resolver.release()
        let cancelled = await cancelledTask.value
        XCTAssertEqual(cancelled.disposition, .failed)
        XCTAssertEqual(cancelled.errorCode, .cancelled)
        XCTAssertEqual(cancelled.diagnostic, "workspace_command_identity_cancelled")

        let tombstoned = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(tombstoned.disposition, .failed)
        XCTAssertEqual(tombstoned.errorCode, .cancelled)
        XCTAssertEqual(tombstoned.diagnostic, "workspace_command_identity_cancelled")
        let replayed = await runtime.workspaceStore.execute(envelope)
        XCTAssertEqual(replayed.disposition, .deduplicated)
        XCTAssertEqual(replayed.errorCode, .cancelled)
        XCTAssertEqual(replayed.diagnostic, "workspace_command_identity_cancelled")

        let isolated = await runtime.workspaceStore.execute(commandIdentityEnvelope())
        XCTAssertEqual(isolated.disposition, .invalid)
        XCTAssertEqual(isolated.errorCode, .workspaceUnavailable)
        _ = await runtime.shutdown()
    }

    private func commandIdentityEnvelope() -> DomainWorkspaceCommandEnvelope {
        DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: 1,
            origin: .standalone,
            command: .saveWorkspaceDocument(workspaceID: UUID())
        )
    }

    private func commandIdentityConfiguration(directory: URL) -> DomainRuntimeConfiguration {
        DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: "command-identity-authority-\(UUID().uuidString)",
            storageDirectory: directory,
            eventDirectory: directory.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("Temp", isDirectory: true),
            externalReloadInterval: nil
        )
    }

    private func temporaryDirectory(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitForCommandIdentityResolver(
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private func domainSemanticRecovery(
    validator: DomainWorkspaceRustJournal.PreparedValidator,
    workspaces: [(workspaceID: UUID, fileURL: URL, operations: [DomainRecordedOperation])] = []
) throws -> DomainWorkspaceSemanticFullRecovery {
    let entries = workspaces.map {
        DomainPersistenceCoordinator.RuntimeWorkspaceCatalog.Entry(
            workspaceID: $0.workspaceID,
            fileURL: $0.fileURL
        )
    }
    let catalog = try validator.seedCatalog(
        entries: entries,
        updatedAt: Date(timeIntervalSinceReferenceDate: 0)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let journals = try workspaces.map { workspace in
        let revisions = workspace.operations.last?.after ?? DomainRevisionState(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let journal = DomainWorkingJournal(
            workspaceID: workspace.workspaceID,
            fileURL: workspace.fileURL,
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: revisions.dirtyRevision == nil ? nil : Data(),
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: workspace.operations,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let validation = try validator.validateSynchronously(
            encoder.encode(journal),
            expectedWorkspaceID: workspace.workspaceID,
            expectedFileURL: workspace.fileURL
        )
        return DomainWorkspaceSemanticRecoveryEvidence(
            workspaceID: workspace.workspaceID,
            journal: .present(validation.canonicalBytes),
            savedDocument: .absent,
            savedRevision: .absent
        )
    }
    return DomainWorkspaceSemanticFullRecovery(
        catalogBytes: catalog.canonicalBytes,
        catalogRevision: catalog.catalog.revision,
        catalogDigest: catalog.contentDigest,
        workspaces: journals,
        deletions: []
    )
}

private func beginDomainCommandAdmission(
    validator: DomainWorkspaceRustJournal.PreparedValidator,
    workspaces: [(workspaceID: UUID, fileURL: URL, operations: [DomainRecordedOperation])] = []
) throws -> DomainWorkspaceRustJournal.PreparedCommandAdmission {
    let recovery = try validator.prepareInitialSemanticRecovery(
        domainSemanticRecovery(validator: validator, workspaces: workspaces)
    )
    let preview = try recovery.preview()
    let commit = try recovery.commit(expected: preview)
    return try XCTUnwrap(commit.admission)
}

private enum CommandIdentityAuthorityTestError: Error {
    case projectorFailed
}

private actor CommandIdentityAuthorityCancellationResolver {
    private(set) var hasStarted = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var invocationCount = 0

    func resolve(_: DomainWorkspaceCommandIdentityInput) async -> String {
        invocationCount += 1
        if invocationCount == 1 {
            hasStarted = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return String(repeating: "d", count: 64)
        }
        return String(repeating: "e", count: 64)
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CommandIdentityAuthorityResolverScript {
    enum Step: Sendable {
        case value(String)
        case failure
    }

    private var steps: [Step]
    private(set) var invocationCount = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func resolve(_: DomainWorkspaceCommandIdentityInput) throws -> String {
        invocationCount += 1
        guard !steps.isEmpty else {
            throw CommandIdentityAuthorityTestError.projectorFailed
        }
        switch steps.removeFirst() {
        case let .value(value):
            return value
        case .failure:
            throw CommandIdentityAuthorityTestError.projectorFailed
        }
    }
}
