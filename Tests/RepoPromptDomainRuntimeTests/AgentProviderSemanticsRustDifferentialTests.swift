import AgentryCoreBridge
import Foundation
import XCTest

/// ADR-0011 P6-c (B track) differential harness: named fixtures extracted from existing
/// Codex/ACP/permission tests plus a seeded corpus. Reproduce with
/// `AGENTRY_P6C_DIFFERENTIAL_SEED`; widen with `AGENTRY_P6C_DIFFERENTIAL_SCALE`.
final class AgentProviderSemanticsRustDifferentialTests: XCTestCase {
    private let permission = CoreAgentPermissionPolicyEvaluator()
    private let acp = CoreAgentProviderAcpSemantics()
    private let codex = CoreAgentProviderCodexSemantics()

    // MARK: - Permission named fixtures

    func testNamedRepoPromptTopLevelAutoApproval() throws {
        let payload = #"{"tool_name":"mcp__RepoPromptCE__read_file","tool_use_id":"toolu_read_1","input":{"path":"Sources/App.swift"}}"#
        let request = p6cRequest(
            toolId: "",
            toolName: "mcp__RepoPromptCE__read_file",
            payloadJSON: payload
        )
        let rust = try permission.evaluate(policy: p6cPolicy(.onRequest), request: request)
        let oracle = P6CPermissionOracle.evaluate(policy: p6cPolicy(.onRequest), request: request)
        p6cAssertPermissionEqual(rust, oracle)
        XCTAssertEqual(rust.disposition, .allow)
        XCTAssertEqual(rust.reason, .repoPromptAutoApproval)
        XCTAssertEqual(rust.autoApproval?.normalizedToolName, "read_file")
    }

    func testNamedNestedPermissionSuggestions() throws {
        let payload = #"{"permission_suggestions":[{"rules":[{"toolName":"mcp__RepoPromptCE__read_file"}]}]}"#
        let rust = try permission.matchRepoPromptAutoApproval(requestToolName: "Bash", requestPayloadJSON: payload)
        let oracle = P6CPermissionOracle.matchAutoApproval(requestToolName: "Bash", payloadJSON: payload)
        XCTAssertEqual(rust?.source, .nestedToolName)
        XCTAssertEqual(rust?.normalizedToolName, "read_file")
        XCTAssertEqual(oracle?.source, .nestedToolName)
        XCTAssertEqual(oracle?.normalizedToolName, "read_file")
    }

    func testNamedUnknownBashAsks() throws {
        let payload = #"{"input":{"command":"rm -rf /tmp/example"}}"#
        let request = p6cRequest(toolId: "", toolName: "Bash", payloadJSON: payload)
        let rust = try permission.evaluate(policy: p6cPolicy(.onRequest), request: request)
        p6cAssertPermissionEqual(rust, P6CPermissionOracle.evaluate(policy: p6cPolicy(.onRequest), request: request))
        XCTAssertEqual(rust.disposition, .ask)
        XCTAssertNil(try permission.matchRepoPromptAutoApproval(requestToolName: "Bash", requestPayloadJSON: payload))
    }

    func testNamedToolPreferenceDenyBeatsAutoApproval() throws {
        let payload = #"{"tool_name":"mcp__RepoPromptCE__read_file"}"#
        let policy = p6cPolicy(
            .onRequest,
            preferences: [AgentHostToolPreferenceV1(toolId: "read_file", disposition: .deny)]
        )
        let request = p6cRequest(
            toolId: "read_file",
            toolName: "mcp__RepoPromptCE__read_file",
            payloadJSON: payload
        )
        let rust = try permission.evaluate(policy: policy, request: request)
        p6cAssertPermissionEqual(rust, P6CPermissionOracle.evaluate(policy: policy, request: request))
        XCTAssertEqual(rust.disposition, .deny)
        XCTAssertEqual(rust.reason, .toolPreference)
    }

    func testNamedNeverAllowsAndDeclineUnattendedAsks() throws {
        let request = p6cRequest(toolId: "bash", toolName: "Bash", payloadJSON: "{}")
        let never = try permission.evaluate(policy: p6cPolicy(.never), request: request)
        p6cAssertPermissionEqual(never, P6CPermissionOracle.evaluate(policy: p6cPolicy(.never), request: request))
        XCTAssertEqual(never.disposition, .allow)
        let decline = try permission.evaluate(policy: p6cPolicy(.declineUnattended), request: request)
        p6cAssertPermissionEqual(
            decline,
            P6CPermissionOracle.evaluate(policy: p6cPolicy(.declineUnattended), request: request)
        )
        XCTAssertEqual(decline.disposition, .ask)
    }

