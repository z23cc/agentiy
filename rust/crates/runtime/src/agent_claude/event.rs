//! P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §5.2, `docs/architecture/
//! rust-agent-claude-v1.md` §7.1): the versioned, batched event envelope that crosses the FFI for
//! the Claude vertical (design D-6: "Stream results cross as a versioned compact payload rather
//! than as `AIStreamResult` structs... field-for-field"). Unlike `inventory_scope::wire`'s
//! fixed-stride binary word tables (justified there by very-high-volume small structs), this
//! module hand-encodes a small JSON object per event via `serde_json::Map` -- the same idiom
//! `codec.rs`/`permission.rs`/`translator.rs` already use for the protocol layer, and adequate
//! here because agent-claude events are comparatively low-volume, text-shaped payloads, not a
//! per-line hot path (INV-P6-1 already forecloses that; this envelope only ever carries *batched*,
//! already-decoded facts). Promoting `serde` derive from a dev-dependency to a real one was
//! considered and rejected to avoid a needless dependency-surface delta for this slice.
//!
//! Every encoded event is a JSON object `{"v":1,"kind":"<name>", ...kind-specific fields}`, plus
//! `"turn_id"` when the event is turn-scoped. `AgentClaudeEvent::classification()` maps each kind
//! to the contract §7.1 event catalog's `(EventClass, coalesce_key, terminal_reserve)` triple --
//! this is where the `sessionStateChanged(idle)` trap (design §5.2/§7.1) is implemented: the
//! `SessionStateChanged` kind's classification depends on its own `is_idle` field, not on the kind
//! alone, so a non-`idle` status ping and the turn-boundary-releasing `idle` fact are never
//! conflated into the same pressure-policy treatment.

use serde_json::{Map, Value, json};

use crate::EventClass;

use super::permission::CanUseToolRequest;
use super::turn_state::TurnStatus;

/// Wire version for this envelope shape. Bump alongside a documented compatibility note if a
/// future step changes field shapes rather than only adding new ones.
pub const AGENT_CLAUDE_EVENT_WIRE_VERSION: u64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentClaudeEventKind {
    AssistantDelta,
    ReasoningDelta,
    ToolUseStarted,
    ToolResult,
    ApprovalRequest,
    ApprovalCancelled,
    TurnCompleted,
    InterruptOutcome,
    RuntimeInit,
    TaskProgress,
    SessionStateChanged,
    StderrTail,
    FramerOverflow,
    ProtocolDrift,
    TranscriptTruncated,
    Error,
}

impl AgentClaudeEventKind {
    #[must_use]
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::AssistantDelta => "assistantDelta",
            Self::ReasoningDelta => "reasoningDelta",
            Self::ToolUseStarted => "toolUseStarted",
            Self::ToolResult => "toolResult",
            Self::ApprovalRequest => "approvalRequest",
            Self::ApprovalCancelled => "approvalCancelled",
            Self::TurnCompleted => "turnCompleted",
            Self::InterruptOutcome => "interruptOutcome",
            Self::RuntimeInit => "runtimeInit",
            Self::TaskProgress => "taskProgress",
            Self::SessionStateChanged => "sessionStateChanged",
            Self::StderrTail => "stderrTail",
            Self::FramerOverflow => "framerOverflow",
            Self::ProtocolDrift => "protocolDrift",
            Self::TranscriptTruncated => "transcriptTruncated",
            Self::Error => "error",
        }
    }
}

/// One already-decoded fact ready to cross the FFI. `fields` carries the kind-specific payload;
/// `turn_id`, when present, is threaded onto the wire as a top-level `"turn_id"` field so a Swift
/// decoder never has to reach into a kind-specific sub-object to correlate an event to a turn.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentClaudeEvent {
    pub kind: AgentClaudeEventKind,
    pub turn_id: Option<u64>,
    pub fields: Map<String, Value>,
}

impl AgentClaudeEvent {
    #[must_use]
    pub fn new(kind: AgentClaudeEventKind) -> Self {
        Self { kind, turn_id: None, fields: Map::new() }
    }

    #[must_use]
    pub fn with_turn_id(mut self, turn_id: u64) -> Self {
        self.turn_id = Some(turn_id);
        self
    }

