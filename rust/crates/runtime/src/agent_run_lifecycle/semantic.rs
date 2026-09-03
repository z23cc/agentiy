//! Port of `DomainAgentRunProviderSemanticAuthority` (P17) and the pure classification half of
//! `DomainAgentRunExecutionCore`. The Swift core is `async` and runs the provider operation
//! itself; here the operation's outcome (returned value, thrown cancellation, thrown error text)
//! is an input and only the deterministic classification is ported.

use super::types::{FailureReason, TerminalOutcome, TerminalOutcomeKind, TerminationSignal};

/// `DomainAgentRunProviderSemanticResolution`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum SemanticResolution {
    Terminal(TerminalOutcome),
    Superseded,
}

/// `DomainAgentRunExecutionOperationResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ExecutionOperationResult {
    Completed { assistant_text: Option<String> },
    Terminal(TerminalOutcome),
    Superseded,
}

/// `DomainAgentRunProviderExecutionResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ProviderExecutionResult {
    Completed { assistant_text: Option<String> },
    Cancelled { assistant_text: Option<String> },
    Failed { signal: TerminationSignal },
    Superseded,
}

impl ProviderExecutionResult {
    /// `semanticSignal`.
    #[must_use]
    pub fn semantic_signal(&self) -> TerminationSignal {
        match self {
            Self::Completed { assistant_text } => TerminationSignal::Completed {
                assistant_text: assistant_text.clone(),
            },
            Self::Cancelled { assistant_text } => TerminationSignal::Cancelled {
                assistant_text: assistant_text.clone(),
            },
            Self::Failed { signal } => signal.clone(),
            Self::Superseded => TerminationSignal::Superseded,
        }
    }
}

/// How one operation ended, as observed by the (Swift or host) executor. `Threw*` carry what the
/// Swift `catch` arms observe: `CancellationError` vs. any other error's `failureText`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum OperationEnding<T> {
    Returned(T),
    ThrewCancellation,
    ThrewError { failure_text: String },
}

/// `DomainAgentRunExecutionResult`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ExecutionResult {
    Terminal(TerminalOutcome),
    Superseded,
}

/// `DomainAgentRunExecutionTraceEvent`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ExecutionTraceEvent {
    ExecutionStarted,
    TerminalOutcomeProduced(TerminalOutcomeKind),
    ExecutionSuperseded,
}

/// `DomainAgentRunExecutionReport`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ExecutionReport {
    pub result: ExecutionResult,
    pub trace: Vec<ExecutionTraceEvent>,
}

impl ExecutionReport {
    fn terminal(outcome: TerminalOutcome) -> Self {
        let kind = outcome.kind;
        Self {
            result: ExecutionResult::Terminal(outcome),
            trace: vec![
                ExecutionTraceEvent::ExecutionStarted,
                ExecutionTraceEvent::TerminalOutcomeProduced(kind),
            ],
        }
    }

    fn superseded() -> Self {
        Self {
            result: ExecutionResult::Superseded,
            trace: vec![
                ExecutionTraceEvent::ExecutionStarted,
                ExecutionTraceEvent::ExecutionSuperseded,
            ],
        }
    }
}

/// Stateless namespace, like the Swift caseless enum.
pub struct SemanticAuthority;

impl SemanticAuthority {
    /// `DomainAgentRunProviderSemanticAuthority.resolve`. Precedence is structural, never
    /// text-derived: cancellation → canonical cancelled reason; explicit reasons win over deferred
    /// classification; process/transport/EOF/timeout carry fixed reasons; startup/provider
    /// failures defer only without a stronger typed reason.
    #[must_use]
    pub fn resolve(signal: &TerminationSignal) -> SemanticResolution {
        let outcome = match signal {
            TerminationSignal::Completed { assistant_text } => {
                TerminalOutcome::completed(assistant_text.clone())
            }
            TerminationSignal::Cancelled { assistant_text } => {
                TerminalOutcome::cancelled(assistant_text.clone())
            }
            TerminationSignal::Superseded => return SemanticResolution::Superseded,
            TerminationSignal::StartupFailure { assistant_text } => {
                TerminalOutcome::failed_without_classification(assistant_text.clone())
            }
            TerminationSignal::ProviderFailure {
                assistant_text,
                reason,
            } => match reason {
                Some(reason) => TerminalOutcome::failed(assistant_text.clone(), *reason),
                None => TerminalOutcome::failed_without_classification(assistant_text.clone()),
            },
            TerminationSignal::Timeout { assistant_text } => {
                TerminalOutcome::failed(assistant_text.clone(), FailureReason::Timeout)
            }
            TerminationSignal::ProcessExited { assistant_text }
            | TerminationSignal::TransportClosed { assistant_text }
            | TerminationSignal::UnexpectedEnd { assistant_text } => {
                TerminalOutcome::failed(assistant_text.clone(), FailureReason::ProcessCrash)
            }
        };
        SemanticResolution::Terminal(outcome)
    }

