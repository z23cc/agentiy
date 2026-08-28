import CryptoKit
import Foundation
@testable import AgentryCoreBridge
import XCTest

final class CoreWorkspaceDocumentProjectionTests: XCTestCase {
    func testRealCoreProjectsTypedWorkspaceContextAndSelection() async throws {
        let workspaceID = UUID()
        let firstContextID = UUID()
        let secondContextID = UUID()
        let agentSessionID = UUID()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Workspace",
            "repoPaths": ["/repo/a", "/repo/b"],
            "activeComposeTabID": secondContextID.uuidString,
            "composeTabs": [
                [
                    "id": firstContextID.uuidString,
                    "name": "First",
                    "activeAgentSessionID": agentSessionID.uuidString,
                    "prompt": "Review",
                    "selectedPaths": ["Sources/App.swift", "README.md"]
                ],
                [
                    "id": secondContextID.uuidString,
                    "selection": ["Legacy.swift"]
                ]
            ]
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()

        let projection = try await client.projectWorkspaceDocumentV1(document)

        XCTAssertEqual(projection.workspaceID, workspaceID)
        XCTAssertEqual(projection.schemaVersion, 1)
        XCTAssertEqual(projection.name, "Workspace")
        XCTAssertEqual(projection.repoPaths, ["/repo/a", "/repo/b"])
        XCTAssertEqual(projection.activeContextID, secondContextID)
        XCTAssertEqual(projection.contexts.map(\.contextID), [firstContextID, secondContextID])
        XCTAssertEqual(projection.contexts[0].activeAgentSessionID, agentSessionID)
        XCTAssertEqual(projection.contexts[0].prompt, "Review")
        XCTAssertEqual(projection.contexts[0].selection, ["Sources/App.swift", "README.md"])
        XCTAssertEqual(projection.contexts[1].name, "Untitled")
        XCTAssertEqual(projection.contexts[1].selection, ["Legacy.swift"])
        _ = try await bridge.close()
    }

    func testOversizedDocumentIsRejectedBeforeTransportDispatch() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()
        let oversized = Data(
            repeating: 0,
            count: CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes + 1
        )