    #[must_use]
    pub fn with_field(mut self, key: &str, value: impl Into<Value>) -> Self {
        self.fields.insert(key.to_string(), value.into());
        self
    }

    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut object = self.fields.clone();
        object.insert("v".to_string(), json!(AGENT_CLAUDE_EVENT_WIRE_VERSION));
        object.insert("kind".to_string(), json!(self.kind.wire_name()));
        if let Some(turn_id) = self.turn_id {
            object.insert("turn_id".to_string(), json!(turn_id));
        }
        serde_json::to_vec(&Value::Object(object)).unwrap_or_default()
    }

    /// Decodes a previously-encoded event back into its wire shape, for tests and for a future
    /// Swift-parity differential (design D-6: "the differential asserts the decoded Swift value
    /// equals today's"). Fail-closed: an unrecognized `"kind"` or missing `"v"` is `None` rather
    /// than a best-effort partial decode.
    #[must_use]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let Value::Object(mut object) = serde_json::from_slice(bytes).ok()? else { return None };
        let version = object.remove("v")?.as_u64()?;
        if version != AGENT_CLAUDE_EVENT_WIRE_VERSION {
            return None;
        }
        let kind_name = object.remove("kind")?;
        let kind_name = kind_name.as_str()?;
        let kind = match kind_name {
            "assistantDelta" => AgentClaudeEventKind::AssistantDelta,
            "reasoningDelta" => AgentClaudeEventKind::ReasoningDelta,
            "toolUseStarted" => AgentClaudeEventKind::ToolUseStarted,
            "toolResult" => AgentClaudeEventKind::ToolResult,
            "approvalRequest" => AgentClaudeEventKind::ApprovalRequest,
            "approvalCancelled" => AgentClaudeEventKind::ApprovalCancelled,
            "turnCompleted" => AgentClaudeEventKind::TurnCompleted,
            "interruptOutcome" => AgentClaudeEventKind::InterruptOutcome,
            "runtimeInit" => AgentClaudeEventKind::RuntimeInit,
            "taskProgress" => AgentClaudeEventKind::TaskProgress,
            "sessionStateChanged" => AgentClaudeEventKind::SessionStateChanged,
            "stderrTail" => AgentClaudeEventKind::StderrTail,
            "framerOverflow" => AgentClaudeEventKind::FramerOverflow,
            "protocolDrift" => AgentClaudeEventKind::ProtocolDrift,
            "transcriptTruncated" => AgentClaudeEventKind::TranscriptTruncated,
            "error" => AgentClaudeEventKind::Error,
            _ => return None,
        };
        let turn_id = object.remove("turn_id").and_then(|v| v.as_u64());
        Some(Self { kind, turn_id, fields: object })
    }

    /// Contract §7.1's event catalog, mapped to `(EventClass, coalesce_key, terminal_reserve)`.
    /// `terminal_reserve` selects `RuntimeEventKind::Terminal` at the publish call site (the
    /// reserved-capacity slot design names for `approvalRequest`/`approvalCancelled`/
    /// `turnCompleted`/`interruptOutcome`). The `SessionStateChanged` row is the named trap: its
    /// classification reads `is_idle` off the payload itself rather than being fixed by the kind.
    #[must_use]
    pub fn classification(&self) -> (EventClass, Option<String>, bool) {
        use AgentClaudeEventKind::{
            ApprovalCancelled, ApprovalRequest, AssistantDelta, Error, FramerOverflow, InterruptOutcome, ProtocolDrift,
            ReasoningDelta, RuntimeInit, SessionStateChanged, StderrTail, TaskProgress, ToolResult, ToolUseStarted,
            TranscriptTruncated, TurnCompleted,
        };
        match self.kind {
            AssistantDelta | ReasoningDelta | ToolUseStarted | ToolResult | Error | TranscriptTruncated => {
                (EventClass::Lossless, None, false)
            }
            ApprovalRequest | ApprovalCancelled | TurnCompleted | InterruptOutcome => (EventClass::Lossless, None, true),
            RuntimeInit => (EventClass::Coalescible, Some("runtimeInit".to_string()), false),
            TaskProgress => (EventClass::Coalescible, Some("progress".to_string()), false),
            SessionStateChanged => {
                if self.fields.get("is_idle").and_then(Value::as_bool).unwrap_or(false) {
                    (EventClass::Lossless, None, false)
                } else {
                    (EventClass::Coalescible, Some("progress".to_string()), false)
                }
            }
            StderrTail | FramerOverflow | ProtocolDrift => {
                (EventClass::Droppable, Some(format!("diag:{}", self.kind.wire_name())), false)
            }
        }
    }
}

#[must_use]
pub fn turn_completed(turn_id: u64, status: TurnStatus) -> AgentClaudeEvent {
    let status_name = match status {
        TurnStatus::Completed => "completed",
        TurnStatus::Cancelled => "cancelled",
        TurnStatus::Failed => "failed",
    };
    AgentClaudeEvent::new(AgentClaudeEventKind::TurnCompleted)
        .with_turn_id(turn_id)
        .with_field("status", status_name)
}

#[must_use]
pub fn interrupt_outcome(
    request_id: &str,
    outcome: &str,
    current_generation: u64,
    current_turn_in_flight: Option<bool>,
) -> AgentClaudeEvent {
    let mut event = AgentClaudeEvent::new(AgentClaudeEventKind::InterruptOutcome)
        .with_field("request_id", request_id)
        .with_field("outcome", outcome)
        .with_field("current_generation", current_generation);
    if let Some(in_flight) = current_turn_in_flight {
        event = event.with_field("current_turn_in_flight", in_flight);
    }
    event
}

