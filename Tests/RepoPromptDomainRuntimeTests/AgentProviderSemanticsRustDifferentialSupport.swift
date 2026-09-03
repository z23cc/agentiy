import AgentryCoreBridge
import Foundation
import XCTest

// ADR-0011 P6-c differential harness: Swift oracle copies of the product algorithms vs the
// Rust twins behind `CoreAgentPermissionPolicyEvaluator` / `CoreAgentProviderAcpSemantics` /
// `CoreAgentProviderCodexSemantics`. Any disagreement is a Rust bug (fix in Rust) unless the
// live-oracle suite in RepoPromptTests shows the product Swift drifted — never change product
// Swift from this file.

// MARK: - Seed / size

enum P6CDifferentialConfiguration {
    static let defaultSeed: UInt64 = 0xC6E7_5EED_0000_0006

    static var seed: UInt64 {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6C_DIFFERENTIAL_SEED"],
           let value = UInt64(raw)
        {
            return value
        }
        return defaultSeed
    }

    static var scale: Int {
        if let raw = ProcessInfo.processInfo.environment["AGENTRY_P6C_DIFFERENTIAL_SCALE"],
           let value = Int(raw), value > 0
        {
            return value
        }
        return 1
    }
}

// MARK: - JSON helpers

enum P6CJSON {
    static func object(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func value(at path: [String], in object: [String: Any]) -> Any? {
        var current: Any = object
        for (index, key) in path.enumerated() {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            if index + 1 == path.count { return next }
            current = next
        }
        return nil
    }

    static func collectStrings(object: [String: Any], paths: [[String]]) -> [String] {
        var values: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let raw = value(at: path, in: object) as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                values.append(trimmed)
            }
        }
        return values
    }
}

// MARK: - RepoPrompt tool-name table (MCPIntegrationHelper.repoPromptToolNames)

enum P6CRepoPromptTools {
    static let serverName = "RepoPromptCE"
    static let names: Set<String> = [
        "ask_user", "ask_user_question", "get_file_tree", "file_search", "read_file",
        "get_code_structure", "apply_edits", "file_actions", "manage_selection", "prompt",
        "workspace_context", "ask_oracle", "oracle_send", "oracle_utils", "oracle_chat_log",
        "history", "git", "bind_context", "manage_workspaces", "context_builder",
        "share_thoughts", "wait_for_next_user_instruction", "agent_explore", "agent_run",
        "agent_manage", "set_status", "app_settings",
    ]

    struct Resolution {
        var normalizedName: String
        var canonicalName: String?
        var hasExplicitServerPrefix: Bool
    }

    static func resolve(_ raw: String?) -> Resolution? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var lowered = trimmed.lowercased()
        while lowered.hasPrefix("functions.") {
            lowered.removeFirst("functions.".count)
        }
        let server = serverName.lowercased()
        let prefixes = ["mcp__\(server)__", "mcp_\(server)__", "\(server)__", "\(server)_"]
        var explicit = false
        var normalized = lowered
        for prefix in prefixes where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count))
            explicit = true
            break
        }
        let canonical: String?
        if names.contains(normalized) {
            canonical = (normalized == "ask_user" || normalized == "ask_user_question") ? "ask_user" : normalized
        } else {
            canonical = nil
        }
        return Resolution(
            normalizedName: normalized,
            canonicalName: canonical,
            hasExplicitServerPrefix: explicit && canonical != nil
        )
    }

    static func isToolName(_ raw: String) -> Bool {
        resolve(raw)?.canonicalName != nil
    }

    static func canonical(_ raw: String) -> String? {
        resolve(raw)?.canonicalName
    }

    static func normalized(_ raw: String) -> String {
        resolve(raw)?.normalizedName ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isServerIdentifier(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return false }
        let server = serverName.lowercased()
        return lowered == server || lowered.contains(server)
    }
}

// MARK: - Permission oracle

enum P6CPermissionOracle {
    enum Reason: String {
        case toolPreference
        case repoPromptAutoApproval
        case approvalPolicyNever
        case approvalPolicyUnlessTrusted
        case approvalPolicyAsk
    }

