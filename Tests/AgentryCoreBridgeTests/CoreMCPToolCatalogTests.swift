import AgentryUniFFIRaw
import CryptoKit
import XCTest
@testable import AgentryCoreBridge

final class CoreMCPToolCatalogTests: XCTestCase {
    func testRustOwnedCatalogSnapshotIsOrderedAndValidated() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let snapshot = try await bridge.mcpToolCatalog()

        XCTAssertEqual(snapshot.catalogVersion, 1)
        XCTAssertFalse(snapshot.canonicalCatalogJSON.isEmpty)
        XCTAssertEqual(
            SHA256.hash(data: snapshot.canonicalCatalogJSON)
                .map { String(format: "%02x", $0) }
                .joined(),
            snapshot.digest
        )
        XCTAssertEqual(snapshot.definitionSchemaVersion, 1)
        XCTAssertEqual(snapshot.tools.count, 27)
        XCTAssertEqual(
            snapshot.tools.map(\.name),
            [
                "app_settings", "bind_context", "manage_workspaces", "manage_selection", "file_actions",
                "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context",
                "prompt", "apply_edits", "oracle_utils", "ask_oracle", "oracle_send", "oracle_chat_log",
                "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "agent_run",
                "agent_manage", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"
            ]
        )
        XCTAssertEqual(Set(snapshot.tools.map(\.name)).count, snapshot.tools.count)
        XCTAssertTrue(snapshot.tools.allSatisfy { record in
            record.inputSchemaJSON.contains("\"type\":\"object\"")
        })
        XCTAssertEqual(
            snapshot.tools.first { $0.name == "file_actions" }?.operationPolicy?.aliases,
            [CoreMcpToolAlias(alias: "rename", canonicalOperation: "move")]
        )
        XCTAssertEqual(
            snapshot.tools.first { $0.name == "read_file" }?.registrationScopes,
            ["window", "standalone"]
        )
    }

    func testBridgeRejectsSemanticallyEquivalentNonCanonicalPayloadBytes() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let identity = try await bridge.runtimeIdentity()
        let raw = try await bridge.transport.mcpToolCatalogV1(identity: identity)
        let canonical = String(decoding: raw.canonicalCatalogJson, as: UTF8.self)
        let prefix = "{\"catalog_version\":1,\"definition_schema_version\":1,\"tools\":"
        XCTAssertTrue(canonical.hasPrefix(prefix))
        // Rebuild the top-level object without changing any semantic value. The bridge must still
        // reject it because Rust's exact canonical byte representation is part of the contract.
        let toolsStart = canonical.index(canonical.startIndex, offsetBy: prefix.count)
        let toolsPayload = String(canonical[toolsStart...].dropLast())
        let nonCanonical = "{\"tools\":\(toolsPayload),\"catalog_version\":1,\"definition_schema_version\":1}"
        let nonCanonicalData = Data(nonCanonical.utf8)
        let digest = SHA256.hash(data: nonCanonicalData).map { String(format: "%02x", $0) }.joined()
        let mutated = AgentryUniFFIRaw.CoreMcpToolCatalogV1(
            catalogVersion: raw.catalogVersion,
            definitionSchemaVersion: raw.definitionSchemaVersion,
            digest: digest,
            canonicalCatalogJson: nonCanonicalData,
            tools: raw.tools
        )
        XCTAssertThrowsError(try CoreMcpToolCatalogSnapshot(raw: mutated))
    }

    func testRustOperationIdentityOwnsNormalizationAndAliases() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let renamed = try await bridge.mcpToolOperationIdentity(
            toolName: "file_actions",
            input: .value("RENAME")
        )
        XCTAssertEqual(
            renamed,
            CoreMcpToolOperationIdentity(canonicalTool: "file_actions", normalizedOperation: "move")
        )
        let defaulted = try await bridge.mcpToolOperationIdentity(
            toolName: "manage_selection",
            input: .missing
        )
        XCTAssertEqual(
            defaulted,
            CoreMcpToolOperationIdentity(canonicalTool: "manage_selection", normalizedOperation: "get")
        )
        let exact = try await bridge.mcpToolOperationIdentity(
            toolName: "history",
            input: .value("search")
        )
        XCTAssertEqual(
            exact,
            CoreMcpToolOperationIdentity(canonicalTool: "history", normalizedOperation: "search")
        )
    }
}