        await XCTAssertThrowsCoreErrorAsync {
            try await client.projectWorkspaceDocumentV1(oversized)
        } verify: {
            XCTAssertEqual(
                $0 as? CoreComputeError,
                .invalidRequest(
                    "workspace document exceeds \(CoreWorkspaceDocumentProjectionV1.maximumDocumentBytes)-byte projection limit"
                )
            )
        }
        XCTAssertFalse(transport.actions.contains("workspace-document-projection-v1"))
        _ = try await bridge.close()
    }

    func testRealCoreComputesTypedWorkspaceCommandIdentity() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let identity = try prepared.commandIdentity(CoreWorkspaceCommandIdentityRequestV1(
            operationID: try XCTUnwrap(UUID(
                uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"
            )),
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: nil,
            expectedContextRevision: nil,
            origin: .appPresentation(windowID: 42),
            commandKind: .create,
            workspaceID: try XCTUnwrap(UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )),
            fileURL: URL(fileURLWithPath: "/tmp/Workspace.json"),
            contentDigest: String(repeating: "f", count: 64),
            acceptExternal: nil,
            protectedAgentIdentities: []
        ))

        XCTAssertEqual(identity.commandKind, .create)
        XCTAssertEqual(
            identity.workspaceID.uuidString,
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        XCTAssertEqual(
            identity.fingerprint,
            "4a06f1cb575766d8be224014ef503c41ccd40d82a94521be142f4746cbd4b9f0"
        )
        _ = try await bridge.close()
    }

    func testRealCoreProvidesClaimBoundWorkspaceCommandAdmission() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let workspaceID = UUID()
        let seededOperation = CoreWorkspaceRecordedOperationV1(
            operationID: UUID(),
            fingerprint: String(repeating: "f", count: 64),
            recordedAt: 42.5,
            disposition: "applied",
            before: nil,
            after: CoreWorkspaceProjectionRevisionState(
                workingRevision: 1,
                savedRevision: 0,
                dirtyRevision: 1
            ),
            catalogRevision: 7,
            resultingDigest: SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined(),
            errorCode: nil,
            diagnostic: nil
        )
        let fileURL = URL(fileURLWithPath: "/tmp/Admission-\(workspaceID).json")
        let admission = try beginCommandAdmission(
            prepared: prepared,
            workspaces: [(workspaceID, fileURL, [seededOperation])]
        )
        defer { admission.close() }
        XCTAssertEqual(try admission.diagnostics().globalOperationCount, 1)

        let transientRequest = CoreWorkspaceCommandIdentityRequestV1(
            operationID: UUID(),
            expectedCatalogRevision: 7,
            expectedWorkspaceRevision: 1,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .save,
            workspaceID: workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )
        let transientIdentity: CoreWorkspaceCommandIdentityV1
        let transientClaim: CoreWorkspaceCommandExecutionClaimV1
        let transientGeneration: UInt64
        switch try admission.acquire(transientRequest) {
        case let .claimed(identity, claim, generation):
            transientIdentity = identity
            transientClaim = claim
            transientGeneration = generation
        default:
            return XCTFail("Expected the first acquisition to claim execution")
        }
        XCTAssertEqual(try transientClaim.checkpoint(), .continueExecution)
        switch try admission.acquire(transientRequest) {
        case let .pending(identity, generation):
            XCTAssertEqual(identity, transientIdentity)
            XCTAssertEqual(generation, transientGeneration)
        default:
            XCTFail("Expected matching concurrent acquisition to remain pending")
        }
        let collisionRequest = CoreWorkspaceCommandIdentityRequestV1(
            operationID: transientRequest.operationID,
            expectedCatalogRevision: transientRequest.expectedCatalogRevision,
            expectedWorkspaceRevision: transientRequest.expectedWorkspaceRevision,
            expectedContextRevision: transientRequest.expectedContextRevision,
            origin: .externalReload,
            commandKind: transientRequest.commandKind,
            workspaceID: transientRequest.workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )
        switch try admission.acquire(collisionRequest) {
        case let .collision(identity, scope):
            XCTAssertNotEqual(identity.fingerprint, transientIdentity.fingerprint)
            XCTAssertNil(scope)
        default:
            XCTFail("Expected an in-flight identity collision")
        }

        let transientOperation = CoreWorkspaceRecordedOperationV1(
            operationID: transientRequest.operationID,
            fingerprint: transientIdentity.fingerprint,
            recordedAt: 43,
            disposition: "conflict",
            before: nil,
            after: nil,
            catalogRevision: 7,
            resultingDigest: nil,
            errorCode: "state_conflict",
            diagnostic: "transient"
        )
        XCTAssertEqual(
            try transientClaim.finalizeTransient(operation: transientOperation),
            transientOperation
        )
        switch try admission.acquire(transientRequest) {
        case let .replay(identity, scope, operation):
            XCTAssertEqual(identity, transientIdentity)
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, transientOperation)
        default:
            XCTFail("Expected transient finalization to replay globally")
        }

        let invalidRequest = CoreWorkspaceCommandIdentityRequestV1(
            operationID: UUID(),
            expectedCatalogRevision: 7,
            expectedWorkspaceRevision: 0,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .create,
            workspaceID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/Invalid-Acquire.json"),
            contentDigest: "invalid-digest",
            acceptExternal: nil,
            protectedAgentIdentities: []
        )
        XCTAssertThrowsError(try admission.acquire(invalidRequest)) { error in
            XCTAssertEqual(error as? CoreWorkspaceWorkingJournalValidationError, .invalidDigest)
        }
        switch try admission.acquire(transientRequest) {
        case .replay:
            break
        default:
            XCTFail("A semantic request error must not close the prepared admission")
        }

        let durableRequest = CoreWorkspaceCommandIdentityRequestV1(
            operationID: UUID(),
            expectedCatalogRevision: 8,
            expectedWorkspaceRevision: 1,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .save,
            workspaceID: workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )
        let durableIdentity: CoreWorkspaceCommandIdentityV1
        let durableClaim: CoreWorkspaceCommandExecutionClaimV1
        switch try admission.acquire(durableRequest) {
        case let .claimed(identity, claim, _):
            durableIdentity = identity
            durableClaim = claim
        default:
            return XCTFail("Expected durable execution claim")
        }
        let durableOperation = CoreWorkspaceRecordedOperationV1(
            operationID: durableRequest.operationID,
            fingerprint: durableIdentity.fingerprint,
            recordedAt: 44,
            disposition: "unchanged",
            before: nil,
            after: nil,
            catalogRevision: 8,
            resultingDigest: nil,
            errorCode: nil,
            diagnostic: nil
        )
        let durableRecovery = try semanticRecovery(
            prepared: prepared,
            workspaces: [(workspaceID, fileURL, [durableOperation])]
        )
        let durableEvidence = try XCTUnwrap(durableRecovery.workspaces.first)
        let targetRecovery = try admission.prepareSemanticTargetRecovery(.init(
            catalogBytes: durableRecovery.catalogBytes,
            workspaceID: workspaceID,
            journal: durableEvidence.journal,
            savedDocument: durableEvidence.savedDocument,
            savedRevision: durableEvidence.savedRevision,
            deletionSidecar: .absent
        ))
        let targetPreview = try targetRecovery.preview()
        let targetCommit = try targetRecovery.commit()
        XCTAssertEqual(targetCommit.targetWorkspaceID, workspaceID)
        XCTAssertEqual(targetCommit.projectionDigest, targetPreview.projectionDigest)
        XCTAssertFalse(try durableClaim.abandon())
        switch try admission.acquire(durableRequest) {
        case let .replay(identity, scope, operation):
            XCTAssertEqual(identity, durableIdentity)
            XCTAssertEqual(scope, .workspace)
            XCTAssertEqual(operation, durableOperation)
        default:
            XCTFail("Expected reconciled durable receipt to replay in workspace scope")
        }

        let fullRecovery = try admission.prepareSemanticFullRecovery(durableRecovery)
        let fullPreview = try fullRecovery.preview()
        let fullCommit = try fullRecovery.commit()
        XCTAssertEqual(fullCommit.projectionDigest, fullPreview.projectionDigest)
        let reconciled = try XCTUnwrap(fullCommit.admissionReceipt)
        XCTAssertEqual(reconciled.diagnostics.globalOperationCount, 3)
        XCTAssertEqual(reconciled.diagnostics.workspaceOperationCount, 1)
        let emptyRecovery = try semanticRecovery(
            prepared: prepared,
            workspaces: [(workspaceID, fileURL, [])]
        )
        let emptyEvidence = try XCTUnwrap(emptyRecovery.workspaces.first)
        let emptyTargetRecovery = try admission.prepareSemanticTargetRecovery(.init(
            catalogBytes: emptyRecovery.catalogBytes,
            workspaceID: workspaceID,
            journal: emptyEvidence.journal,
            savedDocument: emptyEvidence.savedDocument,
            savedRevision: emptyEvidence.savedRevision,
            deletionSidecar: .absent
        ))
        _ = try emptyTargetRecovery.preview()
        _ = try emptyTargetRecovery.commit()
        switch try admission.acquire(durableRequest) {
        case let .replay(_, scope, operation):
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, durableOperation)
        default:
            XCTFail("Removing a workspace index must retain the global replay receipt")
        }

        admission.close()
        XCTAssertThrowsError(try admission.diagnostics()) { error in
            XCTAssertEqual(error as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
        _ = try await bridge.close()
    }

    func testWorkspaceCommandLifecycleMapsCancellationDeadlineAndReplay() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let admission = try beginCommandAdmission(prepared: prepared)
        defer { admission.close() }
        let workspaceID = UUID()
        let operationID = UUID()
        let request = CoreWorkspaceCommandIdentityRequestV1(
            operationID: operationID,
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: nil,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .save,
            workspaceID: workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )

        _ = try admission.cancel(
            OperationID(rawValue: operationID.uuidString.lowercased())
        )
        let cancelledIdentity: CoreWorkspaceCommandIdentityV1
        let cancelledClaim: CoreWorkspaceCommandExecutionClaimV1
        switch try admission.acquire(request) {
        case let .claimed(identity, claim, _):
            cancelledIdentity = identity
            cancelledClaim = claim
        default:
            return XCTFail("A cancel tombstone must materialize an exact stopped claim")
        }
        XCTAssertEqual(try cancelledClaim.checkpoint(), .cancelled)
        let receipt = CoreWorkspaceRecordedOperationV1(
            operationID: operationID,
            fingerprint: cancelledIdentity.fingerprint,
            recordedAt: 45,
            disposition: "failed",
            before: nil,
            after: nil,
            catalogRevision: 0,
            resultingDigest: nil,
            errorCode: "cancelled",
            diagnostic: "workspace_command_identity_cancelled"
        )
        XCTAssertEqual(
            try cancelledClaim.finalizeTransient(operation: receipt),
            receipt
        )
        switch try admission.acquire(request) {
        case let .replay(identity, scope, operation):
            XCTAssertEqual(identity, cancelledIdentity)
            XCTAssertEqual(scope, .global)
            XCTAssertEqual(operation, receipt)
        default:
            XCTFail("A terminal lifecycle stop must replay through the workspace receipt")
        }

        let deadlineRequest = CoreWorkspaceCommandIdentityRequestV1(
            operationID: UUID(),
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: nil,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .save,
            workspaceID: workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )
        XCTAssertThrowsError(
            try admission.acquire(deadlineRequest, deadlineUnixMilliseconds: 1)
        ) { error in
            XCTAssertEqual(error as? CoreBridgeError, .deadlineExpired)
        }
        switch try admission.acquire(deadlineRequest) {
        case let .claimed(_, claim, _):
            XCTAssertTrue(try claim.abandon())
        default:
            XCTFail("An expired lifecycle attachment must roll the workspace claim back")
        }
        _ = try await bridge.close()
    }

    private func acquireCommandExecutionClaim(
        from admission: CorePreparedWorkspaceCommandAdmissionV1,
        request: CoreWorkspaceCommandIdentityRequestV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (CoreWorkspaceCommandIdentityV1, CoreWorkspaceCommandExecutionClaimV1) {
        switch try admission.acquire(request) {
        case let .claimed(identity, claim, _):
            return (identity, claim)
        default:
            XCTFail("Expected a fresh command execution claim", file: file, line: line)
            throw CoreWorkspaceWorkingJournalValidationError.invalidTransaction
        }
    }

    func testRealCoreValidatesFoundationWorkspaceWorkingJournalV1Shape() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let revisions = JournalRevisionFixture(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let journal = JournalFixture(
            version: 1,
            workspaceID: workspaceID,
            fileURL: URL(fileURLWithPath: "/tmp/Workspace.json"),
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [contextID: revisions],
            contextDigests: [contextID: String(repeating: "b", count: 64)],
            contextTombstones: [:],
            operations: [],
            pendingSave: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42.5)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(journal)
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()

        let validated = try await client.validateWorkspaceWorkingJournalV1(bytes)
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let preparedValidated = try await Task.detached {
            try prepared.validate(bytes)
        }.value
        let operationID = UUID()
        let documentDigest = String(repeating: "d", count: 64)
        let savedRevisionRecord = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "workspaceID": workspaceID.uuidString,
            "savedRevision": 1,
            "documentDigest": documentDigest,
            "operationID": operationID.uuidString,
            "updatedAt": 43.0
        ], options: [.sortedKeys])
        let savedRevision = try prepared.validateSavedRevision(savedRevisionRecord)
        let tombstoneRecord = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "workspaceID": workspaceID.uuidString,
            "fileURL": journal.fileURL.absoluteString,
            "operation": [
                "operationID": operationID.uuidString,
                "fingerprint": String(repeating: "c", count: 64),
                "recordedAt": 43.0,
                "disposition": "applied",
                "catalogRevision": 1
            ],
            "deletedAt": 44.0
        ], options: [.sortedKeys])
        let tombstone = try prepared.validateDeletionTombstone(tombstoneRecord)
        let catalogTransition = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "entries": [[
                "workspaceID": workspaceID.uuidString,
                "fileURL": journal.fileURL.absoluteString
            ]],
            "updatedAt": 45.0
        ], options: [.sortedKeys])
        let catalog = try prepared.seedCatalog(seedRequestBytes: catalogTransition)
        let validatedCatalog = try prepared.validateCatalog(catalog.canonicalBytes)
        let nonSeedCatalogRequest = try JSONSerialization.data(withJSONObject: [
            "kind": "upsert",
            "expectedCatalogRevision": 0,
            "workspaceID": workspaceID.uuidString,
            "fileURL": journal.fileURL.absoluteString,
            "updatedAt": 46.0
        ], options: [.sortedKeys])
        XCTAssertThrowsError(try prepared.seedCatalog(seedRequestBytes: nonSeedCatalogRequest)) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }

        XCTAssertEqual(savedRevision.workspaceID, workspaceID)
        XCTAssertEqual(savedRevision.operationID, operationID)
        XCTAssertEqual(tombstone.workspaceID, workspaceID)
        XCTAssertEqual(tombstone.operationID, operationID)
        XCTAssertEqual(catalog, validatedCatalog)
        XCTAssertEqual(catalog.catalogVersion, 1)
        XCTAssertEqual(catalog.revision, 0)
        XCTAssertEqual(catalog.entryCount, 1)
        XCTAssertEqual(catalog.deletionCount, 0)
        XCTAssertFalse(String(decoding: tombstone.canonicalBytes, as: UTF8.self).contains(
            "artifact_cleanup_incomplete"
        ))
        XCTAssertEqual(preparedValidated, validated)
        XCTAssertEqual(validated.workspaceID, workspaceID)
        XCTAssertEqual(validated.journalVersion, 1)
        XCTAssertEqual(validated.contentDigest.count, 64)
        XCTAssertEqual(
            try JSONDecoder().decode(JournalFixture.self, from: validated.canonicalBytes),
            journal
        )
        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        futureObject["version"] = 2
        let futureBytes = try JSONSerialization.data(
            withJSONObject: futureObject,
            options: [.sortedKeys]
        )
        do {
            _ = try await client.validateWorkspaceWorkingJournalV1(futureBytes)
            XCTFail("future journal unexpectedly validated")
        } catch {
            XCTAssertEqual(
                error as? CoreWorkspaceWorkingJournalValidationError,
                .futureSchema(2)
            )
        }
        _ = try await bridge.close()
    }

    func testRealCoreDedicatedWorkingJournalSeedIsDeterministicAndRuntimeFenced() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let seed = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "workspaceID": workspaceID.uuidString,
            "fileURL": "file:///tmp/Workspace.json",
            "revisions": [
                "workingRevision": 0,
                "savedRevision": 0
            ],
            "savedDigest": String(repeating: "a", count: 64),
            "contextDigests": [
                contextID.uuidString,
                String(repeating: "b", count: 64)
            ],
            "updatedAt": 42.0
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()

        let dedicated = try prepared.seedWorkingJournal(seedRequestBytes: seed)
        let repeated = try prepared.seedWorkingJournal(seedRequestBytes: seed)
        XCTAssertEqual(dedicated, repeated)
        XCTAssertEqual(dedicated.workspaceID, workspaceID)
        XCTAssertEqual(dedicated.contentDigest.count, 64)
        XCTAssertThrowsError(try prepared.seedWorkingJournal(seedRequestBytes: Data(
            repeating: 0,
            count: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes + 1
        ))) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .inputTooLarge)
        }

        _ = try await bridge.close()
        XCTAssertThrowsError(try prepared.seedWorkingJournal(seedRequestBytes: seed)) {
            XCTAssertEqual($0 as? CoreTransportError, .runtimeStopped)
        }
    }

    func testRealCoreSaveTransactionRetainsCommitAfterRuntimeStopsAtDocumentAuthority() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let operationID = UUID()
        let revisions = JournalRevisionFixture(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let fileURL = URL(fileURLWithPath: "/tmp/Workspace.json")
        let journal = JournalFixture(
            version: 1,
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [contextID: revisions],
            contextDigests: [contextID: String(repeating: "b", count: 64)],
            contextTombstones: [:],
            operations: [],
            pendingSave: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 40)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawJournal = try encoder.encode(journal)
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Workspace",
            "composeTabs": []
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let effective = try prepared.validate(rawJournal)
        let admission = try beginCommandAdmission(prepared: prepared)
        defer { admission.close() }
        let (commandIdentity, commandClaim) = try acquireCommandExecutionClaim(
            from: admission,
            request: CoreWorkspaceCommandIdentityRequestV1(
                operationID: operationID,
                expectedCatalogRevision: nil,
                expectedWorkspaceRevision: 0,
                expectedContextRevision: nil,
                origin: .standalone,
                commandKind: .save,
                workspaceID: workspaceID,
                fileURL: nil,
                contentDigest: nil,
                acceptExternal: nil,
                protectedAgentIdentities: []
            )
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "expectedWorkspaceID": workspaceID.uuidString,
            "expectedFileURL": fileURL.absoluteString,
            "expectedWorkingRevision": 0,
            "operationID": operationID.uuidString,
            "contextRevisions": [],
            "contextDigests": [],
            "contextTombstones": [],
            "operations": [[
                "operationID": operationID.uuidString,
                "fingerprint": commandIdentity.fingerprint,
                "recordedAt": 41.0,
                "disposition": "applied",
                "catalogRevision": 7
            ]],
            "updatedAt": 41.0,
            "catalogRevision": 7
        ], options: [.sortedKeys])
        XCTAssertThrowsError(try prepared.beginSaveTransaction(
            rawJournalBytes: rawJournal,
            effectiveJournalBytes: effective.canonicalBytes,
            requestBytes: request,
            candidateDocumentBytes: document,
            diskDocumentBytes: nil,
            commandClaim: nil
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
        let transaction = try prepared.beginSaveTransaction(
            rawJournalBytes: rawJournal,
            effectiveJournalBytes: effective.canonicalBytes,
            requestBytes: request,
            candidateDocumentBytes: document,
            diskDocumentBytes: nil,
            commandClaim: commandClaim
        )
        defer { transaction.close() }

        let pendingBytes: Data
        let pendingDigest: String
        switch try transaction.nextDirective() {
        case let .action(
            actionID,
            _,
            .writePendingJournal,
            _,
            bytes,
            digest,
            _,
            nil,
            nil,
            nil
        ):
            XCTAssertEqual(actionID, 1)
            pendingBytes = bytes
            pendingDigest = digest
        default:
            return XCTFail("expected pending-journal directive")
        }
        switch try prepared.resolvePendingSave(
            rawJournalBytes: pendingBytes,
            expectedWorkspaceID: workspaceID,
            expectedFileURL: fileURL,
            documentBytes: document
        ) {
        case let .committed(cleanJournal, documentDigest):
            XCTAssertEqual(cleanJournal.workspaceID, workspaceID)
            XCTAssertEqual(
                documentDigest,
                SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined()
            )
        default:
            XCTFail("matching pending document did not recover")
        }

        let documentDigest: String
        switch try transaction.report(.success(actionID: 1, writtenDigest: pendingDigest)) {
        case let .action(
            actionID,
            _,
            .publishWorkspaceDocument,
            _,
            bytes,
            digest,
            _,
            receipt,
            .pendingJournalRetained,
            nil
        ):
            XCTAssertEqual(actionID, 2)
            XCTAssertEqual(bytes, document)
            XCTAssertEqual(receipt?.workspaceID, workspaceID)
            XCTAssertEqual(receipt?.operationID, operationID)
            XCTAssertEqual(receipt?.catalogRevision, 7)
            documentDigest = digest
        default:
            return XCTFail("expected document-authority directive")
        }

        let authorityPermit = try transaction.acquireAuthorityPermit()
        defer { authorityPermit.close() }
        let closeTask = Task { try await bridge.close() }
        try await Task.sleep(for: .milliseconds(10))
        let committedJournal = try transaction.report(.success(
            actionID: 2,
            writtenDigest: documentDigest
        ))
        authorityPermit.close()
        _ = try await closeTask.value
        let committedActionID: UInt64
        switch committedJournal {
        case let .action(
            actionID,
            _,
            .writeCommittedJournal,
            _,
            _,
            _,
            _,
            _,
            .revisionSidecarMissing,
            .pendingJournalRetained
        ):
            committedActionID = actionID
        default:
            return XCTFail("document authority was lost after runtime shutdown")
        }
        switch try transaction.report(.writeFailed(actionID: committedActionID)) {
        case let .committed(receipt, .pendingJournalRetained):
            XCTAssertEqual(receipt.workspaceID, workspaceID)
            XCTAssertEqual(receipt.documentDigest, documentDigest)
        default:
            XCTFail("post-authority failure became a failed save")
        }
    }

    func testRealCoreJournalMutationTransactionRetainsAuthorityAfterRuntimeStops() async throws {
        let workspaceID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Journal-Mutation-\(workspaceID).json")
        let revisions = JournalRevisionFixture(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let journal = JournalFixture(
            version: 1,
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: [],
            pendingSave: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 50)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawJournal = try encoder.encode(journal)
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Externally Reloaded",
            "composeTabs": []
        ], options: [.sortedKeys])
        let request = try JSONSerialization.data(withJSONObject: [
            "expectedWorkspaceID": workspaceID.uuidString,
            "expectedFileURL": fileURL.absoluteString,
            "catalogRevision": 9,
            "revisionOperationID": operationID.uuidString,
            "transition": [
                "kind": "externalReload",
                "expectedWorkingRevision": 0,
                "newRevision": 1,
                "contextRevisions": [],
                "contextDigests": [],
                "contextTombstones": [],
                "operations": [],
                "updatedAt": 51.0
            ]
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let effective = try prepared.validate(rawJournal)
        let rejected = try prepared.beginJournalMutationTransaction(
            rawJournalBytes: rawJournal,
            effectiveJournalBytes: effective.canonicalBytes,
            requestBytes: request,
            candidateDocumentBytes: document,
            diskDocumentBytes: document,
            commandClaim: nil
        )
        let rejectedActionCandidate: (UInt64, String)? = switch try rejected.nextDirective() {
        case let .action(actionID, _, .writeJournal, _, _, digest, _, _, _, _):
            (actionID, digest)
        default:
            nil
        }
        let rejectedAction = try XCTUnwrap(rejectedActionCandidate)
        let expiredPermit = try rejected.acquireAuthorityPermit()
        expiredPermit.close()
        XCTAssertThrowsError(try rejected.report(.success(
            actionID: rejectedAction.0,
            writtenDigest: rejectedAction.1
        )))
        rejected.close()

        let transaction = try prepared.beginJournalMutationTransaction(
            rawJournalBytes: rawJournal,
            effectiveJournalBytes: effective.canonicalBytes,
            requestBytes: request,
            candidateDocumentBytes: document,
            diskDocumentBytes: document,
            commandClaim: nil
        )
        defer { transaction.close() }

        let journalActionID: UInt64
        let journalDigest: String
        switch try transaction.nextDirective() {
        case let .action(
            actionID,
            _,
            .writeJournal,
            _,
            _,
            digest,
            logicalExpectedRevision,
            receipt,
            postAuthoritySuccessFinalization,
            postAuthorityFailureFinalization
        ):
            XCTAssertEqual(logicalExpectedRevision, 0)
            XCTAssertEqual(postAuthoritySuccessFinalization, .revisionSidecarMissing)
            XCTAssertNil(postAuthorityFailureFinalization)
            XCTAssertEqual(receipt?.workspaceID, workspaceID)
            XCTAssertEqual(receipt?.catalogRevision, 9)
            XCTAssertNotNil(receipt?.savedRevision)
            journalActionID = actionID
            journalDigest = digest
        default:
            return XCTFail("expected journal-authority directive")
        }
        let authorityPermit = try transaction.acquireAuthorityPermit()
        let revisionActionID: UInt64
        switch try transaction.report(.success(
            actionID: journalActionID,
            writtenDigest: journalDigest
        )) {
        case let .action(
            actionID,
            _,
            .writeSavedRevision,
            nil,
            _,
            _,
            nil,
            nil,
            .finalized,
            .revisionSidecarMissing
        ):
            revisionActionID = actionID
        default:
            return XCTFail("expected saved-revision directive")
        }
        authorityPermit.close()

        _ = try await bridge.close()
        switch try transaction.report(.writeFailed(actionID: revisionActionID)) {
        case let .committed(receipt, .revisionSidecarMissing):
            XCTAssertEqual(receipt.workspaceID, workspaceID)
            XCTAssertEqual(receipt.resultingWorkingRevision, 1)
            XCTAssertEqual(receipt.resultingSavedRevision, 1)
        default:
            XCTFail("post-authority sidecar failure became a failed mutation")
        }
    }

    func testRealCoreCreateTransactionOwnsSequenceAndRecoveryPublication() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let operationID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/Create-\(workspaceID).json")
        let context: [String: Any] = [
            "id": contextID.uuidString,
            "name": "Context",
            "prompt": "",
            "selectedPaths": []
        ]
        let contextBytes = try JSONSerialization.data(
            withJSONObject: context,
            options: [.sortedKeys]
        )
        let contextDigest = SHA256.hash(data: contextBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Created",
            "composeTabs": [context]
        ], options: [.sortedKeys])
        let documentDigest = SHA256.hash(data: document)
            .map { String(format: "%02x", $0) }
            .joined()
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let seed = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "entries": [],
            "updatedAt": 100.0
        ], options: [.sortedKeys])
        let catalog = try prepared.seedCatalog(seedRequestBytes: seed)
        let admission = try beginCommandAdmission(prepared: prepared)
        defer { admission.close() }
        let (commandIdentity, commandClaim) = try acquireCommandExecutionClaim(
            from: admission,
            request: CoreWorkspaceCommandIdentityRequestV1(
                operationID: operationID,
                expectedCatalogRevision: 0,
                expectedWorkspaceRevision: nil,
                expectedContextRevision: nil,
                origin: .standalone,
                commandKind: .create,
                workspaceID: workspaceID,
                fileURL: fileURL,
                contentDigest: documentDigest,
                acceptExternal: nil,
                protectedAgentIdentities: []
            )
        )
        let revisions: [String: Any] = [
            "workingRevision": 1,
            "savedRevision": 1
        ]
        let request = try JSONSerialization.data(withJSONObject: [
            "kind": "create",
            "expectedWorkspaceID": workspaceID.uuidString,
            "expectedFileURL": fileURL.absoluteString,
            "expectedCatalogRevision": 0,
            "operationID": operationID.uuidString,
            "contextRevisions": [contextID.uuidString, revisions],
            "contextDigests": [contextID.uuidString, contextDigest],
            "operation": [
                "operationID": operationID.uuidString,
                "fingerprint": commandIdentity.fingerprint,
                "recordedAt": 101.0,
                "disposition": "applied",
                "after": revisions,
                "catalogRevision": 1,
                "resultingDigest": documentDigest
            ],
            "updatedAt": 101.0
        ], options: [.sortedKeys])
        XCTAssertThrowsError(try prepared.beginCreateTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            rawJournalBytes: nil,
            effectiveJournalBytes: nil,
            requestBytes: request,
            documentBytes: document,
            commandClaim: nil
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
        let transaction = try prepared.beginCreateTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            rawJournalBytes: nil,
            effectiveJournalBytes: nil,
            requestBytes: request,
            documentBytes: document,
            commandClaim: commandClaim
        )
        defer { transaction.close() }
        let expectedKinds: [CoreWorkspaceCreateActionKindV1] = [
            .writePendingJournal,
            .publishWorkspaceDocument,
            .writeCommittedJournal,
            .writeSavedRevision,
            .removeDeletionSidecar,
            .publishCatalog
        ]
        var authorityReceipt: CoreWorkspaceCreateCommitReceiptV1?
        for (index, expectedKind) in expectedKinds.enumerated() {
            switch try transaction.nextDirective() {
            case let .action(actionID, _, kind, _, bytes, digest, _, receipt):
                XCTAssertEqual(actionID, UInt64(index + 1))
                XCTAssertEqual(kind, expectedKind)
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), digest)
                if expectedKind == .publishCatalog {
                    let permit = try transaction.acquireAuthorityPermit()
                    XCTAssertThrowsError(try transaction.acquireAuthorityPermit())
                    let attachedReceipt = try XCTUnwrap(receipt)
                    guard case let .committed(committedReceipt) = try transaction.report(.success(
                        actionID: actionID,
                        writtenDigest: digest
                    )) else {
                        permit.close()
                        return XCTFail("catalog authority did not commit create")
                    }
                    permit.close()
                    XCTAssertEqual(committedReceipt, attachedReceipt)
                    authorityReceipt = committedReceipt
                } else {
                    XCTAssertNil(receipt)
                    _ = try transaction.report(.success(
                        actionID: actionID,
                        writtenDigest: digest
                    ))
                }
            default:
                return XCTFail("expected create action \(expectedKind)")
            }
        }
        let receipt = try XCTUnwrap(authorityReceipt)
        XCTAssertEqual(receipt.workspaceID, workspaceID)
        XCTAssertEqual(receipt.operationID, operationID)
        XCTAssertEqual(receipt.documentDigest, documentDigest)
        XCTAssertEqual(receipt.catalog.revision, 1)
        XCTAssertNotNil(receipt.savedRevision)
        XCTAssertEqual(transaction.finishCommandAuthority(), .reconciled)

        let recoveryRequest = try JSONSerialization.data(withJSONObject: [
            "kind": "recover",
            "expectedWorkspaceID": workspaceID.uuidString,
            "expectedFileURL": fileURL.absoluteString,
            "expectedCatalogRevision": 0,
            "updatedAt": 102.0
        ], options: [.sortedKeys])
        let recovery = try prepared.beginCreateTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            rawJournalBytes: receipt.committedJournal.canonicalBytes,
            effectiveJournalBytes: receipt.committedJournal.canonicalBytes,
            requestBytes: recoveryRequest,
            documentBytes: document,
            commandClaim: nil
        )
        defer { recovery.close() }
        switch try recovery.nextDirective() {
        case let .action(actionID, _, .publishCatalog, _, _, digest, _, recoveryReceipt):
            XCTAssertEqual(actionID, 1)
            let permit = try recovery.acquireAuthorityPermit()
            let attachedReceipt = try XCTUnwrap(recoveryReceipt)
            guard case let .committed(committedReceipt) = try recovery.report(.success(
                actionID: actionID,
                writtenDigest: digest
            )) else {
                permit.close()
                return XCTFail("catalog authority did not commit create recovery")
            }
            permit.close()
            XCTAssertEqual(committedReceipt, attachedReceipt)
            XCTAssertNil(committedReceipt.savedRevision)
            XCTAssertEqual(recovery.finishCommandAuthority(), .notApplicable)
        default:
            XCTFail("recovery did not yield the sole catalog action")
        }
    }

    func testRealCoreDeleteTransactionCannotCreateAuthorityAfterRuntimeStops() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let operationID = UUID()
        let revisions = JournalRevisionFixture(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let fileURL = URL(fileURLWithPath: "/tmp/Workspace.json")
        let journal = JournalFixture(
            version: 1,
            workspaceID: workspaceID,
            fileURL: fileURL,
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: nil,
            contextRevisions: [contextID: revisions],
            contextDigests: [contextID: String(repeating: "b", count: 64)],
            contextTombstones: [:],
            operations: [],
            pendingSave: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 40)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rawJournal = try encoder.encode(journal)
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let effectiveJournal = try prepared.validate(rawJournal)
        let admission = try beginCommandAdmission(prepared: prepared)
        defer { admission.close() }
        let (commandIdentity, commandClaim) = try acquireCommandExecutionClaim(
            from: admission,
            request: CoreWorkspaceCommandIdentityRequestV1(
                operationID: operationID,
                expectedCatalogRevision: 0,
                expectedWorkspaceRevision: 0,
                expectedContextRevision: nil,
                origin: .standalone,
                commandKind: .delete,
                workspaceID: workspaceID,
                fileURL: nil,
                contentDigest: nil,
                acceptExternal: nil,
                protectedAgentIdentities: []
            )
        )
        let seed = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "entries": [[
                "workspaceID": workspaceID.uuidString,
                "fileURL": fileURL.absoluteString
            ]],
            "updatedAt": 40.5
        ], options: [.sortedKeys])
        let catalog = try prepared.seedCatalog(seedRequestBytes: seed)
        let request = try JSONSerialization.data(withJSONObject: [
            "expectedWorkspaceID": workspaceID.uuidString,
            "expectedFileURL": fileURL.absoluteString,
            "expectedWorkingRevision": 0,
            "expectedCatalogRevision": 0,
            "operation": [
                "operationID": operationID.uuidString,
                "fingerprint": commandIdentity.fingerprint,
                "recordedAt": 41.0,
                "disposition": "applied",
                "before": [
                    "workingRevision": 0,
                    "savedRevision": 0
                ],
                "catalogRevision": 1
            ],
            "deletedAt": 41.0
        ], options: [.sortedKeys])
        XCTAssertThrowsError(try prepared.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request,
            commandClaim: nil
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
        let emptySeed = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "entries": [],
            "updatedAt": 40.5
        ], options: [.sortedKeys])
        let emptyCatalog = try prepared.seedCatalog(seedRequestBytes: emptySeed)
        XCTAssertThrowsError(try prepared.beginDeleteTransaction(
            rawCatalogBytes: emptyCatalog.canonicalBytes,
            effectiveCatalogBytes: emptyCatalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request,
            commandClaim: commandClaim
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidIdentity)
        }
        let mismatchedURLSeed = try JSONSerialization.data(withJSONObject: [
            "kind": "seed",
            "entries": [[
                "workspaceID": workspaceID.uuidString,
                "fileURL": URL(fileURLWithPath: "/tmp/Other.json").absoluteString
            ]],
            "updatedAt": 40.5
        ], options: [.sortedKeys])
        let mismatchedURLCatalog = try prepared.seedCatalog(seedRequestBytes: mismatchedURLSeed)
        XCTAssertThrowsError(try prepared.beginDeleteTransaction(
            rawCatalogBytes: mismatchedURLCatalog.canonicalBytes,
            effectiveCatalogBytes: mismatchedURLCatalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request,
            commandClaim: commandClaim
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidFileURL)
        }
        var mismatchedRevisionRequest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        var mismatchedOperation = try XCTUnwrap(
            mismatchedRevisionRequest["operation"] as? [String: Any]
        )
        mismatchedOperation["catalogRevision"] = 0
        mismatchedRevisionRequest["operation"] = mismatchedOperation
        XCTAssertThrowsError(try prepared.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: try JSONSerialization.data(
                withJSONObject: mismatchedRevisionRequest,
                options: [.sortedKeys]
            ),
            commandClaim: commandClaim
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidOperationLedger)
        }
        switch try admission.acquire(CoreWorkspaceCommandIdentityRequestV1(
            operationID: operationID,
            expectedCatalogRevision: 0,
            expectedWorkspaceRevision: 0,
            expectedContextRevision: nil,
            origin: .standalone,
            commandKind: .delete,
            workspaceID: workspaceID,
            fileURL: nil,
            contentDigest: nil,
            acceptExternal: nil,
            protectedAgentIdentities: []
        )) {
        case let .pending(identity, _):
            XCTAssertEqual(identity, commandIdentity)
        default:
            return XCTFail("Delete validation attempts consumed or changed the command claim")
        }
        let transaction = try prepared.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request,
            commandClaim: commandClaim
        )
        defer { transaction.close() }

        let actionID: UInt64
        let catalogDigest: String
        let authorityReceipt: CoreWorkspaceDeleteCommitReceiptV1
        switch try transaction.nextDirective() {
        case let .publishCatalog(
            action,
            requestDigest,
            expectedRawDigest,
            candidate,
            logicalExpectedRevision,
            receipt
        ):
            actionID = action
            catalogDigest = candidate.contentDigest
            authorityReceipt = receipt
            XCTAssertEqual(requestDigest, receipt.requestDigest)
            XCTAssertEqual(logicalExpectedRevision, 0)
            XCTAssertEqual(candidate.revision, 1)
            XCTAssertEqual(receipt.workspaceID, workspaceID)
            XCTAssertEqual(receipt.operationID, operationID)
            XCTAssertEqual(receipt.tombstone.workspaceID, workspaceID)
            XCTAssertEqual(
                expectedRawDigest,
                SHA256.hash(data: catalog.canonicalBytes)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        default:
            return XCTFail("expected catalog-authority directive")
        }

        _ = try await bridge.close()
        XCTAssertThrowsError(try transaction.acquireAuthorityPermit()) {
            XCTAssertEqual($0 as? CoreTransportError, .shutdownRequested)
        }
        XCTAssertThrowsError(try transaction.report(.success(
            actionID: actionID,
            writtenDigest: catalogDigest
        ))) {
            XCTAssertEqual($0 as? CoreTransportError, .invalidArgument)
        }
        XCTAssertEqual(authorityReceipt.workspaceID, workspaceID)
        XCTAssertEqual(authorityReceipt.operationID, operationID)
        XCTAssertEqual(authorityReceipt.catalog.revision, 1)
        XCTAssertEqual(authorityReceipt.catalog.contentDigest, catalogDigest)
    }

    func testOversizedWorkingJournalIsRejectedBeforeTransportDispatch() async throws {
        let transport = FakeCoreTransport()
        let bridge = AgentryCoreBridge(transport: transport)
        try await bridge.initialize()
        let client = try await bridge.computeClient()
        let oversized = Data(
            repeating: 0,
            count: CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes + 1
        )

        await XCTAssertThrowsCoreErrorAsync {
            try await client.validateWorkspaceWorkingJournalV1(oversized)
        } verify: {
            XCTAssertEqual(
                $0 as? CoreComputeError,
                .invalidRequest(
                    "workspace journal exceeds \(CoreWorkspaceWorkingJournalValidationV1.maximumJournalBytes)-byte limit"
                )
            )
        }
        XCTAssertFalse(transport.actions.contains("workspace-working-journal-validate-v1"))
        _ = try await bridge.close()
    }

    func testPreparedAdmissionPublishesAndReadsOneAuthorityCursor() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Aggregate",
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": "authoritative",
                "selectedPaths": ["Sources/App.swift"],
            ]],
        ], options: [.sortedKeys])
        let revisions = CoreWorkspaceProjectionRevisionState(
            workingRevision: 1,
            savedRevision: 0,
            dirtyRevision: 1
        )
        let health = CoreWorkspaceProjectionHealth(kind: .writable)
        let published = CoreWorkspaceProjectionPublishedWorkspace(
            documentBytes: document,
            authority: CoreWorkspaceProjectionAuthorityState(
                revisions: revisions,
                health: health,
                contexts: [CoreWorkspaceContextAuthorityState(
                    contextID: contextID,
                    revisions: revisions,
                    health: health
                )]
            )
        )
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let validator = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let admission = try beginCommandAdmission(prepared: validator)

        let emptyRead = try admission.authorityRead(workspaceID: workspaceID)
        XCTAssertNil(emptyRead.projection)
        XCTAssertNil(emptyRead.contentDigest)
        XCTAssertEqual(emptyRead.generation, 0)
        XCTAssertEqual(emptyRead.publicationSequence, 0)
        XCTAssertEqual(emptyRead.eventLogFloorSequence, 1)
        XCTAssertEqual(emptyRead.eventLogCount, 0)
        let emptySynchronization = try admission.synchronizeAuthorityProjection(workspaces: [])
        XCTAssertEqual(emptySynchronization.generation, 0)
        XCTAssertEqual(emptySynchronization.publicationSequence, 0)
        XCTAssertEqual(
            try admission.authorityRead(workspaceID: workspaceID).eventLogFloorSequence,
            1
        )

        let receipt = try admission.publishAuthorityState(
            workspaces: [published],
            draft: CoreWorkspaceAuthorityPublicationDraft(
                catalogRevision: 7,
                kind: .bootstrapped,
                workspaceID: nil,
                contextID: nil,
                operationID: nil,
                revisions: nil
            )
        )
        XCTAssertEqual(receipt.previousGeneration, 0)
        XCTAssertEqual(receipt.generation, 1)
        XCTAssertTrue(receipt.projectionChanged)
        XCTAssertEqual(receipt.publicationSequence, 1)
        XCTAssertEqual(receipt.event.sequence, 1)
        XCTAssertEqual(receipt.event.kind, .bootstrapped)
        XCTAssertEqual(receipt.projectionDigest.count, 64)

        let read = try admission.authorityRead(workspaceID: workspaceID)
        XCTAssertEqual(read.projection?.workspaceID, workspaceID)
        XCTAssertEqual(read.projection?.authority?.revisions, revisions)
        XCTAssertEqual(read.contentDigest, SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(read.generation, receipt.generation)
        XCTAssertEqual(read.catalogRevision, receipt.catalogRevision)
        XCTAssertEqual(read.publicationSequence, receipt.publicationSequence)
        XCTAssertEqual(read.projectionDigest, receipt.projectionDigest)

        let overlayDocument = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Aggregate",
            "composeTabs": [[
                "id": contextID.uuidString,
                "name": "Context",
                "prompt": "routing overlay",
                "selectedPaths": [],
            ]],
        ], options: [.sortedKeys])
        let synchronized = try admission.synchronizeAuthorityProjection(
            workspaces: [CoreWorkspaceProjectionPublishedWorkspace(
                documentBytes: overlayDocument,
                authority: published.authority
            )]
        )
        XCTAssertTrue(synchronized.projectionChanged)
        XCTAssertEqual(synchronized.generation, receipt.generation + 1)
        XCTAssertEqual(synchronized.catalogRevision, receipt.catalogRevision)
        XCTAssertEqual(synchronized.publicationSequence, receipt.publicationSequence)
        let overlayRead = try admission.authorityRead(workspaceID: workspaceID)
        XCTAssertEqual(overlayRead.projection?.contexts.first?.prompt, "routing overlay")
        XCTAssertEqual(overlayRead.publicationSequence, receipt.publicationSequence)

        admission.close()
        XCTAssertThrowsError(try admission.authorityRead(workspaceID: workspaceID))
        _ = try await bridge.close()
    }

    func testRealCoreRejectsInvalidAndDuplicateContextDocuments() async throws {
        let workspaceID = UUID()
        let contextID = UUID()
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        defer { Task { _ = try? await bridge.close() } }
        let invalidTopLevel = Data("[]".utf8)
        let duplicate = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "composeTabs": [
                ["id": contextID.uuidString],
                ["id": contextID.uuidString]
            ]
        ], options: [.sortedKeys])

        for bytes in [invalidTopLevel, duplicate] {
            do {
                _ = try await client.projectWorkspaceDocumentV1(bytes)
                XCTFail("invalid workspace projection unexpectedly succeeded")
            } catch {
                XCTAssertEqual(error as? CoreComputeError, .invalidRequest("invalid compute request"))
            }
        }
    }
}

