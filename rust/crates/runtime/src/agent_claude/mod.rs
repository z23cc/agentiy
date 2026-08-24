//! P6-3 (`docs/designs/p6-claude-vertical-2026-08-23.md` §3.4/§11, `docs/architecture/
//! rust-agent-claude-v1.md`) -- the Rust codec + translator + framer for the standard Claude
//! Code (`claudeCode`) vertical, ported cargo-only with **zero FFI dependency** (INV-P6-1 holds
//! trivially: no export exists yet). Consumed *inside* Rust starting at P6-4/P6-6, never exposed
//! per protocol line/NDJSON payload/stream token in production (INV-P6-1).
//!
//! Module map:
//! - [`framer`] -- `LineFramer` + `repairJSONStringControlCharacters` port (contract §5.3/§5.4/§6).
//! - [`codec`] -- `ClaudeSDKProtocolCodec` port: envelope layer, control request/response/cancel/
//!   keep-alive, outbound encodings (contract §2.1/§2.2).
//! - [`recovery`] -- the four D-1 decode-recovery heuristics (contract §6).
//! - [`translator`] -- `ClaudeSDKNDJSONTranslator` port: the inbound message-type catalog, usage
//!   parsing, tool-result error inference, D-2 suppression (contract §2.3-§2.8).
//! - [`tool_owned`] -- the host-owned-tool-name predicate, ported as data (contract §8).
//! - [`control`] -- P6-5: control-request correlation + timeouts (contract §2.2).
//! - [`permission`] -- P6-5: the `can_use_tool` **protocol** half only (contract §7.1/design §3.2's
//!   ownership split; policy stays Swift).
//! - [`turn_state`] -- P6-5: the §4.5 turn lifecycle / terminal-event authority state machine.
//! - [`resnapshot`] -- P6-5 (design D-8): the new per-turn resnapshot buffer.
//! - [`event`] -- P6-6: the versioned, batched event envelope (design D-6) and the contract §7.1
//!   event-catalog loss classification, including the `sessionStateChanged(idle)` trap.
//! - [`raw_event_log`] -- P6-7 (D-9/R9): the Rust-side reproduction of Swift's DEBUG-only raw-event
//!   JSONL log, behind the same `app_settings` keys (contract §10, `rust-agent-claude-v1.md` §15.6).
//! - [`scope`] -- P6-6: `AgentClaudeScope`/`ScopeRegistry`, the stateful integration object the FFI
//!   crate's exports (this step's next commit) call into -- wires every module above into one live
//!   session, publishing through the shared `SubscriptionHub` (contract §5.1).

pub mod codec;
pub mod control;
pub mod event;
pub mod framer;
pub mod permission;
pub mod process;
pub mod raw_event_log;
pub mod recovery;
pub mod resnapshot;
pub mod scope;
pub mod tool_owned;
pub mod translator;
pub mod turn_state;

#[cfg(test)]
mod tests;

pub use codec::{CodecError, ControlRequest, ControlResponse, InboundMessage, decode_line};
pub use control::{
    ControlCorrelator, ControlOutcome, send_control_request, send_control_request_without_response,
};
pub use framer::{
    FramerDiagnostic, FramerLimits, LineFramer, repair_json_string_control_characters,
};
pub use permission::{
    CanUseToolRequest, PermissionDecision, encode_permission_decision,
    encode_unsupported_subtype_response, parse_can_use_tool_request,
};
pub use raw_event_log::{RawEventLogContext, RawEventLogWriter};
pub use recovery::{RecoveryDiagnostic, RecoveryOutcome, recover_invalid_json_line};
pub use resnapshot::{RESNAPSHOT_BUFFER_CAP_BYTES, ResnapshotBuffer, ResnapshotTruncated};
pub use scope::{
    AgentClaudeScope, AgentClaudeScopeConfig, AgentClaudeScopeDiagnostics, AgentClaudeScopeId,
    AgentScopeError, FlagSettingsDisposition, PermissionDecisionInput, ScopeRegistry,
    ScopeRegistryError, StartReceipt,
};
pub use translator::{
    InvocationId, LIFECYCLE_TYPE, StreamResult, Translator,
    should_suppress_user_facing_stream_result,
};
pub use turn_state::{TurnDiagnostic, TurnEvent, TurnState, TurnStatus};

/// `ClaudeReasoningExtractionFeature.isEnabled` (`ClaudeReasoningDiagnostics.swift:3-5`) -- a
/// hardcoded-`false` feature flag in the Swift source today, not a runtime toggle. Ported as the
/// same compile-time constant rather than a configurable flag, matching the Swift source exactly;
/// flip both sides together if the feature is ever enabled upstream.
pub const REASONING_EXTRACTION_ENABLED: bool = false;
