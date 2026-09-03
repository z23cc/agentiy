//! Projections between the reducer vocabulary and the frozen `agent_host_v1` wire/log schema, so a
//! host can append `RunLifecycleEvent`s straight from reducer output.
//!
//! Wire → domain conversions fail closed: `*_UNSPECIFIED` and out-of-range enum values are
//! rejected rather than defaulted, because the Swift originals have no such state.
//!
//! Known lossy projection (reported, not patched -- the schema is frozen): wire `TurnEpoch`
//! carries only `turn_id`/`epoch`/`transition`, whereas the domain [`TurnEpoch`] also fences on
//! runtime, session, activation, registration, and continuity generations. The event log therefore
//! records the epoch identity, not the full fence; hosts keep the full value in their snapshot.

use agentry_proto::agent_host::v1;

use super::types::{
    EpochTransitionKind, FailureReason, LifecycleStage, LivenessSnapshot, RetryIntent,
    TerminalOutcome, TerminalOutcomeKind, TerminationSignal, TurnEpoch,
};

/// A wire value the reducers cannot represent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProtoConversionError {
    /// An enum field was `*_UNSPECIFIED` or outside the generated range.
    InvalidEnum { field: &'static str, value: i32 },
    /// A `TerminalOutcome` whose `kind`/`failure_reason` pairing no constructor produces.
    InconsistentTerminalOutcome,
    /// A `TerminationSignal` carrying a `failure_reason` on a kind that has none.
    InconsistentTerminationSignal,
}

impl std::fmt::Display for ProtoConversionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidEnum { field, value } => {
                write!(formatter, "invalid {field} enum value {value}")
            }
            Self::InconsistentTerminalOutcome => formatter
                .write_str("terminal outcome kind/failure_reason pairing is not producible"),
            Self::InconsistentTerminationSignal => {
                formatter.write_str("termination signal carries a failure_reason its kind rejects")
            }
        }
    }
}

impl std::error::Error for ProtoConversionError {}

macro_rules! enum_bridge {
    ($domain:ty, $wire:ty, $field:literal, [$($variant:ident),+ $(,)?]) => {
        impl From<$domain> for $wire {
            fn from(value: $domain) -> Self {
                match value { $(<$domain>::$variant => Self::$variant,)+ }
            }
        }

        impl TryFrom<$wire> for $domain {
            type Error = ProtoConversionError;

            fn try_from(value: $wire) -> Result<Self, Self::Error> {
                match value {
                    $(<$wire>::$variant => Ok(Self::$variant),)+
                    <$wire>::Unspecified => Err(ProtoConversionError::InvalidEnum {
                        field: $field,
                        value: 0,
                    }),
                }
            }
        }

        impl $domain {
            /// The raw `i32` stored in prost message fields.
            #[must_use]
            pub fn to_wire_i32(self) -> i32 {
                <$wire>::from(self) as i32
            }

            /// Fail-closed decode of a prost enum field.
            pub fn from_wire_i32(value: i32) -> Result<Self, ProtoConversionError> {
                <$wire>::try_from(value)
                    .map_err(|_| ProtoConversionError::InvalidEnum { field: $field, value })
                    .and_then(Self::try_from)
            }
        }
    };
}

enum_bridge!(
    LifecycleStage,
    v1::LifecycleStage,
    "LifecycleStage",
    [
        Starting,
        PreparingRuntime,
        Running,
        WaitingForInteraction,
        Retrying,
        Cancelling,
    ]
);
enum_bridge!(
    RetryIntent,
    v1::RetryIntent,
    "RetryIntent",
    [None, ProviderManaged, ApplicationManaged]
);
enum_bridge!(
    EpochTransitionKind,
    v1::EpochTransitionKind,
    "EpochTransitionKind",
    [Initial, RelatedFollowUp, Steering, Unrelated]
);
enum_bridge!(
    FailureReason,
    v1::FailureReason,
    "FailureReason",
    [ProcessCrash, Timeout, AgentError, Cancelled]
);
enum_bridge!(
    TerminalOutcomeKind,
    v1::TerminalOutcomeKind,
    "TerminalOutcomeKind",
    [Completed, Cancelled, Failed]
);