    enum Source: String {
        case topLevelToolName
        case nestedToolName
        case serverIdentifier
    }

    struct AutoMatch: Equatable {
        var source: Source
        var normalizedToolName: String?
        var serverIdentifier: String?
    }

    struct Result: Equatable {
        var disposition: AgentHostToolDispositionV1
        var reason: Reason
        var matchedToolId: String?
        var autoApproval: AutoMatch?
    }

    static func evaluate(
        policy: AgentHostPermissionPolicyV1,
        request: AgentPermissionEvalRequestV1
    ) -> Result {
        let payload = P6CJSON.object(request.requestPayloadJson)
        let auto = matchAutoApproval(requestToolName: request.requestToolName, payload: payload)

        if let matched = matchingPreference(policy.toolPreferences, request: request, auto: auto) {
            switch matched.0.disposition {
            case .allow, .deny, .ask:
                return Result(
                    disposition: matched.0.disposition,
                    reason: .toolPreference,
                    matchedToolId: matched.1,
                    autoApproval: auto
                )
            case .unspecified:
                break
            }
        }

        if auto != nil {
            let toolId = request.toolId.trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(
                disposition: .allow,
                reason: .repoPromptAutoApproval,
                matchedToolId: toolId.isEmpty ? (auto?.normalizedToolName ?? request.requestToolName) : request.toolId,
                autoApproval: auto
            )
        }

        switch policy.approvalPolicy {
        case .never:
            return Result(disposition: .allow, reason: .approvalPolicyNever, matchedToolId: nil, autoApproval: nil)
        case .unlessTrusted where request.providerTrusted:
            return Result(
                disposition: .allow,
                reason: .approvalPolicyUnlessTrusted,
                matchedToolId: nil,
                autoApproval: nil
            )
        case .unlessTrusted, .onRequest, .declineUnattended, .unspecified:
            return Result(disposition: .ask, reason: .approvalPolicyAsk, matchedToolId: nil, autoApproval: nil)
        }
    }

    static func matchAutoApproval(requestToolName: String?, payloadJSON: String) -> AutoMatch? {
        matchAutoApproval(requestToolName: requestToolName, payload: P6CJSON.object(payloadJSON))
    }

    static func matchAutoApproval(requestToolName: String?, payload: [String: Any]) -> AutoMatch? {
        if let requestToolName, P6CRepoPromptTools.isToolName(requestToolName) {
            return AutoMatch(
                source: .topLevelToolName,
                normalizedToolName: P6CRepoPromptTools.normalized(requestToolName),
                serverIdentifier: nil
            )
        }
        if let match = labelMatch(requestToolName) { return match }
        for label in labelCandidates(payload) {
            if let match = labelMatch(label) { return match }
        }
        for toolName in toolNameCandidates(payload) where P6CRepoPromptTools.isToolName(toolName) {
            return AutoMatch(
                source: .nestedToolName,
                normalizedToolName: P6CRepoPromptTools.normalized(toolName),
                serverIdentifier: nil
            )
        }
        if let server = serverIdentifier(in: payload) {
            return AutoMatch(source: .serverIdentifier, normalizedToolName: nil, serverIdentifier: server)
        }
        return nil
    }

    static func canonical(_ result: Result) -> String {
        let auto: String
        if let match = result.autoApproval {
            auto = P6ACanonical.object()
                .string("source", match.source.rawValue)
                .string("normalizedToolName", match.normalizedToolName)
                .string("serverIdentifier", match.serverIdentifier)
                .finish()
        } else {
            auto = "null"
        }
        return P6ACanonical.object()
            .string("disposition", dispositionName(result.disposition))
            .string("reason", result.reason.rawValue)
            .string("matchedToolId", result.matchedToolId)
            .raw("autoApproval", auto)
            .finish()
    }

    private static func dispositionName(_ value: AgentHostToolDispositionV1) -> String {
        switch value {
        case .allow: "allow"
        case .deny: "deny"
        case .ask: "ask"
        case .unspecified: "unspecified"
        }
    }

