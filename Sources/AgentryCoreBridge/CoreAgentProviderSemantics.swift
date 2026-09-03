import AgentryUniFFIRaw
import Foundation

// ADR-0011 P6-c (B track; design §4.1.1, §5.6, §8 "P6-c"): bridge surface over the Rust
// Codex/ACP protocol-semantics reducers and the MCP permission-policy evaluator
// (`agentry_runtime::agent_provider_semantics`). Same shape as `CoreAgentSessionTranscript.swift`:
// generated `AgentHost*V1` records are already re-exported by `CoreAgentSessionHost.swift`; this
// file re-exports the additive P6-c records/enums and wraps the three objects so callers never
// import `AgentryUniFFIRaw`. Every call is a bounded synchronous pure function / value-state
// transition; time and identities are inputs. GUI and host rewire is a later cutover.

// MARK: - Additive P6-c record re-exports

public typealias AgentPermissionEvalReasonV1 = AgentryUniFFIRaw.AgentPermissionEvalReasonV1
public typealias AgentPermissionEvalRequestV1 = AgentryUniFFIRaw.AgentPermissionEvalRequestV1
public typealias AgentPermissionEvalResultV1 = AgentryUniFFIRaw.AgentPermissionEvalResultV1
public typealias AgentProviderAcpDecisionMappingV1 = AgentryUniFFIRaw.AgentProviderAcpDecisionMappingV1
public typealias AgentProviderAcpPermissionOptionV1 = AgentryUniFFIRaw.AgentProviderAcpPermissionOptionV1
public typealias AgentProviderAcpProviderIdV1 = AgentryUniFFIRaw.AgentProviderAcpProviderIdV1
public typealias AgentProviderCodexModelOptionV1 = AgentryUniFFIRaw.AgentProviderCodexModelOptionV1
public typealias AgentProviderCodexReasoningEffortV1 = AgentryUniFFIRaw.AgentProviderCodexReasoningEffortV1
public typealias AgentProviderCodexSelectionV1 = AgentryUniFFIRaw.AgentProviderCodexSelectionV1
public typealias AgentProviderCodexServerRequestKindV1 = AgentryUniFFIRaw.AgentProviderCodexServerRequestKindV1
public typealias AgentProviderOpenCodeToolProfileV1 = AgentryUniFFIRaw.AgentProviderOpenCodeToolProfileV1
public typealias AgentRepoPromptAutoApprovalMatchV1 = AgentryUniFFIRaw.AgentRepoPromptAutoApprovalMatchV1
public typealias AgentRepoPromptAutoApprovalSourceV1 = AgentryUniFFIRaw.AgentRepoPromptAutoApprovalSourceV1
public typealias AgentProviderCodexLifecycleEventV1 = AgentryUniFFIRaw.AgentProviderCodexLifecycleEventV1
public typealias AgentProviderCodexBashItemV1 = AgentryUniFFIRaw.AgentProviderCodexBashItemV1
public typealias AgentProviderCodexRunningUpdateV1 = AgentryUniFFIRaw.AgentProviderCodexRunningUpdateV1
public typealias AgentProviderCodexRunningApplyV1 = AgentryUniFFIRaw.AgentProviderCodexRunningApplyV1

// MARK: - Permission evaluator

/// `MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch` + proto `PermissionPolicy`
/// evaluation (`AgentPermissionPolicyEvaluatorV1`).
public final class CoreAgentPermissionPolicyEvaluator: Sendable {
    private let raw: AgentPermissionPolicyEvaluatorV1

    public init() {
        raw = AgentPermissionPolicyEvaluatorV1()
    }

    public func evaluate(
        policy: AgentHostPermissionPolicyV1,
        request: AgentPermissionEvalRequestV1
    ) throws -> AgentPermissionEvalResultV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.evaluate(policy: policy, request: request)
        }
    }

    public func matchRepoPromptAutoApproval(
        requestToolName: String?,
        requestPayloadJSON: String
    ) throws -> AgentRepoPromptAutoApprovalMatchV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.matchRepoPromptAutoApproval(
                requestToolName: requestToolName,
                requestPayloadJson: requestPayloadJSON
            )
        }
    }
}