fn optional_failure_reason_from_wire(
    value: i32,
) -> Result<Option<FailureReason>, ProtoConversionError> {
    if value == v1::FailureReason::Unspecified as i32 {
        return Ok(None);
    }
    FailureReason::from_wire_i32(value).map(Some)
}

fn optional_failure_reason_to_wire(value: Option<FailureReason>) -> i32 {
    value.map_or(
        v1::FailureReason::Unspecified as i32,
        FailureReason::to_wire_i32,
    )
}

impl TurnEpoch {
    /// Lossy projection onto the wire `TurnEpoch` (see module docs).
    #[must_use]
    pub fn to_proto(&self) -> v1::TurnEpoch {
        v1::TurnEpoch {
            turn_id: self.id.to_string(),
            epoch: self.ordinal,
            transition: self.transition_kind.to_wire_i32(),
        }
    }
}

impl TerminalOutcome {
    #[must_use]
    pub fn to_proto(&self) -> v1::TerminalOutcome {
        v1::TerminalOutcome {
            kind: self.kind.to_wire_i32(),
            assistant_text: self.assistant_text.clone(),
            failure_reason: optional_failure_reason_to_wire(self.failure_reason),
        }
    }

    /// Accepts only pairings one of the four Swift constructors can produce.
    pub fn from_proto(value: &v1::TerminalOutcome) -> Result<Self, ProtoConversionError> {
        let kind = TerminalOutcomeKind::from_wire_i32(value.kind)?;
        let failure_reason = optional_failure_reason_from_wire(value.failure_reason)?;
        let assistant_text = value.assistant_text.clone();
        match (kind, failure_reason) {
            (TerminalOutcomeKind::Completed, None) => Ok(Self::completed(assistant_text)),
            (TerminalOutcomeKind::Cancelled, Some(FailureReason::Cancelled)) => {
                Ok(Self::cancelled(assistant_text))
            }
            (TerminalOutcomeKind::Failed, Some(reason)) => Ok(Self::failed(assistant_text, reason)),
            (TerminalOutcomeKind::Failed, None) => {
                Ok(Self::failed_without_classification(assistant_text))
            }
            _ => Err(ProtoConversionError::InconsistentTerminalOutcome),
        }
    }
}

impl TerminationSignal {
    #[must_use]
    pub fn to_proto(&self) -> v1::TerminationSignal {
        let (kind, assistant_text, failure_reason) = match self {
            Self::Completed { assistant_text } => {
                (v1::TerminationSignalKind::Completed, assistant_text, None)
            }
            Self::Cancelled { assistant_text } => {
                (v1::TerminationSignalKind::Cancelled, assistant_text, None)
            }
            Self::Superseded => (v1::TerminationSignalKind::Superseded, &None, None),
            Self::StartupFailure { assistant_text } => (
                v1::TerminationSignalKind::StartupFailure,
                assistant_text,
                None,
            ),
            Self::ProviderFailure {
                assistant_text,
                reason,
            } => (
                v1::TerminationSignalKind::ProviderFailure,
                assistant_text,
                *reason,
            ),
            Self::Timeout { assistant_text } => {
                (v1::TerminationSignalKind::Timeout, assistant_text, None)
            }
            Self::ProcessExited { assistant_text } => (
                v1::TerminationSignalKind::ProcessExited,
                assistant_text,
                None,
            ),
            Self::TransportClosed { assistant_text } => (
                v1::TerminationSignalKind::TransportClosed,
                assistant_text,
                None,
            ),
            Self::UnexpectedEnd { assistant_text } => (
                v1::TerminationSignalKind::UnexpectedEnd,
                assistant_text,
                None,
            ),
        };
        v1::TerminationSignal {
            kind: kind as i32,
            assistant_text: assistant_text.clone(),
            failure_reason: optional_failure_reason_to_wire(failure_reason),
        }
    }