    private static func matchingPreference(
        _ preferences: [AgentHostToolPreferenceV1],
        request: AgentPermissionEvalRequestV1,
        auto: AutoMatch?
    ) -> (AgentHostToolPreferenceV1, String)? {
        var candidates: [String] = []
        func push(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) { candidates.append(trimmed) }
        }
        push(request.toolId)
        push(request.requestToolName)
        push(auto?.normalizedToolName)
        if let canonical = P6CRepoPromptTools.canonical(request.toolId) { push(canonical) }
        if let name = request.requestToolName, let canonical = P6CRepoPromptTools.canonical(name) {
            push(canonical)
        }
        for preference in preferences {
            let preferenceId = preference.toolId.trimmingCharacters(in: .whitespacesAndNewlines)
            if preferenceId.isEmpty { continue }
            for candidate in candidates where preferenceMatches(preferenceId, candidate) {
                return (preference, preference.toolId)
            }
        }
        return nil
    }

    private static func preferenceMatches(_ preferenceId: String, _ candidate: String) -> Bool {
        if preferenceId == candidate { return true }
        if preferenceId.caseInsensitiveCompare(candidate) == .orderedSame { return true }
        if let left = P6CRepoPromptTools.canonical(preferenceId),
           let right = P6CRepoPromptTools.canonical(candidate)
        {
            return left == right
        }
        return false
    }

    private static func labelMatch(_ rawLabel: String?) -> AutoMatch? {
        guard let label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        let legacy = "(\(P6CRepoPromptTools.serverName) MCP Server)"
        if label.lowercased().contains(legacy.lowercased()) {
            return AutoMatch(
                source: .serverIdentifier,
                normalizedToolName: nil,
                serverIdentifier: P6CRepoPromptTools.serverName
            )
        }
        guard let colon = label.firstIndex(of: ":") else { return nil }
        let serverLabel = label[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let toolLabel = label[label.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPermissionServerLabel(serverLabel), P6CRepoPromptTools.canonical(toolLabel) != nil else {
            return nil
        }
        return AutoMatch(
            source: .serverIdentifier,
            normalizedToolName: P6CRepoPromptTools.normalized(toolLabel),
            serverIdentifier: serverLabel
        )
    }

    private static func isPermissionServerLabel(_ raw: String) -> Bool {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty { return false }
        let server = P6CRepoPromptTools.serverName.lowercased()
        return lowered == server
            || lowered.hasPrefix("\(server)-")
            || lowered.hasPrefix("\(server) ")
            || lowered.contains("\(server) mcp server")
    }

    private static func serverIdentifier(in payload: [String: Any]) -> String? {
        for server in P6CJSON.collectStrings(object: payload, paths: [
            ["server_name"], ["serverName"], ["server"], ["mcp_server"], ["mcpServer"],
            ["rawInput", "server_name"], ["rawInput", "serverName"], ["rawInput", "server"],
            ["rawInput", "mcp_server"], ["rawInput", "mcpServer"], ["serverInfo", "name"],
            ["tool", "server"], ["tool", "server_name"], ["tool", "serverName"],
            ["toolCall", "server"], ["toolCall", "server_name"], ["toolCall", "serverName"],
            ["rawInput", "toolCall", "server"], ["rawInput", "toolCall", "server_name"],
            ["rawInput", "toolCall", "serverName"], ["request", "server"], ["request", "server_name"],
            ["request", "serverName"], ["request", "tool", "server"], ["request", "tool", "server_name"],
            ["request", "tool", "serverName"], ["request", "toolCall", "server"],
            ["request", "toolCall", "server_name"], ["request", "toolCall", "serverName"],
            ["request", "_meta", "connector_name"],
        ]) where P6CRepoPromptTools.isServerIdentifier(server) {
            return server
        }
        return nil
    }

    private static func labelCandidates(_ payload: [String: Any]) -> [String] {
        P6CJSON.collectStrings(object: payload, paths: [
            ["title"], ["toolTitle"], ["tool_title"], ["displayName"], ["display_name"],
            ["rawInput", "title"], ["rawInput", "toolTitle"], ["rawInput", "tool_title"],
            ["toolCall", "title"], ["toolCall", "name"], ["toolCall", "displayName"],
            ["toolCall", "display_name"], ["rawInput", "toolCall", "title"],
            ["rawInput", "toolCall", "name"], ["rawInput", "toolCall", "displayName"],
            ["rawInput", "toolCall", "display_name"], ["request", "title"], ["request", "toolTitle"],
            ["request", "tool_title"], ["request", "toolCall", "title"], ["request", "toolCall", "name"],
            ["request", "toolCall", "displayName"], ["request", "toolCall", "display_name"],
            ["request", "_meta", "tool_title"], ["request", "_meta", "tool_description"],
        ])
    }

    private static func toolNameCandidates(_ payload: [String: Any]) -> [String] {
        var values = P6CJSON.collectStrings(object: payload, paths: [
            ["tool_name"], ["toolName"], ["name"], ["rawInput", "tool_name"], ["rawInput", "toolName"],
            ["rawInput", "name"], ["tool", "tool_name"], ["tool", "toolName"], ["tool", "name"],
            ["toolCall", "tool_name"], ["toolCall", "toolName"], ["toolCall", "name"],
            ["toolCall", "title"], ["rawInput", "tool", "tool_name"], ["rawInput", "tool", "toolName"],
            ["rawInput", "tool", "name"], ["rawInput", "toolCall", "tool_name"],
            ["rawInput", "toolCall", "toolName"], ["rawInput", "toolCall", "name"],
            ["rawInput", "toolCall", "title"], ["request", "tool_name"], ["request", "toolName"],
            ["request", "name"], ["request", "tool", "tool_name"], ["request", "tool", "toolName"],
            ["request", "name"], ["request", "toolCall", "tool_name"], ["request", "toolCall", "toolName"],
            ["request", "toolCall", "name"], ["request", "toolCall", "title"],
            ["request", "_meta", "tool_title"], ["request", "_meta", "tool_description"],
            ["request", "_meta", "connector_name"],
        ])
        if let suggestions = payload["permission_suggestions"] as? [[String: Any]] {
            for suggestion in suggestions {
                guard let rules = suggestion["rules"] as? [[String: Any]] else { continue }
                for rule in rules {
                    if let toolName = P6CJSON.firstString(rule, ["toolName"]),
                       !values.contains(toolName)
                    {
                        values.append(toolName)
                    }
                }
            }
        }
        return values
    }
}

// MARK: - Codex oracle

enum P6CCodexOracle {
    enum ServerRequest: String {
        case requestUserInput
        case authTokensRefresh
        case mcpElicitation
        case permissions
        case dynamicToolUnsupported
        case approval
        case unknownUnsupported
    }

    static func classify(_ method: String) -> ServerRequest? {
        switch method {
        case "item/tool/requestUserInput": .requestUserInput
        case "account/chatgptAuthTokens/refresh": .authTokensRefresh
        case "mcpServer/elicitation/request": .mcpElicitation
        case "item/permissions/requestApproval": .permissions
        case "item/tool/call": .dynamicToolUnsupported
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "applyPatchApproval",
             "execCommandApproval":
            .approval
        default:
            method.lowercased().contains("requestapproval") ? .approval : nil
        }
    }

    static func mapTurnStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "completed": "completed"
        case "interrupted": "interrupted"
        case "failed": "failed"
        default: "completed"
        }
    }

    static func buildApprovalResult(
        decision: AgentHostApprovalDecisionKindV1,
        kind: AgentHostApprovalKindV1,
        amendmentJSON: String?
    ) -> String {
        switch decision {
        case .accept: return #"{"decision":"accept"}"#
        case .decline: return #"{"decision":"decline"}"#
        case .cancel: return #"{"decision":"cancel"}"#
        case .acceptForSession: return #"{"decision":"acceptForSession"}"#
        case .acceptWithExecpolicyAmendment:
            if kind != .commandExecution { return #"{"decision":"decline"}"# }
            if let amendmentJSON,
               let data = amendmentJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(parsed) || parsed is NSNumber || parsed is NSString
                   || parsed is NSNull || parsed is Bool,
               let encoded = try? JSONSerialization.data(withJSONObject: [
                   "decision": [
                       "acceptWithExecpolicyAmendment": ["execpolicy_amendment": parsed],
                   ],
               ] as [String: Any]),
               let string = String(data: encoded, encoding: .utf8)
            {
                // Compact via JSONSerialization is not key-stable vs serde. Named fixtures
                // only compare accept / decline / fallback.
                return string
            }
            return #"{"decision":"acceptForSession"}"#
        case .unspecified: return #"{"decision":"decline"}"#
        }
    }
}

