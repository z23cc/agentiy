import XCTest
@testable import AgentryCoreBridge

final class CoreMCPToolCatalogTests: XCTestCase {
    func testRustOwnedCatalogSnapshotIsOrderedAndValidated() async throws {
        let bridge = try await AgentryCoreBridge.start()
        let snapshot = try await bridge.mcpToolCatalog()

        XCTAssertEqual(snapshot.catalogVersion, 1)
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
}
