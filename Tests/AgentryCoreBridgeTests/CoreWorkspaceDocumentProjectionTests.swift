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