    pub fn from_proto(value: &v1::TerminationSignal) -> Result<Self, ProtoConversionError> {
        let kind = v1::TerminationSignalKind::try_from(value.kind).map_err(|_| {
            ProtoConversionError::InvalidEnum {
                field: "TerminationSignalKind",
                value: value.kind,
            }
        })?;
        let failure_reason = optional_failure_reason_from_wire(value.failure_reason)?;
        let assistant_text = value.assistant_text.clone();
        if failure_reason.is_some() && kind != v1::TerminationSignalKind::ProviderFailure {
            return Err(ProtoConversionError::InconsistentTerminationSignal);
        }
        if kind == v1::TerminationSignalKind::Superseded && assistant_text.is_some() {
            return Err(ProtoConversionError::InconsistentTerminationSignal);
        }
        Ok(match kind {
            v1::TerminationSignalKind::Unspecified => {
                return Err(ProtoConversionError::InvalidEnum {
                    field: "TerminationSignalKind",
                    value: 0,
                });
            }
            v1::TerminationSignalKind::Completed => Self::Completed { assistant_text },
            v1::TerminationSignalKind::Cancelled => Self::Cancelled { assistant_text },
            v1::TerminationSignalKind::Superseded => Self::Superseded,
            v1::TerminationSignalKind::StartupFailure => Self::StartupFailure { assistant_text },
            v1::TerminationSignalKind::ProviderFailure => Self::ProviderFailure {
                assistant_text,
                reason: failure_reason,
            },
            v1::TerminationSignalKind::Timeout => Self::Timeout { assistant_text },
            v1::TerminationSignalKind::ProcessExited => Self::ProcessExited { assistant_text },
            v1::TerminationSignalKind::TransportClosed => Self::TransportClosed { assistant_text },
            v1::TerminationSignalKind::UnexpectedEnd => Self::UnexpectedEnd { assistant_text },
        })
    }
}

impl LivenessSnapshot {
    /// `RunStageChanged` projection of an accepted liveness snapshot.
    #[must_use]
    pub fn to_stage_changed_event(&self, run_id: &str) -> v1::RunLifecycleEvent {
        v1::RunLifecycleEvent {
            run_id: run_id.to_owned(),
            epoch: self.ownership.turn_epoch.as_ref().map(TurnEpoch::to_proto),
            kind: Some(v1::run_lifecycle_event::Kind::StageChanged(
                v1::RunStageChanged {
                    stage: self.stage.to_wire_i32(),
                    retry_intent: self.retry_intent.to_wire_i32(),
                },
            )),
        }
    }
}

