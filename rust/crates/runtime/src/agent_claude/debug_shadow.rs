//! P6-5 (design §3.4's "codec, on live bytes" rung, `docs/architecture/rust-agent-claude-v1.md`
//! §9/§14): the session-scoped codec+translator wrapper the DEBUG-only per-line shadow arm calls.
//! **This module is cargo-only and has zero FFI dependency itself** -- the raw `extern "C"` symbol
//! that exposes it to Swift lives in [`super::debug_shadow_ffi`], gated separately
//! (`#[cfg(debug_assertions)]`) so this module's own tests run in every build profile while the FFI
//! surface exists in none but debug (INV-P6-1 §3.3: "The only per-line export that may ever exist
//! is `agent_claude_decode_line_debug_v1`... A release-build guardrail test... asserts that
//! symbol's absence from the release binary").
//!
//! **Scope, deliberately narrower than full production dispatch.** [`DebugShadowSession::decode_line`]
//! uses [`codec::decode_line_primary_only`] (module doc there), not the full [`codec::decode_line`]
//! (which also attempts the control-character sanitize-and-retry pass) or any of the four D-1
//! recovery heuristics. The live shadow arm's job is validating primary codec+translator semantics
//! on **real OS-level `read()` chunk boundaries** the P6-3 corpus (captured post-framing) cannot
//! exercise (design §3.4) -- not re-proving D-1/D-2, which the corpus differential, the
//! `claude-ndjson-v1` fuzz target, and P6-4's synthetic-CLI matrix already cover exhaustively for
//! exactly this reason (design §3.4: "chunk-boundary behaviour is covered in three other places,
//! each better suited to it than a captured corpus"). A line that needs repair or recovery is
//! [`DebugShadowOutcome::NotComparable`] here, and the Swift-side comparator is expected to apply
//! the identical gate (a plain `JSONSerialization` decode, no repair) before ever calling in, so
//! both arms agree on which lines are in scope without duplicating comparator logic on both sides
//! of the FFI.

use serde_json::Map;

use super::codec::{self, InboundMessage};
use super::tool_owned;
use super::translator::{StreamResult, Translator, should_suppress_user_facing_stream_result};

#[derive(Debug, Clone, PartialEq)]
pub enum DebugShadowOutcome {
    /// Primary decode failed (would need §2.1's repair pass or a D-1 heuristic) -- out of the live
    /// shadow arm's scope by construction (module doc).
    NotComparable,
    /// A control envelope (`control_request`/`control_response`/`control_cancel_request`/
    /// `keep_alive`) or an empty/all-whitespace line -- never produces a `StreamResult`, so trivially
    /// comparable against an equally-empty Swift-side sequence without this module doing any work.
    NonStream,
    /// The translated, D-2-suppression-filtered event sequence for a `.streamPayload` line --
    /// exactly what production `handleStreamPayload` (`:1269-1390`) would emit to the transcript
    /// event stream for this one line (minus the turn-completion bookkeeping, which is
    /// [`super::turn_state`]'s concern, not this module's -- see that module's doc for why the live
    /// shadow arm does not need it either).
    Stream(Vec<StreamResult>),
}

/// One instance per live Claude session for the lifetime the DEBUG shadow comparator is attached
/// (opened alongside the real controller's session, closed at its shutdown). Holds its own
/// [`Translator`] state (`tool_name_by_tool_use_id`) entirely independent of the live controller's
/// translator instance -- this module never touches the controller's private state, only observes
/// the same raw bytes it does (mirrors P4-5's `WorkspaceInventoryScopeShadowForwarder`: an
/// independent shadow computation from the same inputs, not a hook into the authority's internals).
pub struct DebugShadowSession {
    translator: Translator,
}

impl Default for DebugShadowSession {
    fn default() -> Self {
        Self::new()
    }
}

impl DebugShadowSession {
    pub fn new() -> Self {
        // Matches production wiring exactly (contract §8, `ClaudeSDKNDJSONTranslator.init`, which
        // wires `MCPIntegrationHelper.isRepoPromptToolName`) -- NOT `Translator::default`'s `|_|
        // false` stub, which would make every RepoPrompt-owned tool_result's `tool_is_error` diverge
        // from the live Swift arm's `None` (contract §2.7: host-owned tool errors are never
        // inferred here).
        Self { translator: Translator::new(Box::new(tool_owned::is_repoprompt_tool_name)) }
    }