// MARK: - ACP semantics

/// ACP session-update / option-policy / stopReason reducer (`AgentProviderAcpSemanticsV1`).
public final class CoreAgentProviderAcpSemantics: Sendable {
    private let raw: AgentProviderAcpSemanticsV1

    public init() {
        raw = AgentProviderAcpSemanticsV1()
    }

    public func reset() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.reset() }
    }

    public func normalizeSessionUpdate(
        payloadJSON: String,
        provider: AgentProviderAcpProviderIdV1,
        fallbackToolCallId: String,
        runId: String,
        turnId: String,
        openCodeProfile: AgentProviderOpenCodeToolProfileV1 = .agentMode
    ) throws -> [AgentHostRuntimeEventV1] {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.normalizeSessionUpdate(
                payloadJson: payloadJSON,
                provider: provider,
                fallbackToolCallId: fallbackToolCallId,
                runId: runId,
                turnId: turnId,
                openCodeProfile: openCodeProfile
            )
        }
    }

    public func applyStopReason(
        _ stopReason: String?,
        runId: String,
        turnId: String
    ) throws -> AgentHostRuntimeEventV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyStopReason(stopReason: stopReason, runId: runId, turnId: turnId)
        }
    }

    public func isAutoSelectable(
        optionId: String?,
        provider: AgentProviderAcpProviderIdV1
    ) throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.isAutoSelectable(optionId: optionId, provider: provider)
        }
    }

    public func mapApprovalDecision(
        _ decision: AgentHostApprovalDecisionKindV1,
        options: [AgentProviderAcpPermissionOptionV1],
        provider: AgentProviderAcpProviderIdV1
    ) throws -> AgentProviderAcpDecisionMappingV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.mapApprovalDecision(decision: decision, options: options, provider: provider)
        }
    }

    public func autoApprovalOptionId(
        requestToolName: String?,
        payloadJSON: String,
        options: [AgentProviderAcpPermissionOptionV1],
        provider: AgentProviderAcpProviderIdV1
    ) throws -> String? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.autoApprovalOptionId(
                requestToolName: requestToolName,
                payloadJson: payloadJSON,
                options: options,
                provider: provider
            )
        }
    }

    public func approvalKind(forToolKind toolKind: String?) throws -> AgentHostApprovalKindV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.approvalKindForToolKind(toolKind: toolKind)
        }
    }

    public func settleApproval(_ approvalId: String) throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.settleApproval(approvalId: approvalId) }
    }

    public func isTerminal() throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.isTerminal() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Codex semantics

/// Codex notification / approval / model-option / turn reducer (`AgentProviderCodexSemanticsV1`).
public final class CoreAgentProviderCodexSemantics: Sendable {
    private let raw: AgentProviderCodexSemanticsV1

    public init() {
        raw = AgentProviderCodexSemanticsV1()
    }