    // MARK: - Codex named fixtures

    func testNamedCodexServerRequestClassification() throws {
        let cases: [(String, AgentProviderCodexServerRequestKindV1?)] = [
            ("item/commandExecution/requestApproval", .approval),
            ("item/permissions/requestApproval", .permissions),
            ("foo/RequestApproval", .approval),
            ("session/update", nil),
            ("item/tool/requestUserInput", .requestUserInput),
            ("account/chatgptAuthTokens/refresh", .authTokensRefresh),
            ("mcpServer/elicitation/request", .mcpElicitation),
            ("item/tool/call", .dynamicToolUnsupported),
        ]
        for (method, expected) in cases {
            XCTAssertEqual(try codex.classifyServerRequest(method), expected, method)
            XCTAssertEqual(P6CCodexOracle.classify(method)?.rawValue, expected?.p6cName, method)
        }
    }

    func testNamedCodexTurnStatusUnknownCompletes() throws {
        XCTAssertEqual(try codex.mapTurnStatus("done"), "completed")
        XCTAssertEqual(try codex.mapTurnStatus("interrupted"), "interrupted")
        XCTAssertEqual(try codex.mapTurnStatus("failed"), "failed")
        XCTAssertEqual(P6CCodexOracle.mapTurnStatus("done"), "completed")
    }

    func testNamedCodexCollapseOrder() throws {
        func option(_ raw: String, placeholder: Bool = false, providerDefault: Bool = false) -> AgentProviderCodexModelOptionV1 {
            AgentProviderCodexModelOptionV1(
                rawValue: raw,
                displayName: raw,
                isPlaceholderDefault: placeholder,
                isProviderDefault: providerDefault,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            )
        }
        let collapsed = try codex.collapseModelOptions([
            option("default", placeholder: true),
            option("gpt-5.2-high"),
            option("gpt-5.4-fast-high"),
            option("gpt-5.6-sol-high", providerDefault: true),
            option("gpt-5.4-low"),
            option("gpt-5.6-sol-low"),
            option("gpt-5.4-fast-low"),
        ])
        XCTAssertEqual(
            collapsed.map(\.rawValue),
            ["default", "gpt-5.6-sol", "gpt-5.4", "gpt-5.4-fast", "gpt-5.2"]
        )
        let sol = try XCTUnwrap(collapsed.first { $0.rawValue == "gpt-5.6-sol" })
        XCTAssertEqual(sol.supportedReasoningEfforts, [.low, .high])
        XCTAssertEqual(sol.defaultReasoningEffort, .high)
        XCTAssertTrue(sol.isProviderDefault)
    }

    func testNamedCodexApprovalResult() throws {
        XCTAssertEqual(
            try codex.buildApprovalResult(decision: .accept, kind: .commandExecution, amendmentJSON: nil),
            #"{"decision":"accept"}"#
        )
        XCTAssertEqual(
            try codex.buildApprovalResult(
                decision: .acceptWithExecpolicyAmendment,
                kind: .fileChange,
                amendmentJSON: "{}"
            ),
            #"{"decision":"decline"}"#
        )
        XCTAssertEqual(
            P6CCodexOracle.buildApprovalResult(decision: .accept, kind: .commandExecution, amendmentJSON: nil),
            #"{"decision":"accept"}"#
        )
    }

    func testNamedCodexTurnReducerIsAbsorbing() throws {
        try codex.reset()
        XCTAssertTrue(try codex.applyNotification(
            method: "turn/started",
            paramsJSON: #"{"turn":{"id":"t1"}}"#,
            runId: "run"
        ).isEmpty)
        XCTAssertFalse(try codex.isTerminal())
        let completed = try codex.applyNotification(
            method: "turn/completed",
            paramsJSON: #"{"turn":{"id":"t1","status":"completed"}}"#,
            runId: "run"
        )
        XCTAssertEqual(completed.count, 1)
        XCTAssertTrue(try codex.isTerminal())
        XCTAssertTrue(try codex.applyNotification(
            method: "turn/completed",
            paramsJSON: #"{"turn":{"id":"t1","status":"failed"}}"#,
            runId: "run"
        ).isEmpty)
        XCTAssertTrue(try codex.isTerminal())
    }

