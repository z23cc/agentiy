import Foundation

// MARK: - Provider semantic closure

/// Provider-neutral terminal facts emitted by a provider adapter.
///
/// Adapters translate provider-specific events into this vocabulary before they cross the
/// terminal commit boundary. The Domain authority intentionally does not inspect provider text,
/// protocol payloads, or error descriptions to choose a failure class.
package enum DomainAgentRunProviderTerminationSignal: Equatable, Sendable {
    case completed(assistantText: String?)
    case cancelled(assistantText: String?)
    case superseded
    case startupFailure(assistantText: String?)
    case providerFailure(assistantText: String?, reason: DomainAgentRunSnapshot.FailureReason?)
    case timeout(assistantText: String?)
    case processExited(assistantText: String?)
    case transportClosed(assistantText: String?)
    case unexpectedEnd(assistantText: String?)
}

/// Result of reducing provider termination facts. `superseded` is deliberately non-terminal and
/// therefore cannot be accidentally published as a failed run.
package enum DomainAgentRunProviderSemanticResolution: Equatable, Sendable {
    case terminal(DomainAgentRunTerminalOutcome)
    case superseded
}

/// Single semantic reducer shared by every provider execution host.
///
/// Precedence is structural rather than text-derived:
/// - cancellation always produces the canonical cancelled reason;
/// - explicit failure reasons win over deferred transcript classification;
/// - process/transport/EOF/timeout signals carry their fixed canonical reason;
/// - startup/provider failures defer only when the adapter has no stronger typed reason.
package enum DomainAgentRunProviderSemanticAuthority {
    package static func resolve(
        _ signal: DomainAgentRunProviderTerminationSignal
    ) -> DomainAgentRunProviderSemanticResolution {
        switch signal {
        case let .completed(assistantText):
            return .terminal(.completed(assistantText: assistantText))
        case let .cancelled(assistantText):
            return .terminal(.cancelled(assistantText: assistantText))
        case .superseded:
            return .superseded
        case let .startupFailure(assistantText):
            return .terminal(.failedWithoutClassification(assistantText: assistantText))
        case let .providerFailure(assistantText, reason):
            if let reason {
                return .terminal(.failed(assistantText: assistantText, reason: reason))
            }
            return .terminal(.failedWithoutClassification(assistantText: assistantText))
        case let .timeout(assistantText):
            return .terminal(.failed(assistantText: assistantText, reason: .timeout))
        case let .processExited(assistantText),
             let .transportClosed(assistantText),
             let .unexpectedEnd(assistantText):
            return .terminal(.failed(assistantText: assistantText, reason: .processCrash))
        }
    }

    package static func outcome(
        _ signal: DomainAgentRunProviderTerminationSignal
    ) -> DomainAgentRunTerminalOutcome? {
        guard case let .terminal(outcome) = resolve(signal) else { return nil }
        return outcome
    }

    package static func isTerminal(
        _ signal: DomainAgentRunProviderTerminationSignal
    ) -> Bool {
        if case .superseded = signal { return false }
        return true
    }
}

/// A provider-neutral operation result suitable for `DomainAgentRunExecutionCore`.
package enum DomainAgentRunProviderExecutionResult: Equatable, Sendable {
    case completed(assistantText: String?)
    case cancelled(assistantText: String?)
    case failed(signal: DomainAgentRunProviderTerminationSignal)
    case superseded

    package var semanticSignal: DomainAgentRunProviderTerminationSignal {
        switch self {
        case let .completed(assistantText): .completed(assistantText: assistantText)
        case let .cancelled(assistantText): .cancelled(assistantText: assistantText)
        case let .failed(signal): signal
        case .superseded: .superseded
        }
    }
}
