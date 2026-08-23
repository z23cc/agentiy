//! P6-3 (`docs/designs/p6-claude-vertical-2026-08-23.md` §3.4/§11, `docs/architecture/
//! rust-agent-claude-v1.md`) -- the Rust codec + translator + framer for the standard Claude
//! Code (`claudeCode`) vertical, ported cargo-only with **zero FFI dependency** (INV-P6-1 holds
//! trivially: no export exists yet). Consumed *inside* Rust starting at P6-4/P6-6, never exposed
//! per protocol line/NDJSON payload/stream token in production (INV-P6-1; the sole exception,
//! a DEBUG-only per-line export for the P6-5 shadow arm, is a later step's addition).
//!
//! Module map:
//! - [`framer`] -- `LineFramer` + `repairJSONStringControlCharacters` port (contract §5.3/§5.4/§6).
//! - [`codec`] -- `ClaudeSDKProtocolCodec` port: envelope layer, control request/response/cancel/
//!   keep-alive, outbound encodings (contract §2.1/§2.2).
//! - [`recovery`] -- the four D-1 decode-recovery heuristics (contract §6).
//! - [`translator`] -- `ClaudeSDKNDJSONTranslator` port: the inbound message-type catalog, usage
//!   parsing, tool-result error inference, D-2 suppression (contract §2.3-§2.8).
//! - [`tool_owned`] -- the host-owned-tool-name predicate, ported as data (contract §8).

pub mod codec;
pub mod framer;
pub mod recovery;
pub mod tool_owned;
pub mod translator;

#[cfg(test)]
mod tests;

pub use codec::{CodecError, ControlRequest, ControlResponse, InboundMessage, decode_line};
pub use framer::{FramerDiagnostic, FramerLimits, LineFramer, repair_json_string_control_characters};
pub use recovery::{RecoveryDiagnostic, RecoveryOutcome, recover_invalid_json_line};
pub use translator::{InvocationId, LIFECYCLE_TYPE, StreamResult, Translator, should_suppress_user_facing_stream_result};

/// `ClaudeReasoningExtractionFeature.isEnabled` (`ClaudeReasoningDiagnostics.swift:3-5`) -- a
/// hardcoded-`false` feature flag in the Swift source today, not a runtime toggle. Ported as the
/// same compile-time constant rather than a configurable flag, matching the Swift source exactly;
/// flip both sides together if the feature is ever enabled upstream.
pub const REASONING_EXTRACTION_ENABLED: bool = false;