    /// `DomainAgentRunProviderSemanticAuthority.outcome`.
    #[must_use]
    pub fn outcome(signal: &TerminationSignal) -> Option<TerminalOutcome> {
        match Self::resolve(signal) {
            SemanticResolution::Terminal(outcome) => Some(outcome),
            SemanticResolution::Superseded => None,
        }
    }

    /// `DomainAgentRunProviderSemanticAuthority.isTerminal`.
    #[must_use]
    pub const fn is_terminal(signal: &TerminationSignal) -> bool {
        !matches!(signal, TerminationSignal::Superseded)
    }

    /// Classification half of `DomainAgentRunExecutionCore.execute`.
    #[must_use]
    pub fn classify_execution(
        ending: OperationEnding<ExecutionOperationResult>,
        failure_reason: FailureReason,
        defer_failure_classification: bool,
    ) -> ExecutionReport {
        match ending {
            OperationEnding::Returned(ExecutionOperationResult::Completed { assistant_text }) => {
                ExecutionReport::terminal(TerminalOutcome::completed(assistant_text))
            }
            OperationEnding::Returned(ExecutionOperationResult::Terminal(outcome)) => {
                ExecutionReport::terminal(outcome)
            }
            OperationEnding::Returned(ExecutionOperationResult::Superseded) => {
                ExecutionReport::superseded()
            }
            OperationEnding::ThrewCancellation => {
                ExecutionReport::terminal(TerminalOutcome::cancelled(None))
            }
            OperationEnding::ThrewError { failure_text } => {
                let outcome = if defer_failure_classification {
                    TerminalOutcome::failed_without_classification(Some(failure_text))
                } else {
                    TerminalOutcome::failed(Some(failure_text), failure_reason)
                };
                ExecutionReport::terminal(outcome)
            }
        }
    }