// MARK: - ACP oracle

enum P6CACPOracle {
    static func isAutoSelectable(optionId: String?, provider: AgentProviderAcpProviderIdV1) -> Bool {
        guard let normalized = optionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else { return false }
        if provider == .grokBuild, normalized == "enable-always-approve" { return false }
        return true
    }

    static func stopReason(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "end_turn", "max_tokens", "max_turn_requests": "completed"
        case "cancelled": "cancelled"
        case "refusal": "failed"
        default: "completed"
        }
    }
}

// MARK: - Dual helpers

func p6cPolicy(
    _ approval: AgentHostApprovalPolicyV1,
    preferences: [AgentHostToolPreferenceV1] = []
) -> AgentHostPermissionPolicyV1 {
    AgentHostPermissionPolicyV1(
        approvalPolicy: approval,
        toolPreferences: preferences,
        providerSettings: [],
        interactionTimeoutSeconds: 0
    )
}

func p6cRequest(
    toolId: String,
    toolName: String?,
    payloadJSON: String,
    trusted: Bool = false,
    kind: AgentHostApprovalKindV1 = .commandExecution
) -> AgentPermissionEvalRequestV1 {
    AgentPermissionEvalRequestV1(
        toolId: toolId,
        requestToolName: toolName,
        requestPayloadJson: payloadJSON,
        providerTrusted: trusted,
        kind: kind
    )
}