    // MARK: - ACP named fixtures (GrokBuildACPEventNormalizerTests)

    func testNamedGrokAgentMessageChunk() throws {
        try acp.reset()
        let events = try acp.normalizeSessionUpdate(
            payloadJSON: #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from grok"}}"#,
            provider: .grokBuild,
            fallbackToolCallId: "fallback",
            runId: "run",
            turnId: "turn"
        )
        XCTAssertEqual(events.count, 1)
        guard case let .stream(stream)? = events.first?.kind else {
            return XCTFail("expected stream")
        }
        XCTAssertEqual(stream.itemType, "content")
        XCTAssertEqual(stream.text, "hello from grok")
    }

    func testNamedGrokThoughtChunk() throws {
        let events = try acp.normalizeSessionUpdate(
            payloadJSON: #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}"#,
            provider: .grokBuild,
            fallbackToolCallId: "fallback",
            runId: "run",
            turnId: "turn"
        )
        guard case let .stream(stream)? = events.first?.kind else {
            return XCTFail("expected stream")
        }
        XCTAssertEqual(stream.itemType, "reasoning")
        XCTAssertEqual(stream.reasoning, "thinking")
    }

    func testNamedGrokTerminalToolUpdate() throws {
        let events = try acp.normalizeSessionUpdate(
            payloadJSON: #"{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed","rawOutput":{"exitCode":0,"stdout":"ok"}}"#,
            provider: .grokBuild,
            fallbackToolCallId: "fallback",
            runId: "run",
            turnId: "turn"
        )
        guard case let .stream(stream)? = events.first?.kind else {
            return XCTFail("expected stream")
        }
        XCTAssertEqual(stream.itemType, "tool_result")
        let json = stream.toolResultJson ?? ""
        XCTAssertTrue(json.contains("acp_status"), json)
        XCTAssertTrue(json.contains("completed"), json)
        XCTAssertTrue(json.contains("success"), json)
        XCTAssertEqual(stream.toolIsError, false)
    }

    func testNamedGrokFailedToolUpdate() throws {
        let events = try acp.normalizeSessionUpdate(
            payloadJSON: #"{"sessionUpdate":"tool_call_update","toolCallId":"call-2","status":"failed","rawOutput":{"exitCode":3}}"#,
            provider: .grokBuild,
            fallbackToolCallId: "fallback",
            runId: "run",
            turnId: "turn"
        )
        guard case let .stream(stream)? = events.first?.kind else {
            return XCTFail("expected stream")
        }
        XCTAssertEqual(stream.toolIsError, true)
        XCTAssertTrue((stream.toolResultJson ?? "").contains("failed"))
    }

    func testNamedGrokIgnoredUpdates() throws {
        for payload in [
            #"{"sessionUpdate":"turn_completed","usage":{"totalTokens":42}}"#,
            #"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact"}]}"#,
            #"{"sessionUpdate":"plan","entries":[]}"#,
        ] {
            XCTAssertTrue(
                try acp.normalizeSessionUpdate(
                    payloadJSON: payload,
                    provider: .grokBuild,
                    fallbackToolCallId: "fallback",
                    runId: "run",
                    turnId: "turn"
                ).isEmpty,
                payload
            )
        }
    }

    func testNamedGrokUsageUpdate() throws {
        let events = try acp.normalizeSessionUpdate(
            payloadJSON: #"{"sessionUpdate":"usage_update","used":1234,"size":500000}"#,
            provider: .grokBuild,
            fallbackToolCallId: "fallback",
            runId: "run",
            turnId: "turn"
        )
        guard case let .stream(stream)? = events.first?.kind else {
            return XCTFail("expected usage")
        }
        XCTAssertEqual(stream.itemType, "usage")
        XCTAssertEqual(stream.contextUsedTokens, 1234)
        XCTAssertEqual(stream.modelContextWindow, 500_000)
    }