#[must_use]
pub fn approval_request(request: &CanUseToolRequest) -> AgentClaudeEvent {
    let mut event = AgentClaudeEvent::new(AgentClaudeEventKind::ApprovalRequest)
        .with_field("request_id", request.request_id.as_str())
        .with_field("tool_name", request.tool_name.as_str())
        .with_field("input", Value::Object(request.input.clone()));
    if let Some(blocked_path) = &request.blocked_path {
        event = event.with_field("blocked_path", blocked_path.as_str());
    }
    if let Some(decision_reason) = &request.decision_reason {
        event = event.with_field("decision_reason", decision_reason.as_str());
    }
    if let Some(description) = &request.description {
        event = event.with_field("description", description.as_str());
    }
    if let Some(tool_use_id) = &request.tool_use_id {
        event = event.with_field("tool_use_id", tool_use_id.as_str());
    }
    event
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_turn_completed_event() {
        let event = turn_completed(7, TurnStatus::Cancelled).with_turn_id(7);
        let decoded = AgentClaudeEvent::decode(&event.encode()).expect("decode");
        assert_eq!(decoded.kind, AgentClaudeEventKind::TurnCompleted);
        assert_eq!(decoded.turn_id, Some(7));
        assert_eq!(decoded.fields.get("status").and_then(Value::as_str), Some("cancelled"));
    }

    #[test]
    fn turn_completed_and_interrupt_outcome_use_the_reserved_terminal_slot() {
        let (_, _, terminal) = turn_completed(1, TurnStatus::Completed).classification();
        assert!(terminal);
        let (_, _, terminal) = interrupt_outcome("r1", "acknowledged", 1, None).classification();
        assert!(terminal);
    }

    #[test]
    fn session_state_changed_classification_depends_on_is_idle_not_the_kind_alone() {
        let progress = AgentClaudeEvent::new(AgentClaudeEventKind::SessionStateChanged)
            .with_field("text", "running")
            .with_field("is_idle", false);
        let (class, key, terminal) = progress.classification();
        assert_eq!(class, EventClass::Coalescible);
        assert_eq!(key.as_deref(), Some("progress"));
        assert!(!terminal);

        let idle = AgentClaudeEvent::new(AgentClaudeEventKind::SessionStateChanged)
            .with_field("text", "idle")
            .with_field("is_idle", true);
        let (class, key, terminal) = idle.classification();
        assert_eq!(class, EventClass::Lossless, "idle is the turn-boundary trap -- must never be droppable/coalescible");
        assert_eq!(key, None);
        assert!(!terminal);
    }

    #[test]
    fn diagnostics_are_droppable_with_a_per_kind_coalesce_key() {
        let (class, key, _) = AgentClaudeEvent::new(AgentClaudeEventKind::FramerOverflow).classification();
        assert_eq!(class, EventClass::Droppable);
        assert_eq!(key.as_deref(), Some("diag:framerOverflow"));
    }

    #[test]
    fn decode_rejects_an_unknown_wire_version() {
        let mut object = Map::new();
        object.insert("v".to_string(), json!(999));
        object.insert("kind".to_string(), json!("error"));
        let bytes = serde_json::to_vec(&Value::Object(object)).unwrap();
        assert_eq!(AgentClaudeEvent::decode(&bytes), None);
    }

    #[test]
    fn decode_rejects_an_unknown_kind_fail_closed() {
        let mut object = Map::new();
        object.insert("v".to_string(), json!(AGENT_CLAUDE_EVENT_WIRE_VERSION));
        object.insert("kind".to_string(), json!("somethingFuture"));
        let bytes = serde_json::to_vec(&Value::Object(object)).unwrap();
        assert_eq!(AgentClaudeEvent::decode(&bytes), None);
    }

    #[test]
    fn approval_request_carries_every_optional_field_when_present() {
        let request = CanUseToolRequest {
            request_id: "req-1".to_string(),
            tool_name: "Bash".to_string(),
            input: Map::new(),
            blocked_path: Some("/etc/shadow".to_string()),
            decision_reason: Some("blocked".to_string()),
            description: Some("list files".to_string()),
            tool_use_id: Some("toolu_1".to_string()),
        };
        let decoded = AgentClaudeEvent::decode(&approval_request(&request).encode()).expect("decode");
        assert_eq!(decoded.fields.get("blocked_path").and_then(Value::as_str), Some("/etc/shadow"));
        assert_eq!(decoded.fields.get("tool_use_id").and_then(Value::as_str), Some("toolu_1"));
    }
}
