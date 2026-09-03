//! Canonical JSON rendering of reducer values and *observable* reducer state.
//!
//! The Swift ⇄ Rust differential harness renders the Swift reducer with an identical hand-written
//! encoder and compares strings, so the format is fixed here rather than derived: keys in the
//! written order (not sorted), no whitespace, UUIDs lowercase hyphenated, integers unquoted,
//! `null` for absent optionals, strings escaped exactly as `serde_json` does. Only fields the
//! Swift originals expose (`package` visibility) participate; Swift-`private` fields
//! (`nextSequence`, `phaseOwnership`, the settlement collections) are proven through behavior.

use std::fmt::Write as _;

use super::process_identity::ProcessIdentityState;
use super::semantic::{ExecutionReport, ExecutionResult, ExecutionTraceEvent, SemanticResolution};
use super::settlement::TerminalSettlementCoordinator;
use super::terminal_commit::{TerminalCommitReceipt, TerminalCommitState};
use super::tracker::LifecycleTracker;
use super::types::{
    BindingIdentity, FailureReason, LivenessSnapshot, Ownership, ProgressAcceptance,
    TerminalOutcome, TerminalPublicationResult, TurnEpoch,
};
use super::uuid::RunUuid;

/// Ordered JSON object builder.
#[derive(Default)]
pub struct Canonical {
    buffer: String,
    has_field: bool,
}

impl Canonical {
    #[must_use]
    pub fn object() -> Self {
        Self {
            buffer: String::from("{"),
            has_field: false,
        }
    }

    fn key(&mut self, key: &str) {
        if self.has_field {
            self.buffer.push(',');
        }
        self.has_field = true;
        self.buffer.push_str(&json_string(key));
        self.buffer.push(':');
    }

    pub fn raw(&mut self, key: &str, rendered: &str) -> &mut Self {
        self.key(key);
        self.buffer.push_str(rendered);
        self
    }

    pub fn string(&mut self, key: &str, value: &str) -> &mut Self {
        self.raw(key, &json_string(value))
    }

    pub fn optional_string(&mut self, key: &str, value: Option<&str>) -> &mut Self {
        match value {
            Some(value) => self.string(key, value),
            None => self.raw(key, "null"),
        }
    }

    pub fn u64(&mut self, key: &str, value: u64) -> &mut Self {
        let mut rendered = String::new();
        let _ = write!(rendered, "{value}");
        self.raw(key, &rendered)
    }

    pub fn optional_u64(&mut self, key: &str, value: Option<u64>) -> &mut Self {
        match value {
            Some(value) => self.u64(key, value),
            None => self.raw(key, "null"),
        }
    }

    pub fn bool(&mut self, key: &str, value: bool) -> &mut Self {
        self.raw(key, if value { "true" } else { "false" })
    }

    pub fn uuid(&mut self, key: &str, value: RunUuid) -> &mut Self {
        self.raw(key, &json_string(&value.to_string()))
    }

    pub fn optional_uuid(&mut self, key: &str, value: Option<RunUuid>) -> &mut Self {
        match value {
            Some(value) => self.uuid(key, value),
            None => self.raw(key, "null"),
        }
    }

    pub fn nested(&mut self, key: &str, value: Option<&dyn CanonicalValue>) -> &mut Self {
        match value {
            Some(value) => self.raw(key, &value.canonical()),
            None => self.raw(key, "null"),
        }
    }

    #[must_use]
    pub fn finish(&mut self) -> String {
        let mut rendered = std::mem::take(&mut self.buffer);
        rendered.push('}');
        rendered
    }
}

/// serde_json-compatible string escaping.
#[must_use]
pub fn json_string(value: &str) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| String::from("\"\""))
}

/// Anything with a fixed canonical JSON rendering.
pub trait CanonicalValue {
    fn canonical(&self) -> String;
}

impl CanonicalValue for TurnEpoch {
    fn canonical(&self) -> String {
        Canonical::object()
            .uuid("runtimeID", self.runtime_id)
            .u64("runtimeGeneration", self.runtime_generation)
            .uuid("sessionID", self.session_id)
            .uuid("activationID", self.activation_id)
            .u64("registrationGeneration", self.registration_generation)
            .uuid("id", self.id)
            .u64("ordinal", self.ordinal)
            .u64("continuityGeneration", self.continuity_generation)
            .string("transitionKind", self.transition_kind.raw_value())
            .finish()
    }
}