    pub fn decode_line(&mut self, line: &[u8]) -> DebugShadowOutcome {
        match codec::decode_line_primary_only(line) {
            Ok(Some(InboundMessage::StreamPayload(payload))) => {
                DebugShadowOutcome::Stream(self.translate_and_suppress(&payload))
            }
            Ok(_) => DebugShadowOutcome::NonStream,
            Err(_) => DebugShadowOutcome::NotComparable,
        }
    }

    fn translate_and_suppress(&mut self, payload: &Map<String, serde_json::Value>) -> Vec<StreamResult> {
        let mut results = self.translator.parse_stream_payload(payload);
        results.retain(|result| !should_suppress_user_facing_stream_result(result));
        results
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn line(value: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    #[test]
    fn a_stream_payload_translates_and_applies_d2_suppression() {
        let mut session = DebugShadowSession::new();
        let outcome = session.decode_line(&line(json!({
            "type": "system", "subtype": "task_started", "task_id": "t-1"
        })));
        assert_eq!(outcome, DebugShadowOutcome::Stream(Vec::new()), "Task started must be suppressed, not surfaced");

        let outcome = session.decode_line(&line(json!({
            "type": "assistant", "message": {"content": [{"type": "text", "text": "hello"}]}
        })));
        match outcome {
            DebugShadowOutcome::Stream(results) => {
                assert_eq!(results.len(), 1);
                assert_eq!(results[0].kind, "content");
                assert_eq!(results[0].text.as_deref(), Some("hello"));
            }
            other => panic!("expected Stream, got {other:?}"),
        }
    }

    #[test]
    fn a_control_envelope_line_is_non_stream_not_a_mismatch() {
        let mut session = DebugShadowSession::new();
        assert_eq!(
            session.decode_line(br#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool"}}"#),
            DebugShadowOutcome::NonStream
        );
        assert_eq!(session.decode_line(b""), DebugShadowOutcome::NonStream);
    }

    #[test]
    fn malformed_json_is_not_comparable_not_a_mismatch() {
        let mut session = DebugShadowSession::new();
        assert_eq!(session.decode_line(b"{not json"), DebugShadowOutcome::NotComparable);
    }

    #[test]
    fn repoprompt_owned_tool_result_errors_are_not_inferred_matching_production_wiring() {
        let mut session = DebugShadowSession::new();
        session.decode_line(&line(json!({
            "type": "assistant",
            "message": {"content": [{"type": "tool_use", "id": "toolu_1", "name": "read_file", "input": {}}]}
        })));
        let outcome = session.decode_line(&line(json!({
            "type": "user",
            "message": {"content": [{
                "type": "tool_result",
                "tool_use_id": "toolu_1",
                "is_error": true,
                "content": [{"type": "text", "text": "contents"}]
            }]}
        })));
        match outcome {
            DebugShadowOutcome::Stream(results) => {
                assert_eq!(results.len(), 1);
                assert_eq!(
                    results[0].tool_is_error, None,
                    "read_file is RepoPrompt-owned: production never infers tool_is_error for it, even given an explicit is_error field upstream of the host's own tracking"
                );
            }
            other => panic!("expected Stream, got {other:?}"),
        }
    }

    #[test]
    fn tool_use_and_tool_result_correlation_persists_across_calls_on_the_same_session() {
        let mut session = DebugShadowSession::new();
        session.decode_line(&line(json!({
            "type": "assistant",
            "message": {"content": [{"type": "tool_use", "id": "toolu_9", "name": "Bash", "input": {"command": "ls"}}]}
        })));
        let outcome = session.decode_line(&line(json!({
            "type": "user",
            "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_9", "content": "ok"}]}
        })));
        match outcome {
            DebugShadowOutcome::Stream(results) => {
                assert_eq!(results[0].tool_name.as_deref(), Some("Bash"), "the tool name must resolve from the earlier tool_use, proving session state persists across decode_line calls");
            }
            other => panic!("expected Stream, got {other:?}"),
        }
    }
}