/// `RunTerminated` projection of a resolved terminal outcome and the signal that produced it.
#[must_use]
pub fn terminated_event(
    run_id: &str,
    epoch: Option<&TurnEpoch>,
    outcome: &TerminalOutcome,
    signal: Option<&TerminationSignal>,
) -> v1::RunLifecycleEvent {
    v1::RunLifecycleEvent {
        run_id: run_id.to_owned(),
        epoch: epoch.map(TurnEpoch::to_proto),
        kind: Some(v1::run_lifecycle_event::Kind::Terminated(
            v1::RunTerminated {
                outcome: Some(outcome.to_proto()),
                signal: signal.map(TerminationSignal::to_proto),
            },
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::uuid::RunUuid;

    #[test]
    fn enums_round_trip_and_reject_unspecified() {
        for stage in LifecycleStage::ALL {
            assert_eq!(
                LifecycleStage::from_wire_i32(stage.to_wire_i32()),
                Ok(stage)
            );
        }
        for intent in RetryIntent::ALL {
            assert_eq!(RetryIntent::from_wire_i32(intent.to_wire_i32()), Ok(intent));
        }
        for kind in EpochTransitionKind::ALL {
            assert_eq!(
                EpochTransitionKind::from_wire_i32(kind.to_wire_i32()),
                Ok(kind)
            );
        }
        for reason in FailureReason::ALL {
            assert_eq!(
                FailureReason::from_wire_i32(reason.to_wire_i32()),
                Ok(reason)
            );
        }
        assert_eq!(
            LifecycleStage::from_wire_i32(0),
            Err(ProtoConversionError::InvalidEnum {
                field: "LifecycleStage",
                value: 0
            })
        );
        assert_eq!(
            RetryIntent::from_wire_i32(99),
            Err(ProtoConversionError::InvalidEnum {
                field: "RetryIntent",
                value: 99
            })
        );
    }

    #[test]
    fn terminal_outcome_round_trips_only_producible_pairings() {
        let outcomes = [
            TerminalOutcome::completed(Some("a".into())),
            TerminalOutcome::cancelled(None),
            TerminalOutcome::failed(None, FailureReason::Timeout),
            TerminalOutcome::failed_without_classification(Some("b".into())),
        ];
        for outcome in outcomes {
            assert_eq!(
                TerminalOutcome::from_proto(&outcome.to_proto()),
                Ok(outcome)
            );
        }
        let bogus = v1::TerminalOutcome {
            kind: v1::TerminalOutcomeKind::Completed as i32,
            assistant_text: None,
            failure_reason: v1::FailureReason::Timeout as i32,
        };
        assert_eq!(
            TerminalOutcome::from_proto(&bogus),
            Err(ProtoConversionError::InconsistentTerminalOutcome)
        );
        let cancelled_without_reason = v1::TerminalOutcome {
            kind: v1::TerminalOutcomeKind::Cancelled as i32,
            assistant_text: None,
            failure_reason: 0,
        };
        assert_eq!(
            TerminalOutcome::from_proto(&cancelled_without_reason),
            Err(ProtoConversionError::InconsistentTerminalOutcome)
        );
    }

    #[test]
    fn termination_signal_round_trips_and_rejects_inconsistent_reason() {
        let signals = [
            TerminationSignal::Completed {
                assistant_text: Some("x".into()),
            },
            TerminationSignal::Cancelled {
                assistant_text: None,
            },
            TerminationSignal::Superseded,
            TerminationSignal::StartupFailure {
                assistant_text: None,
            },
            TerminationSignal::ProviderFailure {
                assistant_text: Some("y".into()),
                reason: Some(FailureReason::AgentError),
            },
            TerminationSignal::ProviderFailure {
                assistant_text: None,
                reason: None,
            },
            TerminationSignal::Timeout {
                assistant_text: None,
            },
            TerminationSignal::ProcessExited {
                assistant_text: None,
            },
            TerminationSignal::TransportClosed {
                assistant_text: None,
            },
            TerminationSignal::UnexpectedEnd {
                assistant_text: None,
            },
        ];
        for signal in signals {
            assert_eq!(
                TerminationSignal::from_proto(&signal.to_proto()),
                Ok(signal)
            );
        }
        let bogus = v1::TerminationSignal {
            kind: v1::TerminationSignalKind::Timeout as i32,
            assistant_text: None,
            failure_reason: v1::FailureReason::Timeout as i32,
        };
        assert_eq!(
            TerminationSignal::from_proto(&bogus),
            Err(ProtoConversionError::InconsistentTerminationSignal)
        );
        assert!(
            TerminationSignal::from_proto(&v1::TerminationSignal::default()).is_err(),
            "unspecified kind fails closed"
        );
    }

    #[test]
    fn turn_epoch_projection_keeps_identity_ordinal_and_transition() {
        let epoch = TurnEpoch {
            runtime_id: RunUuid::from_bytes([1; 16]),
            runtime_generation: 3,
            session_id: RunUuid::from_bytes([2; 16]),
            activation_id: RunUuid::from_bytes([3; 16]),
            registration_generation: 4,
            id: RunUuid::from_bytes([4; 16]),
            ordinal: 7,
            continuity_generation: 2,
            transition_kind: EpochTransitionKind::Steering,
        };
        let wire = epoch.to_proto();
        assert_eq!(wire.turn_id, "04040404-0404-0404-0404-040404040404");
        assert_eq!(wire.epoch, 7);
        assert_eq!(wire.transition, v1::EpochTransitionKind::Steering as i32);
    }
}
