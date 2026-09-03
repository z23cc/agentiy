import AgentryCoreBridge
import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// ADR-0011 P6-c live-oracle gate: product Swift (not a copy) vs Rust. Failures are Rust bugs
/// unless the product algorithm itself is wrong — never change Swift behavior here.
final class AgentProviderSemanticsLiveOracleDifferentialTests: XCTestCase {
    private let permission = CoreAgentPermissionPolicyEvaluator()
    private let acp = CoreAgentProviderAcpSemantics()
    private let codex = CoreAgentProviderCodexSemantics()

    func testLiveRepoPromptAutoApprovalMatchesRust() throws {
        let cases: [(String, [String: Any])] = [
            (
                "mcp__RepoPromptCE__read_file",
                [
                    "tool_name": "mcp__RepoPromptCE__read_file",
                    "tool_use_id": "toolu_read_1",
                    "input": ["path": "Sources/App.swift"]
                ]
            ),
            (
                "Bash",
                ["permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]]
            ),
            (
                "Bash",
                ["input": ["command": "rm -rf /tmp/example"]]
            ),
            (
                "RepoPromptCE: git",
                ["title": "RepoPromptCE: git"]
            )
        ]
        for (toolName, payload) in cases {
            let swift = ClaudeNativeRuntimeHostPolicy.repoPromptPermissionAutoApprovalMatch(
                toolName: toolName,
                requestPayload: payload
            )
            let rust = try permission.matchRepoPromptAutoApproval(
                requestToolName: toolName,
                requestPayloadJSON: Self.jsonString(payload)
            )
            XCTAssertEqual(swift?.source.p6cName, rust?.source.p6cName, "source \(toolName)")
            XCTAssertEqual(swift?.normalizedToolName, rust?.normalizedToolName, "tool \(toolName)")
            XCTAssertEqual(swift?.serverIdentifier, rust?.serverIdentifier, "server \(toolName)")
        }
    }

    func testLiveGrokNormalizerAgreesWithRustOnNamedFixtures() throws {
        let fixtures: [[String: Any]] = [
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hello from grok"]],
            ["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "thinking"]],
            [
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call-1",
                "status": "completed",
                "rawOutput": ["exitCode": 0, "stdout": "ok"]
            ],
            [
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call-2",
                "status": "failed",
                "rawOutput": ["exitCode": 3]
            ],
            ["sessionUpdate": "turn_completed", "usage": ["totalTokens": 42]],
            ["sessionUpdate": "available_commands_update", "availableCommands": [["name": "compact"]]],
            ["sessionUpdate": "plan", "entries": []],
            ["sessionUpdate": "usage_update", "used": 1234, "size": 500_000],
            ["sessionUpdate": "session_info_update", "title": "done"]
        ]
        for payload in fixtures {
            let swiftEvents = GrokBuildACPEventNormalizer.normalize(payload)
            let rustEvents = try acp.normalizeSessionUpdate(
                payloadJSON: Self.jsonString(payload),
                provider: .grokBuild,
                fallbackToolCallId: "fallback",
                runId: "run",
                turnId: "turn"
            )
            XCTAssertEqual(swiftEvents.count, rustEvents.count, "count \(payload)")
            for (swiftEvent, rustEvent) in zip(swiftEvents, rustEvents) {
                switch (swiftEvent, rustEvent.kind) {
                case let (.stream(swiftStream), .stream(rustStream)?):
                    XCTAssertEqual(swiftStream.type, rustStream.itemType, "type \(payload)")
                    XCTAssertEqual(swiftStream.text, rustStream.text, "text \(payload)")
                    XCTAssertEqual(swiftStream.toolIsError, rustStream.toolIsError, "error \(payload)")
                    XCTAssertEqual(
                        swiftStream.contextUsedTokens.map(UInt64.init),
                        rustStream.contextUsedTokens,
                        "used \(payload)"
                    )
                    if let invocation = swiftStream.toolInvocationID {
                        XCTAssertEqual(
                            invocation.uuidString,
                            rustStream.toolInvocationId,
                            "invocation \(payload)"
                        )
                    }
                    if rustStream.itemType == "tool_result" {
                        Self.assertACPStatusParity(
                            swift: swiftStream.toolResultJSON,
                            rust: rustStream.toolResultJson,
                            payload: payload
                        )
                    }
                case (.terminal, _):
                    XCTFail("Swift emitted terminal for \(payload)")
                default:
                    XCTFail("kind mismatch for \(payload): \(swiftEvent) vs \(String(describing: rustEvent.kind))")
                }
            }
        }
    }

    func testLiveACPOptionPolicyAgreesWithRust() throws {
        let optionIds: [String?] = [
            "enable-always-approve", "allow-once", "  Enable-Always-Approve ", "once", nil, ""
        ]
        for optionId in optionIds {
            XCTAssertEqual(
                ACPPermissionOptionPolicy.isAutoSelectable(optionID: optionId, for: .grokBuild),
                try acp.isAutoSelectable(optionId: optionId, provider: .grokBuild),
                String(describing: optionId)
            )
            XCTAssertEqual(
                ACPPermissionOptionPolicy.isAutoSelectable(optionID: optionId, for: .cursor),
                try acp.isAutoSelectable(optionId: optionId, provider: .cursor),
                String(describing: optionId)
            )
        }
    }

    @MainActor
    func testLiveCodexCollapseAgreesWithRust() throws {
        let swift = CodexAgentModeCoordinator.test_collapseCodexModelOptions([
            AgentModelOption(
                rawValue: AgentModel.defaultModel.rawValue,
                displayName: AgentModel.defaultModel.displayName,
                description: nil,
                isPlaceholderDefault: true,
                isProviderDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
            Self.modelOption("gpt-5.2-high"),
            Self.modelOption("gpt-5.4-fast-high"),
            AgentModelOption(
                rawValue: "gpt-5.6-sol-high",
                displayName: "GPT-5.6 Sol High",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
            Self.modelOption("gpt-5.4-low"),
            Self.modelOption("gpt-5.6-sol-low"),
            Self.modelOption("gpt-5.4-fast-low")
        ])
        let rust = try codex.collapseModelOptions([
            AgentProviderCodexModelOptionV1(
                rawValue: AgentModel.defaultModel.rawValue,
                displayName: AgentModel.defaultModel.displayName,
                isPlaceholderDefault: true,
                isProviderDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
            Self.rustOption("gpt-5.2-high"),
            Self.rustOption("gpt-5.4-fast-high"),
            AgentProviderCodexModelOptionV1(
                rawValue: "gpt-5.6-sol-high",
                displayName: "GPT-5.6 Sol High",
                isPlaceholderDefault: false,
                isProviderDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
            Self.rustOption("gpt-5.4-low"),
            Self.rustOption("gpt-5.6-sol-low"),
            Self.rustOption("gpt-5.4-fast-low")
        ])
        XCTAssertEqual(swift.map(\.rawValue), rust.map(\.rawValue))
        XCTAssertEqual(swift.map(\.isProviderDefault), rust.map(\.isProviderDefault))
        XCTAssertEqual(
            swift.map { $0.supportedReasoningEfforts.map(\.p6cEffort) },
            rust.map(\.supportedReasoningEfforts)
        )
        XCTAssertEqual(
            swift.map(\.defaultReasoningEffort?.p6cEffort),
            rust.map(\.defaultReasoningEffort)
        )
    }

    private static func modelOption(_ raw: String) -> AgentModelOption {
        AgentModelOption(
            rawValue: raw,
            displayName: raw,
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
    }

    private static func rustOption(_ raw: String) -> AgentProviderCodexModelOptionV1 {
        AgentProviderCodexModelOptionV1(
            rawValue: raw,
            displayName: raw,
            isPlaceholderDefault: false,
            isProviderDefault: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private static func assertACPStatusParity(swift: String?, rust: String?, payload: [String: Any]) {
        func status(in raw: String?) -> (String?, String?) {
            guard let raw, let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return (nil, nil)
            }
            return (object["status"] as? String, object["acp_status"] as? String)
        }
        let swiftStatus = status(in: swift)
        let rustStatus = status(in: rust)
        XCTAssertEqual(swiftStatus.0, rustStatus.0, "status \(payload)")
        XCTAssertEqual(swiftStatus.1, rustStatus.1, "acp_status \(payload)")
    }
}

private extension MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch.Source {
    var p6cName: String {
        switch self {
        case .topLevelToolName: "topLevelToolName"
        case .nestedToolName: "nestedToolName"
        case .serverIdentifier: "serverIdentifier"
        }
    }
}

private extension AgentRepoPromptAutoApprovalSourceV1 {
    var p6cName: String {
        switch self {
        case .topLevelToolName: "topLevelToolName"
        case .nestedToolName: "nestedToolName"
        case .serverIdentifier: "serverIdentifier"
        }
    }
}

private extension CodexReasoningEffort {
    var p6cEffort: AgentProviderCodexReasoningEffortV1 {
        switch self {
        case .none: AgentProviderCodexReasoningEffortV1.none
        case .minimal: .minimal
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .max: .max
        case .ultra: .ultra
        }
    }
}