impl CanonicalValue for BindingIdentity {
    fn canonical(&self) -> String {
        Canonical::object()
            .uuid("tabID", self.tab_id)
            .optional_uuid("persistentSessionID", self.persistent_session_id)
            .optional_uuid(
                "persistentBindingGeneration",
                self.persistent_binding_generation,
            )
            .u64(
                "bindingTransitionGeneration",
                self.binding_transition_generation,
            )
            .uuid("generation", self.generation)
            .finish()
    }
}

impl CanonicalValue for Ownership {
    fn canonical(&self) -> String {
        Canonical::object()
            .uuid("attemptID", self.attempt_id)
            .nested("binding", Some(&self.binding))
            .nested(
                "turnEpoch",
                self.turn_epoch.as_ref().map(|epoch| epoch as _),
            )
            .finish()
    }
}

impl CanonicalValue for LivenessSnapshot {
    fn canonical(&self) -> String {
        Canonical::object()
            .nested("ownership", Some(&self.ownership))
            .string("stage", self.stage.raw_value())
            .string("retryIntent", self.retry_intent.raw_value())
            .u64("lastAcceptedSequence", self.last_accepted_sequence)
            .u64(
                "lastSignalUptimeNanoseconds",
                self.last_signal_uptime_nanoseconds,
            )
            .u64(
                "lastRealProgressUptimeNanoseconds",
                self.last_real_progress_uptime_nanoseconds,
            )
            .optional_u64(
                "lastHeartbeatUptimeNanoseconds",
                self.last_heartbeat_uptime_nanoseconds,
            )
            .finish()
    }
}

impl CanonicalValue for ProgressAcceptance {
    fn canonical(&self) -> String {
        match self {
            Self::Accepted(snapshot) => Canonical::object()
                .string("acceptance", "accepted")
                .nested("snapshot", Some(snapshot))
                .finish(),
            Self::Rejected(rejection) => Canonical::object()
                .string("acceptance", "rejected")
                .string("rejection", rejection.raw_value())
                .finish(),
        }
    }
}

impl CanonicalValue for TerminalPublicationResult {
    fn canonical(&self) -> String {
        match self {
            Self::Accepted { successor_epoch } => Canonical::object()
                .string("result", "accepted")
                .nested(
                    "successorEpoch",
                    successor_epoch.as_ref().map(|epoch| epoch as _),
                )
                .finish(),
            Self::Stale => Canonical::object().string("result", "stale").finish(),
            Self::Rejected { reason } => Canonical::object()
                .string("result", "rejected")
                .string("reason", reason)
                .finish(),
        }
    }
}

impl CanonicalValue for TerminalCommitReceipt {
    fn canonical(&self) -> String {
        Canonical::object()
            .uuid("commitID", self.commit_id)
            .nested("ownership", Some(&self.ownership))
            .finish()
    }
}

impl CanonicalValue for TerminalOutcome {
    fn canonical(&self) -> String {
        Canonical::object()
            .string("kind", self.kind.raw_value())
            .optional_string("assistantText", self.assistant_text.as_deref())
            .optional_string(
                "failureReason",
                self.failure_reason.map(FailureReason::raw_value),
            )
            .finish()
    }
}

impl CanonicalValue for SemanticResolution {
    fn canonical(&self) -> String {
        match self {
            Self::Terminal(outcome) => Canonical::object()
                .string("resolution", "terminal")
                .nested("outcome", Some(outcome))
                .finish(),
            Self::Superseded => Canonical::object()
                .string("resolution", "superseded")
                .finish(),
        }
    }
}

impl CanonicalValue for ExecutionReport {
    fn canonical(&self) -> String {
        let trace = self
            .trace
            .iter()
            .map(|event| match event {
                ExecutionTraceEvent::ExecutionStarted => json_string("executionStarted"),
                ExecutionTraceEvent::TerminalOutcomeProduced(kind) => {
                    json_string(&format!("terminalOutcomeProduced:{}", kind.raw_value()))
                }
                ExecutionTraceEvent::ExecutionSuperseded => json_string("executionSuperseded"),
            })
            .collect::<Vec<_>>()
            .join(",");
        let mut object = Canonical::object();
        match &self.result {
            ExecutionResult::Terminal(outcome) => {
                object
                    .string("result", "terminal")
                    .nested("outcome", Some(outcome));
            }
            ExecutionResult::Superseded => {
                object.string("result", "superseded").raw("outcome", "null");
            }
        }
        object.raw("trace", &format!("[{trace}]")).finish()
    }
}

