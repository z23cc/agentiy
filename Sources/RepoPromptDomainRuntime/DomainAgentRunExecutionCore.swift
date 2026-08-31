import Foundation

// MARK: - Shared transient Agent run execution

/// The host-controlled result of one provider operation.
///
/// Completion and supersession are explicit, while provider adapters may carry
/// a typed terminal outcome. Thrown cancellation and failure remain supported
/// for unclassified execution errors and share the same classification order.
package enum DomainAgentRunExecutionOperationResult: Equatable, Sendable {
    case completed(assistantText: String?)
    /// A provider adapter may supply a typed terminal signal after it has
    /// translated its protocol event. The core carries the resulting outcome
    /// without reclassifying it from display text.
    case terminal(DomainAgentRunTerminalOutcome)
    case superseded
}

/// The presentation-free result returned to an Agent execution host.
///
/// Hosts remain responsible for mapping terminal outcomes into their canonical
/// publication surface. This value owns no session, provider, or settlement
/// state.
package enum DomainAgentRunExecutionResult: Equatable, Sendable {
    case terminal(DomainAgentRunTerminalOutcome)
    case superseded
}

/// Deterministic lifecycle facts produced by one execution-core invocation.
///
/// The trace intentionally excludes provider payloads, display text, IDs, and
/// timestamps so streaming and one-shot hosts can assert lifecycle parity.
package enum DomainAgentRunExecutionTraceEvent: Equatable, Sendable {
    case executionStarted
    case terminalOutcomeProduced(DomainAgentRunTerminalOutcome.Kind)
    case executionSuperseded
}

/// Immutable report from one shared execution-core invocation.
package struct DomainAgentRunExecutionReport: Equatable, Sendable {
    package let result: DomainAgentRunExecutionResult
    package let trace: [DomainAgentRunExecutionTraceEvent]

    package init(
        result: DomainAgentRunExecutionResult,
        trace: [DomainAgentRunExecutionTraceEvent]
    ) {
        self.result = result
        self.trace = trace
    }
}

/// Stateless classifier shared by app-hosted and direct/headless Agent runs.
///
/// This namespace deliberately owns no task, stream, provider, registration,
/// epoch, cancellation handler, teardown, or publication capability. The
/// caller supplies exactly one operation on its own isolation domain, then maps
/// the returned report into its existing host and canonical lifecycle surfaces.
package enum DomainAgentRunExecutionCore {
    package static func execute(
        isolation _: isolated (any Actor)? = #isolation,
        failureReason: DomainAgentRunSnapshot.FailureReason = .agentError,
        deferFailureClassification: Bool = false,
        failureText: (any Error) -> String = { $0.localizedDescription },
        operation: () async throws -> DomainAgentRunExecutionOperationResult
    ) async -> DomainAgentRunExecutionReport {
        let started: [DomainAgentRunExecutionTraceEvent] = [.executionStarted]
        do {
            switch try await operation() {
            case let .completed(assistantText):
                let outcome = DomainAgentRunTerminalOutcome.completed(assistantText: assistantText)
                return terminalReport(outcome, after: started)
            case let .terminal(outcome):
                return terminalReport(outcome, after: started)
            case .superseded:
                return DomainAgentRunExecutionReport(
                    result: .superseded,
                    trace: started + [.executionSuperseded]
                )
            }
        } catch is CancellationError {
            return terminalReport(.cancelled(), after: started)
        } catch {
            let assistantText = failureText(error)
            let outcome = deferFailureClassification
                ? DomainAgentRunTerminalOutcome.failedWithoutClassification(assistantText: assistantText)
                : DomainAgentRunTerminalOutcome.failed(assistantText: assistantText, reason: failureReason)
            return terminalReport(outcome, after: started)
        }
    }

    /// Executes a provider adapter operation after reducing its typed
    /// termination signal through the shared semantic authority. Provider
    /// adapters may still throw for an unclassified transport/setup error; in
    /// that case the normal deferred failure path is preserved for transcript
    /// settlement, while cancellation remains canonical.
    package static func executeProvider(
        isolation: isolated (any Actor)? = #isolation,
        failureText: (any Error) -> String = { $0.localizedDescription },
        operation: () async throws -> DomainAgentRunProviderExecutionResult
    ) async -> DomainAgentRunExecutionReport {
        await execute(
            isolation: isolation,
            deferFailureClassification: true,
            failureText: failureText
        ) {
            let result = try await operation()
            switch DomainAgentRunProviderSemanticAuthority.resolve(result.semanticSignal) {
            case let .terminal(outcome):
                return .terminal(outcome)
            case .superseded:
                return .superseded
            }
        }
    }

    private static func terminalReport(
        _ outcome: DomainAgentRunTerminalOutcome,
        after trace: [DomainAgentRunExecutionTraceEvent]
    ) -> DomainAgentRunExecutionReport {
        DomainAgentRunExecutionReport(
            result: .terminal(outcome),
            trace: trace + [.terminalOutcomeProduced(outcome.kind)]
        )
    }
}
