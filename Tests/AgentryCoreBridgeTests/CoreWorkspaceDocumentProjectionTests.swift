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

    func testRealCoreProvidesPreparedWorkspaceCommandAdmission() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let workspaceID = UUID()
        let operationID = UUID()
        let operation = CoreWorkspaceRecordedOperationV1(
            operationID: operationID,
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
            resultingDigest: String(repeating: "a", count: 64),
            errorCode: nil,
            diagnostic: nil
        )
        let admission = try prepared.beginCommandAdmission(records: [
            .init(workspaceID: workspaceID, operation: operation),
        ])
        defer { admission.close() }

        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: operation.fingerprint
            ),
            .replay(scope: .workspace, operation: operation)
        )
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: String(repeating: "e", count: 64)
            ),
            .collision(scope: .workspace)
        )
        XCTAssertEqual(try admission.diagnostics().globalOperationCount, 1)

        let transient = CoreWorkspaceRecordedOperationV1(
            operationID: UUID(),
            fingerprint: String(repeating: "d", count: 64),
            recordedAt: 43.5,
            disposition: "conflict",
            before: nil,
            after: nil,
            catalogRevision: 7,
            resultingDigest: nil,
            errorCode: "state_conflict",
            diagnostic: "transient"
        )
        _ = try admission.insert(workspaceID: nil, operation: transient)
        let durableReplacement = CoreWorkspaceRecordedOperationV1(
            operationID: UUID(),
            fingerprint: String(repeating: "c", count: 64),
            recordedAt: 44.5,
            disposition: "unchanged",
            before: nil,
            after: nil,
            catalogRevision: 8,
            resultingDigest: nil,
            errorCode: nil,
            diagnostic: nil
        )
        _ = try admission.reconcileDurable([
            .init(workspaceID: workspaceID, operation: durableReplacement),
        ])
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: transient.operationID,
                fingerprint: transient.fingerprint
            ),
            .replay(scope: .global, operation: transient)
        )
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: durableReplacement.operationID,
                fingerprint: durableReplacement.fingerprint
            ),
            .replay(scope: .workspace, operation: durableReplacement)
        )

        _ = try admission.removeWorkspace(workspaceID)
        XCTAssertEqual(
            try admission.decision(
                workspaceID: workspaceID,
                operationID: operationID,
                fingerprint: operation.fingerprint
            ),
            .replay(scope: .global, operation: operation)
        )

        admission.close()
        XCTAssertThrowsError(try admission.diagnostics()) { error in
            XCTAssertEqual(
                error as? CoreWorkspaceWorkingJournalValidationError,
                .invalidTransaction
            )
        }
        _ = try await bridge.close()
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
        let cleanupWarnings = try JSONSerialization.data(
            withJSONObject: ["revision sidecar: denied"],
            options: [.sortedKeys]
        )
        let amendedTombstone = try prepared.amendDeletionTombstoneCleanup(
            authoritativeTombstoneBytes: tombstone.canonicalBytes,
            cleanupWarningsBytes: cleanupWarnings
        )
        XCTAssertThrowsError(try prepared.amendDeletionTombstoneCleanup(
            authoritativeTombstoneBytes: tombstone.canonicalBytes,
            cleanupWarningsBytes: Data("[]".utf8)
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
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
        XCTAssertEqual(amendedTombstone.workspaceID, tombstone.workspaceID)
        XCTAssertEqual(amendedTombstone.operationID, tombstone.operationID)
        XCTAssertEqual(catalog, validatedCatalog)
        XCTAssertEqual(catalog.catalogVersion, 1)
        XCTAssertEqual(catalog.revision, 0)
        XCTAssertEqual(catalog.entryCount, 1)
        XCTAssertEqual(catalog.deletionCount, 0)
        XCTAssertFalse(String(decoding: tombstone.canonicalBytes, as: UTF8.self).contains(
            "artifact_cleanup_incomplete"
        ))
        XCTAssertTrue(String(decoding: amendedTombstone.canonicalBytes, as: UTF8.self).contains(
            "artifact_cleanup_incomplete: revision sidecar: denied"
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
                "fingerprint": String(repeating: "c", count: 64),
                "recordedAt": 41.0,
                "disposition": "applied",
                "catalogRevision": 7
            ]],
            "updatedAt": 41.0,
            "catalogRevision": 7
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let client = try await bridge.computeClient()
        let prepared = try await client.prepareWorkspaceWorkingJournalValidatorV1()
        let effective = try prepared.validate(rawJournal)
        let transaction = try prepared.beginSaveTransaction(
            rawJournalBytes: rawJournal,
            effectiveJournalBytes: effective.canonicalBytes,
            requestBytes: request,
            candidateDocumentBytes: document,
            diskDocumentBytes: nil
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

        _ = try await bridge.close()
        let committedJournal = try transaction.report(.success(
            actionID: 2,
            writtenDigest: documentDigest
        ))
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
            diskDocumentBytes: document
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
            diskDocumentBytes: document
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
                "fingerprint": String(repeating: "c", count: 64),
                "recordedAt": 101.0,
                "disposition": "applied",
                "after": revisions,
                "catalogRevision": 1,
                "resultingDigest": documentDigest
            ],
            "updatedAt": 101.0
        ], options: [.sortedKeys])
        let transaction = try prepared.beginCreateTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            rawJournalBytes: nil,
            effectiveJournalBytes: nil,
            requestBytes: request,
            documentBytes: document
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
                    permit.close()
                    authorityReceipt = try XCTUnwrap(receipt)
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
            documentBytes: document
        )
        defer { recovery.close() }
        switch try recovery.nextDirective() {
        case let .action(actionID, _, .publishCatalog, _, _, _, _, recoveryReceipt):
            XCTAssertEqual(actionID, 1)
            let permit = try recovery.acquireAuthorityPermit()
            permit.close()
            XCTAssertNil(try XCTUnwrap(recoveryReceipt).savedRevision)
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
                "fingerprint": String(repeating: "c", count: 64),
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
            requestBytes: request
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
            requestBytes: request
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
            )
        )) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidOperationLedger)
        }
        let closedTransaction = try prepared.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request
        )
        let closedActionID: UInt64
        let closedDigest: String
        switch try closedTransaction.nextDirective() {
        case let .publishCatalog(actionID, _, _, candidate, _, _):
            closedActionID = actionID
            closedDigest = candidate.contentDigest
        default:
            return XCTFail("expected close-test catalog directive")
        }
        closedTransaction.close()
        XCTAssertThrowsError(try closedTransaction.nextDirective()) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }
        XCTAssertThrowsError(try closedTransaction.report(.success(
            actionID: closedActionID,
            writtenDigest: closedDigest
        ))) {
            XCTAssertEqual($0 as? CoreWorkspaceWorkingJournalValidationError, .invalidTransaction)
        }

        let transaction = try prepared.beginDeleteTransaction(
            rawCatalogBytes: catalog.canonicalBytes,
            effectiveCatalogBytes: catalog.canonicalBytes,
            effectiveJournalBytes: effectiveJournal.canonicalBytes,
            requestBytes: request
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
        XCTAssertThrowsError(try transaction.report(.success(
            actionID: actionID,
            writtenDigest: catalogDigest
        ))) {
            XCTAssertEqual($0 as? CoreTransportError, .runtimeStopped)
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

    func testRealCoreStatefulScopeRetainsImmutableGenerationAcrossMutation() async throws {
        let workspaceID = UUID()
        let scopeID = UUID()
        let before = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "Before"
        ], options: [.sortedKeys])
        let after = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": "After"
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let scope = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)

        let first = try await scope.replaceDocuments(expectedGeneration: 0, documents: [before])
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.generation, 1)
        let snapshot = try await scope.openSnapshot(expectedGeneration: 1)
        let second = try await scope.upsertDocument(expectedGeneration: 1, document: after)
        XCTAssertEqual(second.generation, 2)

        let retiredPage = try await snapshot.page(offset: 0, limit: 1)
        XCTAssertEqual(retiredPage.generation, 1)
        XCTAssertEqual(retiredPage.workspaces.map(\.name), ["Before"])
        let diagnostics = try await scope.diagnostics()
        XCTAssertEqual(diagnostics.generation, 2)
        XCTAssertEqual(diagnostics.openSnapshotHandleCount, 1)

        do {
            _ = try await scope.upsertDocument(expectedGeneration: 1, document: after)
            XCTFail("stale generation unexpectedly committed")
        } catch {
            XCTAssertEqual(
                error as? CoreBridgeError,
                .workspaceProjectionGenerationMismatch(expected: 1, actual: 2)
            )
        }
        await snapshot.close()
        let closedDiagnostics = try await scope.diagnostics()
        XCTAssertEqual(closedDiagnostics.openSnapshotHandleCount, 0)
        await scope.close()
        _ = try await bridge.close()
    }

    func testRealCorePublicationStateAtomicallyTracksCatalogCursorAndBoundedLog() async throws {
        let workspaceID = UUID()
        let scopeID = UUID()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "name": "Published"
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let scope = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        let firstEvent = CoreWorkspaceProjectionPublicationEvent(
            sequence: 5,
            catalogRevision: 9,
            kind: .bootstrapped,
            workspaceID: workspaceID,
            contextID: nil,
            operationID: nil,
            revisions: .init(workingRevision: 2, savedRevision: 1, dirtyRevision: 2)
        )

        let authority = CoreWorkspaceProjectionAuthorityState(
            revisions: .init(workingRevision: 2, savedRevision: 1, dirtyRevision: 2),
            health: .init(kind: .externalConflict, reason: "external_update"),
            contexts: []
        )
        let workspace = CoreWorkspaceProjectionPublishedWorkspace(
            documentBytes: document,
            authority: authority
        )
        let first = try await scope.publishAuthoritative(
            expectedGeneration: 0,
            expectedCatalogRevision: 0,
            expectedPublicationSequence: 0,
            rebased: true,
            workspaces: [workspace],
            event: firstEvent
        )
        XCTAssertEqual(first.generation, 1)
        XCTAssertTrue(first.projectionChanged)
        XCTAssertEqual(first.publicationSequence, 5)
        XCTAssertEqual(first.catalogRevision, 9)
        XCTAssertEqual(first.eventLogFloorSequence, 5)
        XCTAssertEqual(first.eventLogCount, 1)
        let firstSnapshot = try await scope.openSnapshot(expectedGeneration: 1)
        XCTAssertEqual(firstSnapshot.catalogRevision, 9)
        XCTAssertEqual(firstSnapshot.publicationSequence, 5)
        XCTAssertEqual(firstSnapshot.eventLogFloorSequence, 5)
        XCTAssertEqual(firstSnapshot.eventLogCount, 1)

        let firstPage = try await firstSnapshot.page(offset: 0, limit: 1)
        XCTAssertEqual(firstPage.workspaces.first?.authority, authority)

        let second = try await scope.publishAuthoritative(
            expectedGeneration: 1,
            expectedCatalogRevision: 9,
            expectedPublicationSequence: 5,
            rebased: false,
            workspaces: [workspace],
            event: .init(
                sequence: 6,
                catalogRevision: 9,
                kind: .operationDeduplicated,
                workspaceID: workspaceID,
                contextID: nil,
                operationID: UUID(),
                revisions: nil
            )
        )
        XCTAssertEqual(second.generation, 1, "cursor-only publication must not invent a document generation")
        XCTAssertFalse(second.projectionChanged)
        XCTAssertEqual(second.eventLogCount, 2)
        XCTAssertEqual(firstSnapshot.catalogRevision, 9)
        XCTAssertEqual(firstSnapshot.publicationSequence, 5)
        await firstSnapshot.close()
        let secondSnapshot = try await scope.openSnapshot(expectedGeneration: 1)
        XCTAssertEqual(secondSnapshot.catalogRevision, 9)
        XCTAssertEqual(secondSnapshot.publicationSequence, 6)
        XCTAssertEqual(secondSnapshot.eventLogFloorSequence, 5)
        XCTAssertEqual(secondSnapshot.eventLogCount, 2)
        await secondSnapshot.close()
        let diagnostics = try await scope.diagnostics()
        XCTAssertEqual(diagnostics.generation, 1)
        XCTAssertEqual(diagnostics.catalogRevision, 9)
        XCTAssertEqual(diagnostics.publicationSequence, 6)
        XCTAssertEqual(diagnostics.eventLogFloorSequence, 5)
        XCTAssertEqual(diagnostics.eventLogCount, 2)

        do {
            _ = try await scope.publish(
                expectedGeneration: 1,
                expectedCatalogRevision: 9,
                expectedPublicationSequence: 6,
                rebased: false,
                documents: [document],
                event: .init(
                    sequence: 8,
                    catalogRevision: 10,
                    kind: .workspaceCreated,
                    workspaceID: workspaceID,
                    contextID: nil,
                    operationID: nil,
                    revisions: nil
                )
            )
            XCTFail("a publication gap unexpectedly committed")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .invalidArgument)
        }
        let diagnosticsAfterRejectedGap = try await scope.diagnostics()
        XCTAssertEqual(diagnosticsAfterRejectedGap, diagnostics)
        await scope.close()
        _ = try await bridge.close()
    }

    func testRealCoreCheckpointFacadeSupportsExactAndNewEpochRecovery() async throws {
        let scopeID = UUID()
        let workspaceID = UUID()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "name": "Checkpoint"
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let source = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        _ = try await source.publish(
            expectedGeneration: 0,
            expectedCatalogRevision: 0,
            expectedPublicationSequence: 0,
            rebased: true,
            documents: [document],
            event: .init(
                sequence: 5,
                catalogRevision: 7,
                kind: .bootstrapped,
                workspaceID: nil,
                contextID: nil,
                operationID: nil,
                revisions: nil
            )
        )
        let checkpoint = try await source.exportCheckpoint()
        await source.close()

        let exact = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        let exactReceipt = try await exact.restoreCheckpoint(
            checkpoint,
            beginNewPublicationEpoch: false
        )
        XCTAssertEqual(exactReceipt.generation, 1)
        XCTAssertEqual(exactReceipt.workspaceCount, 1)
        XCTAssertEqual(exactReceipt.catalogRevision, 7)
        XCTAssertEqual(exactReceipt.publicationSequence, 5)
        XCTAssertEqual(exactReceipt.eventLogFloorSequence, 5)
        XCTAssertEqual(exactReceipt.eventLogCount, 1)
        XCTAssertFalse(exactReceipt.beganNewPublicationEpoch)
        let reexportedCheckpoint = try await exact.exportCheckpoint()
        XCTAssertEqual(reexportedCheckpoint, checkpoint)
        await exact.close()

        let restarted = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        let restartReceipt = try await restarted.restoreCheckpoint(
            checkpoint,
            beginNewPublicationEpoch: true
        )
        XCTAssertEqual(restartReceipt.generation, 1)
        XCTAssertEqual(restartReceipt.catalogRevision, 0)
        XCTAssertEqual(restartReceipt.publicationSequence, 0)
        XCTAssertEqual(restartReceipt.eventLogFloorSequence, 1)
        XCTAssertEqual(restartReceipt.eventLogCount, 0)
        XCTAssertTrue(restartReceipt.beganNewPublicationEpoch)
        let baseline = try await restarted.publish(
            expectedGeneration: 1,
            expectedCatalogRevision: 0,
            expectedPublicationSequence: 0,
            rebased: true,
            documents: [document],
            event: .init(
                sequence: 1,
                catalogRevision: 7,
                kind: .bootstrapped,
                workspaceID: nil,
                contextID: nil,
                operationID: nil,
                revisions: nil
            )
        )
        XCTAssertFalse(baseline.projectionChanged)
        XCTAssertEqual(baseline.generation, 1)
        XCTAssertEqual(baseline.publicationSequence, 1)
        await restarted.close()
        _ = try await bridge.close()
    }

    func testReopenedScopeRejectsRetiredFacadeAndSnapshotWithoutTouchingFreshIncarnation() async throws {
        let scopeID = UUID()
        let workspaceID = UUID()
        let document = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "name": "Fresh"
        ], options: [.sortedKeys])
        let bridge = try await AgentryCoreBridge.start()
        let retired = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        _ = try await retired.replaceDocuments(expectedGeneration: 0, documents: [document])
        let retiredSnapshot = try await retired.openSnapshot(expectedGeneration: 1)
        await retired.close()

        let fresh = try await CoreWorkspaceProjectionScope.open(bridge: bridge, scopeID: scopeID)
        _ = try await fresh.replaceDocuments(expectedGeneration: 0, documents: [document])
        let freshSnapshot = try await fresh.openSnapshot(expectedGeneration: 1)
        await retiredSnapshot.close()

        let freshPage = try await freshSnapshot.page(offset: 0, limit: 1)
        XCTAssertEqual(freshPage.workspaces.map(\.name), ["Fresh"])
        let diagnostics = try await fresh.diagnostics()
        XCTAssertEqual(diagnostics.generation, 1)
        XCTAssertEqual(diagnostics.openSnapshotHandleCount, 1)
        do {
            _ = try await retired.upsertDocument(expectedGeneration: 1, document: document)
            XCTFail("closed facade unexpectedly mutated the reopened scope")
        } catch {
            XCTAssertEqual(error as? CoreBridgeError, .workspaceProjectionScopeClosed)
        }

        await freshSnapshot.close()
        await fresh.close()
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
    let catalogRevision: UInt64
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