    /// Classification half of `DomainAgentRunExecutionCore.executeProvider`: the provider result is
    /// reduced through [`Self::resolve`], then classified with deferred failure classification.
    #[must_use]
    pub fn classify_provider_execution(
        ending: OperationEnding<ProviderExecutionResult>,
    ) -> ExecutionReport {
        let ending = match ending {
            OperationEnding::Returned(result) => {
                OperationEnding::Returned(match Self::resolve(&result.semantic_signal()) {
                    SemanticResolution::Terminal(outcome) => {
                        ExecutionOperationResult::Terminal(outcome)
                    }
                    SemanticResolution::Superseded => ExecutionOperationResult::Superseded,
                })
            }
            OperationEnding::ThrewCancellation => OperationEnding::ThrewCancellation,
            OperationEnding::ThrewError { failure_text } => {
                OperationEnding::ThrewError { failure_text }
            }
        };
        Self::classify_execution(ending, FailureReason::AgentError, true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> Option<String> {
        Some(value.to_owned())
    }

    /// Mirrors `testCanonicalSignalsResolveToFixedFailureReasons`.
    #[test]
    fn canonical_signals_resolve_to_fixed_failure_reasons() {
        assert_eq!(
            SemanticAuthority::resolve(&TerminationSignal::Completed {
                assistant_text: text("done")
            }),
            SemanticResolution::Terminal(TerminalOutcome::completed(text("done")))
        );
        assert_eq!(
            SemanticAuthority::resolve(&TerminationSignal::Cancelled {
                assistant_text: None
            }),
            SemanticResolution::Terminal(TerminalOutcome::cancelled(None))
        );
        assert_eq!(
            SemanticAuthority::resolve(&TerminationSignal::Timeout {
                assistant_text: text("slow")
            }),
            SemanticResolution::Terminal(TerminalOutcome::failed(
                text("slow"),
                FailureReason::Timeout
            ))
        );
        for signal in [
            TerminationSignal::ProcessExited {
                assistant_text: text("exited"),
            },
            TerminationSignal::TransportClosed {
                assistant_text: text("exited"),
            },
            TerminationSignal::UnexpectedEnd {
                assistant_text: text("exited"),
            },
        ] {
            assert_eq!(
                SemanticAuthority::resolve(&signal),
                SemanticResolution::Terminal(TerminalOutcome::failed(
                    text("exited"),
                    FailureReason::ProcessCrash
                )),
                "{signal:?}"
            );
        }
    }

    /// Mirrors `testExplicitProviderFailureReasonWinsOverDeferredClassification`.
    #[test]
    fn explicit_provider_failure_reason_wins_over_deferred_classification() {
        assert_eq!(
            SemanticAuthority::outcome(&TerminationSignal::ProviderFailure {
                assistant_text: text("network"),
                reason: Some(FailureReason::Timeout),
            }),
            Some(TerminalOutcome::failed(
                text("network"),
                FailureReason::Timeout
            ))
        );
        assert_eq!(
            SemanticAuthority::outcome(&TerminationSignal::ProviderFailure {
                assistant_text: text("network"),
                reason: None,
            }),
            Some(TerminalOutcome::failed_without_classification(text(
                "network"
            )))
        );
        assert_eq!(
            SemanticAuthority::outcome(&TerminationSignal::StartupFailure {
                assistant_text: text("boot")
            }),
            Some(TerminalOutcome::failed_without_classification(text("boot")))
        );
    }

    /// Mirrors `testSupersededIsNonTerminal`.
    #[test]
    fn superseded_is_non_terminal() {
        assert_eq!(
            SemanticAuthority::resolve(&TerminationSignal::Superseded),
            SemanticResolution::Superseded
        );
        assert_eq!(
            SemanticAuthority::outcome(&TerminationSignal::Superseded),
            None
        );
        assert!(!SemanticAuthority::is_terminal(
            &TerminationSignal::Superseded
        ));
        assert!(SemanticAuthority::is_terminal(
            &TerminationSignal::Completed {
                assistant_text: None
            }
        ));
    }

    /// Mirrors the `DomainAgentRunExecutionCore.executeProvider` tests.
    #[test]
    fn provider_execution_reduces_through_semantic_authority() {
        let report = SemanticAuthority::classify_provider_execution(OperationEnding::Returned(
            ProviderExecutionResult::Failed {
                signal: TerminationSignal::ProcessExited {
                    assistant_text: text("crash"),
                },
            },
        ));
        assert_eq!(
            report,
            ExecutionReport {
                result: ExecutionResult::Terminal(TerminalOutcome::failed(
                    text("crash"),
                    FailureReason::ProcessCrash
                )),
                trace: vec![
                    ExecutionTraceEvent::ExecutionStarted,
                    ExecutionTraceEvent::TerminalOutcomeProduced(TerminalOutcomeKind::Failed),
                ],
            }
        );
        assert_eq!(
            SemanticAuthority::classify_provider_execution(OperationEnding::Returned(
                ProviderExecutionResult::Superseded
            )),
            ExecutionReport {
                result: ExecutionResult::Superseded,
                trace: vec![
                    ExecutionTraceEvent::ExecutionStarted,
                    ExecutionTraceEvent::ExecutionSuperseded,
                ],
            }
        );
        assert_eq!(
            SemanticAuthority::classify_provider_execution(OperationEnding::ThrewCancellation)
                .result,
            ExecutionResult::Terminal(TerminalOutcome::cancelled(None))
        );
        assert_eq!(
            SemanticAuthority::classify_provider_execution(OperationEnding::ThrewError {
                failure_text: "boom".to_owned()
            })
            .result,
            ExecutionResult::Terminal(TerminalOutcome::failed_without_classification(text("boom")))
        );
    }

    #[test]
    fn execution_classification_honors_failure_reason_and_deferral() {
        assert_eq!(
            SemanticAuthority::classify_execution(
                OperationEnding::ThrewError {
                    failure_text: "boom".to_owned()
                },
                FailureReason::Timeout,
                false
            )
            .result,
            ExecutionResult::Terminal(TerminalOutcome::failed(
                text("boom"),
                FailureReason::Timeout
            ))
        );
        assert_eq!(
            SemanticAuthority::classify_execution(
                OperationEnding::Returned(ExecutionOperationResult::Completed {
                    assistant_text: text("ok")
                }),
                FailureReason::AgentError,
                false
            ),
            ExecutionReport {
                result: ExecutionResult::Terminal(TerminalOutcome::completed(text("ok"))),
                trace: vec![
                    ExecutionTraceEvent::ExecutionStarted,
                    ExecutionTraceEvent::TerminalOutcomeProduced(TerminalOutcomeKind::Completed),
                ],
            }
        );
    }
}
