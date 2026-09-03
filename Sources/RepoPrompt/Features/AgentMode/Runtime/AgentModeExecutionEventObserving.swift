import Foundation
import RepoPromptDomainRuntime

/// Execution-side observer of the in-process run stack, installed by the seam's executor
/// so provider runtime events and terminal commits can be mirrored onto
/// `AgentSessionConnection.events` (design §5.5) without changing how the stack itself
/// delivers them to presentation hooks.
///
/// Observation is fire-and-forget: the stack never waits on an observer and observers
/// never influence settlement.
@MainActor
protocol AgentModeExecutionEventObserving: AnyObject {
    /// A provider-neutral runtime event was consumed for `session`'s active attempt.
    func executionDidObserveRuntimeEvent(_ event: NativeAgentRuntimeEvent, session: AgentTabSession)
    /// A terminal commit for the run hosted by `tabID` was accepted and published.
    func executionDidCommitTerminalOutcome(_ outcome: DomainAgentRunTerminalOutcome, tabID: UUID)
}
