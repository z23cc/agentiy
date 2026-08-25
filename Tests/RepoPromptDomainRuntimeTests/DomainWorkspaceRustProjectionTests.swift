import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceRustProjectionTests: XCTestCase {
    func testRealCoreProjectionMatchesSwiftWorkspaceAndContextReadShape() async throws {
        let workspaceID = UUID()
        let firstContextID = UUID()
        let secondContextID = UUID()
        let agentSessionID = UUID()
        let chatSessionID = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
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
                    "activeChatSessionID": chatSessionID.uuidString,
                    "prompt": "Review this",
                    "selectedPaths": ["Sources/App.swift", "README.md"],
                    "selection": ["legacy-must-not-win"]
                ],
                [
                    "id": secondContextID.uuidString,
                    "name": "Second",
                    "prompt": "Continue",
                    "selection": ["Legacy.swift"]
                ]
            ]
        ], options: [.sortedKeys])
        let swiftDocument = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: URL(fileURLWithPath: "/tmp/workspace.json")
        )

        let rustProjection = try await projectWithOwnedCore(bytes)

        XCTAssertEqual(rustProjection, try swiftProjection(swiftDocument))
        XCTAssertEqual(rustProjection.contexts.map(\.contextID), [firstContextID, secondContextID])
        XCTAssertEqual(rustProjection.contexts[0].selection, ["Sources/App.swift", "README.md"])
        XCTAssertEqual(rustProjection.contexts[1].selection, ["Legacy.swift"])
    }

    func testRealCoreProjectionMatchesSwiftBooleanNSNumberSchemaSemantics() async throws {
        for (schemaValue, expectedVersion) in [(false, 0), (true, 1)] {
            let bytes = try JSONSerialization.data(withJSONObject: [
                "id": UUID().uuidString,
                "schemaVersion": schemaValue
            ], options: [.sortedKeys])
            let swiftDocument = try DomainWorkspaceDocument.decode(
                documentBytes: bytes,
                fileURL: URL(fileURLWithPath: "/tmp/workspace-boolean-schema.json")
            )

            let rustProjection = try await projectWithOwnedCore(bytes)

            XCTAssertEqual(swiftDocument.metadata.schemaVersion, expectedVersion)
            XCTAssertEqual(rustProjection, try swiftProjection(swiftDocument))
        }
    }

    func testRealCoreProjectionMatchesSwiftDefaultsAndWholeArrayFallbacks() async throws {
        let workspaceID = UUID()
        let firstContextID = UUID()
        let secondContextID = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: [
            "id": workspaceID.uuidString,
            "schemaVersion": 1.9,
            "repoPaths": ["/valid", 7],
            "activeComposeTabID": "not-a-uuid",
            "composeTabs": [
                [
                    "id": firstContextID.uuidString,
                    "selectedPaths": ["partial", 7],
                    "selection": ["fallback"]
                ],
                [
                    "id": secondContextID.uuidString,
                    "selectedPaths": ["canonical"],
                    "selection": ["legacy-must-not-win"],
                    "activeAgentSessionID": "invalid"
                ]
            ]
        ], options: [.sortedKeys])
        let swiftDocument = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: URL(fileURLWithPath: "/tmp/workspace-defaults.json")
        )

        let rustProjection = try await projectWithOwnedCore(bytes)

        XCTAssertEqual(rustProjection, try swiftProjection(swiftDocument))
        XCTAssertEqual(rustProjection.schemaVersion, 1)
        XCTAssertEqual(rustProjection.name, "Untitled Workspace")
        XCTAssertTrue(rustProjection.repoPaths.isEmpty)
        XCTAssertNil(rustProjection.activeContextID)
        XCTAssertEqual(rustProjection.contexts[0].selection, ["fallback"])
        XCTAssertEqual(rustProjection.contexts[1].selection, ["canonical"])
    }

    private func projectWithOwnedCore(_ bytes: Data) async throws -> DomainWorkspaceDocumentReadProjection {
        let service = AgentryCoreService()
        do {
            let projection = try await DomainWorkspaceRustProjection.project(
                documentBytes: bytes,
                coreService: service
            )
            await service.shutdown()
            return projection
        } catch {
            await service.shutdown()
            throw error
        }
    }

    private func swiftProjection(
        _ document: DomainWorkspaceDocument
    ) throws -> DomainWorkspaceDocumentReadProjection {
        let metadata = document.metadata
        return DomainWorkspaceDocumentReadProjection(
            workspaceID: metadata.workspaceID,
            schemaVersion: metadata.schemaVersion,
            name: metadata.name,
            repoPaths: metadata.repoPaths,
            activeContextID: metadata.activeContextID,
            contexts: try metadata.contexts.map { context in
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: context.documentBytes) as? [String: Any]
                )
                return DomainWorkspaceContextReadProjection(
                    contextID: context.identity.contextID,
                    name: context.name,
                    activeAgentSessionID: context.activeAgentSessionID,
                    activeChatSessionID: context.activeChatSessionID,
                    prompt: object["prompt"] as? String ?? "",
                    selection: object["selectedPaths"] as? [String]
                        ?? object["selection"] as? [String]
                        ?? []
                )
            }
        )
    }
}
