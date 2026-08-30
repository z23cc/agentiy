import Foundation
import RepoPromptDomainRuntime

// Provider-neutral run-attempt vocabulary is owned by RepoPromptDomainRuntime. These aliases keep
// existing App/provider call sites source-compatible while ensuring the reducer has one definition.
typealias AgentRunBindingIdentity = DomainAgentRunBindingIdentity
typealias AgentRunOwnership = DomainAgentRunOwnership
typealias AgentRunEpochTransitionKind = DomainAgentRunEpochTransitionKind
typealias AgentRunTurnEpoch = DomainAgentRunTurnEpoch
typealias AgentRunTerminalPublicationEnvelope = DomainAgentRunTerminalPublicationEnvelope
typealias AgentRunTerminalPublicationResult = DomainAgentRunTerminalPublicationResult
typealias AgentRunLifecycleStage = DomainAgentRunLifecycleStage
typealias AgentRunLivenessSignalKind = DomainAgentRunLivenessSignalKind
typealias AgentRunRetryIntent = DomainAgentRunRetryIntent
typealias AgentRunProgressSignal = DomainAgentRunProgressSignal
typealias AgentRunLivenessSnapshot = DomainAgentRunLivenessSnapshot
typealias AgentRunProgressRejection = DomainAgentRunProgressRejection
typealias AgentRunProgressAcceptance = DomainAgentRunProgressAcceptance
typealias AgentRunLifecycleTracker = DomainAgentRunLifecycleTracker

/// App-only terminal teardown resources. The closure captures AgentSessionRunState and therefore
/// remains a presentation/provider adapter; ownership and liveness decisions live in Domain.
@MainActor
final class AgentRunAttemptTerminalResources {
    typealias Teardown = @MainActor () async -> Void
    typealias Prepare = @MainActor (_ terminalState: AgentSessionRunState) -> Teardown?

    let ownership: AgentRunOwnership
    private let prepare: Prepare
    private(set) var isClaimed = false

    init(ownership: AgentRunOwnership, prepare: @escaping Prepare) {
        self.ownership = ownership
        self.prepare = prepare
    }

    func claim(for ownership: AgentRunOwnership, terminalState: AgentSessionRunState) -> Teardown? {
        guard !isClaimed, self.ownership == ownership else { return nil }
        isClaimed = true
        return prepare(terminalState)
    }
}
