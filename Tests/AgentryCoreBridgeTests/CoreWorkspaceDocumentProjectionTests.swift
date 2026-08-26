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

        let first = try await scope.publish(
            expectedGeneration: 0,
            expectedCatalogRevision: 0,
            expectedPublicationSequence: 0,
            rebased: true,
            documents: [document],
            event: firstEvent
        )
        XCTAssertEqual(first.generation, 1)
        XCTAssertTrue(first.projectionChanged)
        XCTAssertEqual(first.publicationSequence, 5)
        XCTAssertEqual(first.catalogRevision, 9)
        XCTAssertEqual(first.eventLogFloorSequence, 5)
        XCTAssertEqual(first.eventLogCount, 1)

        let second = try await scope.publish(
            expectedGeneration: 1,
            expectedCatalogRevision: 9,
            expectedPublicationSequence: 5,
            rebased: false,
            documents: [document],
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
