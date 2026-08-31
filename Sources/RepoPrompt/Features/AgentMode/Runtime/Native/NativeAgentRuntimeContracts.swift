import Foundation

/// Core Agent Mode contract for native CLI runtimes that keep an interactive
/// process/session alive across turns.
///
/// This is an app-internal contract, not the future external plugin API. It can
/// use core app models (`AIStreamResult`, `AgentApprovalRequest`, and
/// `AgentApprovalDecision`) because adapters/bridges are expected to translate
/// plugin-owned DTOs before events reach Agent Mode.
protocol NativeAgentRuntimeControlling: Actor {
    var hasActiveSession: Bool { get async }
    var hasTurnInFlight: Bool { get async }
    var events: AsyncStream<NativeAgentRuntimeEvent> { get async }

    func ensureEventsStreamReady() async
    func resetEventsStreamForNewRun() async
    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: NativeAgentRuntimeEffortLevel?,
        systemPromptOverride: String?
    ) async throws -> NativeAgentRuntimeSessionRef
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef
    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) async throws
    func sendUserMessage(_ text: String) async throws -> UUID
    /// Sends a message with a caller-reserved turn identity. The identity is reserved before
    /// crossing the provider boundary so an immediately-completing provider cannot publish its
    /// terminal event before the coordinator has installed its stale-event fence.
    func sendUserMessage(_ text: String, turnID: UUID) async throws -> UUID
    /// Sends a reasoned interrupt request to the provider runtime.
    /// - Parameter reason: "interrupt" for steering (graceful), "cancel" for forceful stop.
    func interruptTurn(reason: String) async -> NativeAgentRuntimeInterruptOutcome
    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome
    func shutdown() async
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async
}

extension NativeAgentRuntimeControlling {
    func cleanupConversation(_ handle: ProviderConversationCleanupHandle, action: ProviderConversationCleanupAction) async -> ProviderConversationCleanupOutcome {
        .unsupported(message: "Native runtime has no local API for \(action.rawValue) cleanup of conversations.")
    }
}

// MARK: - Provider-neutral native runtime DTOs

/// Event plane shared by interactive native runtimes. These types are owned by the runtime
/// contract rather than by any retired provider controller, so a production adapter cannot retain
/// an implementation dependency merely to name its protocol values.
enum NativeAgentRuntimeTurnStatus {
    case completed
    case cancelled
    case failed
}

struct NativeAgentRuntimeRuntimeInitStatus: Equatable {
    struct InitializeResponseSnapshot: Equatable {
        struct Command: Equatable {
            let name: String
            let description: String
            let argumentHint: String
        }

        struct Agent: Equatable {
            let name: String
            let description: String
            let model: String?
        }

        struct Account: Equatable {
            let email: String?
            let organization: String?
            let subscriptionType: String?
            let tokenSource: String?
            let apiKeySource: String?
            let apiProvider: String?
        }

        let commands: [Command]
        let agents: [Agent]
        let outputStyle: String?
        let availableOutputStyles: [String]
        let account: Account?
        let pid: Int?
        let modelsJSON: String?
        let fastModeStateJSON: String?
    }

    let sessionID: String?
    let tools: [String]
    let mcpServerStatuses: [String: String]
    let initializeResponse: InitializeResponseSnapshot?

    var repoPromptServerStatus: String? {
        mcpServerStatuses.first {
            $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }?.value
    }

    var isRepoPromptServerFailed: Bool {
        guard let status = repoPromptServerStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return status == "failed"
    }
}

enum NativeAgentRuntimeEvent {
    case stream(AIStreamResult)
    case runtimeInit(NativeAgentRuntimeRuntimeInitStatus)
    case approvalRequest(AgentApprovalRequest)
    case approvalCancelled(requestID: String)
    case turnCompleted(turnID: UUID, status: NativeAgentRuntimeTurnStatus)
    case error(String)
}

struct NativeAgentRuntimeSessionRef {
    var sessionID: String?
}

/// Outcome of an interrupt control request, used by the coordinator to decide whether it is safe
/// to proceed with a superseding user turn.
enum NativeAgentRuntimeInterruptOutcome: Equatable {
    case acknowledged
    case noTurnInFlight
    case timedOut
    case failed
}

enum NativeAgentRuntimeControllerError: Error, LocalizedError {
    case processNotRunning
    case initializationFailed(String)
    case invalidControlResponse(String)
    case inputWriteFailed(String)
    case controlRequestTimedOut(requestID: String)
    case liveModelSwitchRequiresRestart

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            "Claude process is not running."
        case let .initializationFailed(message):
            "Claude initialization failed: \(message)"
        case let .invalidControlResponse(message):
            "Claude control response failed: \(message)"
        case let .inputWriteFailed(message):
            "Failed writing to Claude process stdin: \(message)"
        case let .controlRequestTimedOut(requestID):
            "Claude control request timed out: \(requestID)"
        case .liveModelSwitchRequiresRestart:
            "Changing to the selected model requires restarting Claude because its launch environment changes."
        }
    }
}

typealias NativeAgentRuntimeEffortLevel = ClaudeCodeEffortLevel