private func semanticRecovery(
    prepared: CorePreparedWorkspaceWorkingJournalValidatorV1,
    workspaces: [(workspaceID: UUID, fileURL: URL, operations: [CoreWorkspaceRecordedOperationV1])] = []
) throws -> CoreWorkspaceSemanticFullRecoveryV1 {
    let seed = try JSONSerialization.data(withJSONObject: [
        "kind": "seed",
        "entries": workspaces.map { workspace in
            [
                "workspaceID": workspace.workspaceID.uuidString,
                "fileURL": workspace.fileURL.absoluteString,
            ]
        },
        "updatedAt": 0.0,
    ], options: [.sortedKeys])
    let catalog = try prepared.seedCatalog(seedRequestBytes: seed)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let journals = try workspaces.map { workspace in
        let revisions = workspace.operations.last?.after.map {
            JournalRevisionFixture(
                workingRevision: $0.workingRevision,
                savedRevision: $0.savedRevision,
                dirtyRevision: $0.dirtyRevision
            )
        } ?? JournalRevisionFixture(
            workingRevision: 0,
            savedRevision: 0,
            dirtyRevision: nil
        )
        let journal = JournalFixture(
            version: 1,
            workspaceID: workspace.workspaceID,
            fileURL: workspace.fileURL,
            revisions: revisions,
            savedDigest: String(repeating: "a", count: 64),
            workingDocument: revisions.dirtyRevision == nil ? nil : Data(),
            contextRevisions: [:],
            contextDigests: [:],
            contextTombstones: [:],
            operations: workspace.operations.map(JournalOperationFixture.init),
            pendingSave: nil,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        return CoreWorkspaceSemanticRecoveryEvidenceV1(
            workspaceID: workspace.workspaceID,
            journal: .present(try prepared.validate(encoder.encode(journal)).canonicalBytes),
            savedDocument: .absent,
            savedRevision: .absent
        )
    }
    return CoreWorkspaceSemanticFullRecoveryV1(
        catalogBytes: catalog.canonicalBytes,
        workspaces: journals,
        deletions: []
    )
}

private func beginCommandAdmission(
    prepared: CorePreparedWorkspaceWorkingJournalValidatorV1,
    workspaces: [(workspaceID: UUID, fileURL: URL, operations: [CoreWorkspaceRecordedOperationV1])] = []
) throws -> CorePreparedWorkspaceCommandAdmissionV1 {
    let recovery = try prepared.prepareInitialSemanticRecovery(
        semanticRecovery(prepared: prepared, workspaces: workspaces)
    )
    _ = try recovery.preview()
    return try XCTUnwrap(recovery.commit().admission)
}

private struct JournalRevisionFixture: Codable, Equatable {
    let workingRevision: UInt64
    let savedRevision: UInt64
    let dirtyRevision: UInt64?
}

private struct JournalPendingSaveFixture: Codable, Equatable {
    let operationID: UUID
    let documentDigest: String
}

private struct JournalOperationFixture: Codable, Equatable {
    let operationID: UUID
    let fingerprint: String
    let recordedAt: Date
    let disposition: String
    let before: JournalRevisionFixture?
    let after: JournalRevisionFixture?
    let catalogRevision: UInt64
    let resultingDigest: String?
    let errorCode: String?
    let diagnostic: String?

    init(_ operation: CoreWorkspaceRecordedOperationV1) {
        operationID = operation.operationID
        fingerprint = operation.fingerprint
        recordedAt = Date(timeIntervalSinceReferenceDate: operation.recordedAt)
        disposition = operation.disposition
        before = operation.before.map {
            JournalRevisionFixture(
                workingRevision: $0.workingRevision,
                savedRevision: $0.savedRevision,
                dirtyRevision: $0.dirtyRevision
            )
        }
        after = operation.after.map {
            JournalRevisionFixture(
                workingRevision: $0.workingRevision,
                savedRevision: $0.savedRevision,
                dirtyRevision: $0.dirtyRevision
            )
        }
        catalogRevision = operation.catalogRevision
        resultingDigest = operation.resultingDigest
        errorCode = operation.errorCode
        diagnostic = operation.diagnostic
    }
}

private struct JournalFixture: Codable, Equatable {
    let version: Int
    let workspaceID: UUID
    let fileURL: URL
    let revisions: JournalRevisionFixture
    let savedDigest: String
    let workingDocument: Data?
    let contextRevisions: [UUID: JournalRevisionFixture]
    let contextDigests: [UUID: String]
    let contextTombstones: [UUID: UInt64]
    let operations: [JournalOperationFixture]
    let pendingSave: JournalPendingSaveFixture?
    let updatedAt: Date
}