func p6cAssertPermissionEqual(
    _ rust: AgentPermissionEvalResultV1,
    _ oracle: P6CPermissionOracle.Result,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(rust.disposition, oracle.disposition, "disposition", file: file, line: line)
    XCTAssertEqual(rust.reason.p6cName, oracle.reason.rawValue, "reason", file: file, line: line)
    XCTAssertEqual(rust.matchedToolId, oracle.matchedToolId, "matchedToolId", file: file, line: line)
    XCTAssertEqual(rust.autoApproval?.source.p6cName, oracle.autoApproval?.source.rawValue, file: file, line: line)
    XCTAssertEqual(rust.autoApproval?.normalizedToolName, oracle.autoApproval?.normalizedToolName, file: file, line: line)
    XCTAssertEqual(rust.autoApproval?.serverIdentifier, oracle.autoApproval?.serverIdentifier, file: file, line: line)
    XCTAssertEqual(rust.canonical, P6CPermissionOracle.canonical(oracle), "canonical", file: file, line: line)
}

extension AgentPermissionEvalReasonV1 {
    var p6cName: String {
        switch self {
        case .toolPreference: "toolPreference"
        case .repoPromptAutoApproval: "repoPromptAutoApproval"
        case .approvalPolicyNever: "approvalPolicyNever"
        case .approvalPolicyUnlessTrusted: "approvalPolicyUnlessTrusted"
        case .approvalPolicyAsk: "approvalPolicyAsk"
        }
    }
}

extension AgentRepoPromptAutoApprovalSourceV1 {
    var p6cName: String {
        switch self {
        case .topLevelToolName: "topLevelToolName"
        case .nestedToolName: "nestedToolName"
        case .serverIdentifier: "serverIdentifier"
        }
    }
}

extension AgentProviderCodexServerRequestKindV1 {
    var p6cName: String {
        switch self {
        case .requestUserInput: "requestUserInput"
        case .authTokensRefresh: "authTokensRefresh"
        case .mcpElicitation: "mcpElicitation"
        case .permissions: "permissions"
        case .dynamicToolUnsupported: "dynamicToolUnsupported"
        case .approval: "approval"
        case .unknownUnsupported: "unknownUnsupported"
        }
    }
}