    public func reset() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.reset() }
    }

    public func applyNotification(
        method: String,
        paramsJSON: String,
        runId: String,
        requestId: String? = nil
    ) throws -> [AgentHostRuntimeEventV1] {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyNotification(
                method: method,
                paramsJson: paramsJSON,
                runId: runId,
                requestId: requestId
            )
        }
    }

    public func classifyServerRequest(_ method: String) throws -> AgentProviderCodexServerRequestKindV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.classifyServerRequest(method: method)
        }
    }

    public func parseApprovalRequest(
        requestId: String,
        method: String,
        paramsJSON: String,
        activeThreadId: String? = nil,
        currentTurnId: String? = nil
    ) throws -> AgentHostApprovalRequestV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.parseApprovalRequest(
                requestId: requestId,
                method: method,
                paramsJson: paramsJSON,
                activeThreadId: activeThreadId,
                currentTurnId: currentTurnId
            )
        }
    }

    public func mapTurnStatus(_ rawStatus: String) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.mapTurnStatus(raw: rawStatus) }
    }

    public func collapseModelOptions(
        _ options: [AgentProviderCodexModelOptionV1]
    ) throws -> [AgentProviderCodexModelOptionV1] {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.collapseModelOptions(options: options)
        }
    }

    public func negotiateSelection(
        selectedModelRaw: String,
        explicitEffort: String?,
        lastUsedEffort: String?,
        supported: [AgentProviderCodexReasoningEffortV1],
        defaultEffort: AgentProviderCodexReasoningEffortV1?,
        preservingExplicitEffort: Bool
    ) throws -> AgentProviderCodexSelectionV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.negotiateSelection(
                selectedModelRaw: selectedModelRaw,
                explicitEffort: explicitEffort,
                lastUsedEffort: lastUsedEffort,
                supported: supported,
                defaultEffort: defaultEffort,
                preservingExplicitEffort: preservingExplicitEffort
            )
        }
    }

    public func buildApprovalResult(
        decision: AgentHostApprovalDecisionKindV1,
        kind: AgentHostApprovalKindV1,
        amendmentJSON: String?
    ) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.buildApprovalResult(decision: decision, kind: kind, amendmentJson: amendmentJSON)
        }
    }

    public func buildPermissionsResult(
        decision: AgentHostApprovalDecisionKindV1,
        permissionsJSON: String
    ) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.buildPermissionsResult(decision: decision, permissionsJson: permissionsJSON)
        }
    }

    public func settleApproval(_ approvalId: String) throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.settleApproval(approvalId: approvalId) }
    }

    public func isTerminal() throws -> Bool {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.isTerminal() }
    }

    public func canonicalState() throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.canonicalState() }
    }
}

// MARK: - Codex bash / file-change lifecycle (P6 leftover)

/// Value-state port of leftover `CodexNativeSessionController` file-change and bash
/// running-update reducers (`AgentProviderCodexLifecycleV1`). GUI/host rewire is later.
public final class CoreAgentProviderCodexLifecycle: Sendable {
    private let raw: AgentProviderCodexLifecycleV1

    public init() {
        raw = AgentProviderCodexLifecycleV1()
    }

    public func reset() throws {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.reset() }
    }

    public func applyFileChange(method: String, paramsJSON: String) throws -> AgentProviderCodexLifecycleEventV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyFileChange(method: method, paramsJson: paramsJSON)
        }
    }

    public func applyFileChangeLifecycle(method: String, paramsJSON: String) throws -> AgentProviderCodexLifecycleEventV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyFileChangeLifecycle(method: method, paramsJson: paramsJSON)
        }
    }

    public func applyFileChangeOutputDelta(paramsJSON: String) throws -> AgentProviderCodexLifecycleEventV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyFileChangeOutputDelta(paramsJson: paramsJSON)
        }
    }

    public func applyCommandExecutionRunningUpdate(
        _ update: AgentProviderCodexRunningUpdateV1,
        items: [AgentProviderCodexBashItemV1]
    ) throws -> AgentProviderCodexRunningApplyV1 {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.applyCommandExecutionRunningUpdate(update: update, items: items)
        }
    }

    public func parseCommandExecutionRunningUpdate(
        method: String,
        paramsJSON: String
    ) throws -> AgentProviderCodexRunningUpdateV1? {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.parseCommandExecutionRunningUpdate(method: method, paramsJson: paramsJSON)
        }
    }

    public func sanitizeCommandOutput(_ rawOutput: String) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.sanitizeCommandOutput(raw: rawOutput) }
    }

    public func withCommandExecutionRunningStatus(
        resultJSON: String?,
        processId: String?,
        appendOutput: String?
    ) throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow {
            try raw.withCommandExecutionRunningStatus(
                resultJson: resultJSON,
                processId: processId,
                appendOutput: appendOutput
            )
        }
    }

    public func canonicalState() throws -> String {
        try CoreAgentSessionHostErrorMapping.rethrow { try raw.canonicalState() }
    }
}
