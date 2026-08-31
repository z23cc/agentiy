import Foundation
import RepoPromptDomainRuntime

/// Maps Codex's dispatch-specific result vocabulary onto the shared transient
/// execution classifier without transferring any Codex lifecycle authority.
///
/// A completed report means only that the provider accepted or durably queued
/// the dispatch operation. The report must never be published as a terminal
/// Agent run result; Codex events and `AgentRunTerminalCommitBarrier` remain the
/// sole terminal settlement path.
@MainActor
enum CodexIntegratedRunExecutionAdapter {
    struct Result {
        let nativeOutcome: CodexAgentModeCoordinator.NativeSendOutcome
        let executionReport: DomainAgentRunExecutionReport

        var didStartProviderRun: Bool {
            if case .sent = nativeOutcome {
                return true
            }
            return false
        }

        var shouldReleaseCreatedOwnership: Bool {
            switch executionReport.result {
            case .superseded:
                true
            case let .terminal(outcome):
                outcome.kind != .completed
            }
        }
    }

    static func execute(
        operation: () async -> CodexAgentModeCoordinator.NativeSendOutcome
    ) async -> Result {
        var nativeOutcome: CodexAgentModeCoordinator.NativeSendOutcome?
        let executionReport = await DomainAgentRunExecutionCore.executeProvider {
            let outcome = await operation()
            nativeOutcome = outcome
            return operationResult(for: outcome)
        }
        guard let nativeOutcome else {
            preconditionFailure("Codex transient execution completed without a native outcome")
        }
        return Result(nativeOutcome: nativeOutcome, executionReport: executionReport)
    }

    private static func operationResult(
        for outcome: CodexAgentModeCoordinator.NativeSendOutcome
    ) -> DomainAgentRunProviderExecutionResult {
        switch outcome {
        case .sent, .queuedFallback:
            .completed(assistantText: nil)
        case .stale:
            .superseded
        case .cancelled:
            .cancelled(assistantText: nil)
        case let .preDispatchRejected(message), let .failed(message):
            .failed(signal: .providerFailure(
                assistantText: message,
                reason: .agentError
            ))
        }
    }
}