    func testNamedGrokOptionDenylistAndStopReason() throws {
        XCTAssertFalse(try acp.isAutoSelectable(optionId: "enable-always-approve", provider: .grokBuild))
        XCTAssertTrue(try acp.isAutoSelectable(optionId: "allow-once", provider: .grokBuild))
        XCTAssertTrue(try acp.isAutoSelectable(optionId: "  Enable-Always-Approve ", provider: .cursor))
        XCTAssertFalse(try acp.isAutoSelectable(optionId: "  Enable-Always-Approve ", provider: .grokBuild))
        XCTAssertEqual(P6CACPOracle.isAutoSelectable(optionId: "enable-always-approve", provider: .grokBuild), false)

        try acp.reset()
        let completed = try acp.applyStopReason("end_turn", runId: "run", turnId: "t1")
        guard case let .turnCompleted(turn)? = completed.kind else {
            return XCTFail("expected turnCompleted")
        }
        XCTAssertEqual(turn.stopReason, "completed")
        XCTAssertTrue(try acp.isTerminal())
        _ = try acp.applyStopReason("cancelled", runId: "run", turnId: "t2")
        XCTAssertTrue(try acp.isTerminal())
        XCTAssertEqual(P6CACPOracle.stopReason("refusal"), "failed")
        XCTAssertEqual(P6CACPOracle.stopReason("cancelled"), "cancelled")
    }

    // MARK: - Seeded corpus

    func testSeededPermissionCorpusAgrees() throws {
        var rng = P6ASplitMix64(seed: P6CDifferentialConfiguration.seed)
        let scale = P6CDifferentialConfiguration.scale
        let tools = [
            "mcp__RepoPromptCE__read_file", "Bash", "read_file", "apply_edits", "unknown_tool", "",
        ]
        let payloads = [
            #"{"tool_name":"mcp__RepoPromptCE__read_file"}"#,
            #"{"permission_suggestions":[{"rules":[{"toolName":"mcp__RepoPromptCE__git"}]}]}"#,
            #"{"input":{"command":"ls"}}"#,
            #"{"server_name":"RepoPromptCE"}"#,
            #"{"title":"RepoPromptCE: read_file"}"#,
            "{}",
        ]
        let policies: [AgentHostApprovalPolicyV1] = [
            .onRequest, .unlessTrusted, .never, .declineUnattended, .unspecified,
        ]
        let dispositions: [AgentHostToolDispositionV1] = [.allow, .deny, .ask]
        var compared = 0
        for _ in 0..<(64 * scale) {
            let policy = p6cPolicy(
                rng.pick(policies),
                preferences: rng.percent(40)
                    ? [AgentHostToolPreferenceV1(toolId: rng.pick(["read_file", "Bash", "git"]), disposition: rng.pick(dispositions))]
                    : []
            )
            let request = p6cRequest(
                toolId: rng.pick(["", "read_file", "bash", "git"]),
                toolName: rng.pick(tools),
                payloadJSON: rng.pick(payloads),
                trusted: rng.percent(50)
            )
            let rust = try permission.evaluate(policy: policy, request: request)
            p6cAssertPermissionEqual(rust, P6CPermissionOracle.evaluate(policy: policy, request: request))
            compared += 1
        }
        XCTAssertEqual(compared, 64 * scale)
    }

    func testSeededCodexClassifyAndAcpPolicyCorpusAgrees() throws {
        var rng = P6ASplitMix64(seed: P6CDifferentialConfiguration.seed &+ 1)
        let scale = P6CDifferentialConfiguration.scale
        let methods = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/requestUserInput",
            "item/tool/call",
            "account/chatgptAuthTokens/refresh",
            "mcpServer/elicitation/request",
            "applyPatchApproval",
            "execCommandApproval",
            "foo/RequestApproval",
            "session/update",
            "turn/started",
        ]
        let statuses = ["completed", "interrupted", "failed", "done", "unknown", ""]
        let optionIds: [String?] = [
            "enable-always-approve", "allow-once", "  Enable-Always-Approve ", "once", nil, "",
        ]
        let providers: [AgentProviderAcpProviderIdV1] = [.grokBuild, .cursor, .openCode]
        var compared = 0
        for _ in 0..<(48 * scale) {
            let method = rng.pick(methods)
            XCTAssertEqual(
                try codex.classifyServerRequest(method)?.p6cName,
                P6CCodexOracle.classify(method)?.rawValue,
                method
            )
            let status = rng.pick(statuses)
            XCTAssertEqual(try codex.mapTurnStatus(status), P6CCodexOracle.mapTurnStatus(status))
            let option = rng.pick(optionIds)
            let provider = rng.pick(providers)
            XCTAssertEqual(
                try acp.isAutoSelectable(optionId: option, provider: provider),
                P6CACPOracle.isAutoSelectable(optionId: option, provider: provider)
            )
            compared += 1
        }
        XCTAssertEqual(compared, 48 * scale)
    }
}