impl CanonicalValue for ProcessIdentityState {
    fn canonical(&self) -> String {
        Canonical::object()
            .optional_uuid("runID", self.run_id())
            .u64("terminalDrainGeneration", self.terminal_drain_generation())
            .finish()
    }
}

impl CanonicalValue for TerminalCommitState {
    fn canonical(&self) -> String {
        Canonical::object()
            .bool("isInProgress", self.is_in_progress())
            .nested(
                "stagedReceipt",
                self.staged_receipt().map(|receipt| receipt as _),
            )
            .nested(
                "publicationResult",
                self.publication_result().map(|result| result as _),
            )
            .finish()
    }
}

impl CanonicalValue for LifecycleTracker {
    fn canonical(&self) -> String {
        Canonical::object()
            .nested(
                "activeOwnership",
                self.active_ownership().map(|ownership| ownership as _),
            )
            .nested("liveness", self.liveness().map(|liveness| liveness as _))
            .optional_uuid("processRunID", self.process_run_id())
            .u64("terminalDrainGeneration", self.terminal_drain_generation())
            .bool(
                "terminalCommitInProgress",
                self.terminal_commit_in_progress(),
            )
            .nested(
                "terminalCommitReceipt",
                self.terminal_commit_receipt().map(|receipt| receipt as _),
            )
            .nested(
                "terminalCommitPublicationResult",
                self.terminal_commit_publication_result()
                    .map(|result| result as _),
            )
            .finish()
    }
}

impl CanonicalValue for TerminalSettlementCoordinator {
    fn canonical(&self) -> String {
        Canonical::object()
            .u64(
                "consumedProviderSuccessorCount",
                u64::try_from(self.consumed_provider_successor_count()).unwrap_or(u64::MAX),
            )
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_run_lifecycle::types::{EpochTransitionKind, LifecycleStage, RetryIntent};

    fn uuid(byte: u8) -> RunUuid {
        RunUuid::from_bytes([byte; 16])
    }

    #[test]
    fn renders_fixed_key_order_and_escapes_like_serde_json() {
        let ownership = Ownership {
            attempt_id: uuid(1),
            binding: BindingIdentity {
                tab_id: uuid(2),
                persistent_session_id: None,
                persistent_binding_generation: Some(uuid(3)),
                binding_transition_generation: 4,
                generation: uuid(5),
            },
            turn_epoch: Some(TurnEpoch {
                runtime_id: uuid(6),
                runtime_generation: 7,
                session_id: uuid(8),
                activation_id: uuid(9),
                registration_generation: 10,
                id: uuid(11),
                ordinal: 12,
                continuity_generation: 13,
                transition_kind: EpochTransitionKind::RelatedFollowUp,
            }),
        };
        let rendered = ownership.canonical();
        assert!(rendered.starts_with(
            "{\"attemptID\":\"01010101-0101-0101-0101-010101010101\",\"binding\":{\"tabID\":"
        ));
        assert!(
            rendered.contains(
                "\"persistentSessionID\":null,\"persistentBindingGeneration\":\"03030303"
            )
        );
        assert!(rendered.ends_with("\"transitionKind\":\"relatedFollowUp\"}}"));

        let outcome = TerminalOutcome::failed(Some("a\"b\\c\n/é".into()), FailureReason::Timeout);
        assert_eq!(
            outcome.canonical(),
            "{\"kind\":\"failed\",\"assistantText\":\"a\\\"b\\\\c\\n/é\",\"failureReason\":\"timeout\"}"
        );

        let snapshot = LivenessSnapshot {
            ownership,
            stage: LifecycleStage::Running,
            retry_intent: RetryIntent::None,
            last_accepted_sequence: 1,
            last_signal_uptime_nanoseconds: 2,
            last_real_progress_uptime_nanoseconds: 3,
            last_heartbeat_uptime_nanoseconds: None,
        };
        assert!(
            ProgressAcceptance::Accepted(snapshot)
                .canonical()
                .starts_with("{\"acceptance\":\"accepted\",\"snapshot\":{\"ownership\":")
        );
        assert_eq!(
            TerminalSettlementCoordinator::new().canonical(),
            "{\"consumedProviderSuccessorCount\":0}"
        );
    }
}
