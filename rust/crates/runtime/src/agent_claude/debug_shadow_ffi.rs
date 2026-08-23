//! P6-5 (design §3.3 INV-P6-1, §11 P6-5's done-when; `docs/architecture/rust-agent-claude-v1.md`
//! §14): the **sole per-line production-adjacent export this vertical ever carries**, and it is not
//! a production export at all -- `#[cfg(debug_assertions)]` gates this entire module out of every
//! release build. INV-P6-1: "The only per-line export that may ever exist is
//! `agent_claude_decode_line_debug_v1`, DEBUG-feature-gated, used solely by the P6-5 shadow arm. A
//! release-build guardrail test (landed at P6-5) asserts that symbol's absence from the release
//! binary."
//!
//! **Why this is a raw `extern "C"` symbol and not a `#[uniffi::export]`.** The codegen protocol
//! (`cargo run -p xtask -- generate` on every rust-touching commit, checked-in bindings under
//! `Sources/AgentryUniFFIRaw/Generated`) must stay byte-identical between debug and release --
//! `#[cfg(debug_assertions)]` on a `#[uniffi::export]` would make codegen's *output* differ by
//! profile (the checked-in Swift wrapper would reference a symbol a release static archive does not
//! contain), which is exactly the failure mode a checked-in-bindings workflow cannot tolerate. A
//! hand-declared C symbol, called from a hand-written `#if DEBUG`-gated Swift declaration (see
//! `Sources/CAgentryRustCore`), never enters UniFFI's scaffolding at all: `cargo run -p xtask --
//! generate` never sees it, so its output is identical regardless of which profile built the .a it
//! was run against. `exports.txt`/`abi-v1.json` (the UniFFI contract surface) correctly never
//! enumerate it either -- it *is not* a UniFFI export, by construction, not merely by omission.
//!
//! **Why this crate, not `agentry-ffi`.** `rust/crates/ffi/src/lib.rs:3` carries
//! `#![forbid(unsafe_code)]`, and `forbid` cannot be downgraded by any inner `#[allow(...)]`
//! (`agentry-runtime/src/lib.rs`'s own doc comment explains the same constraint for why *that*
//! crate downgraded to `deny`). A raw C-ABI function taking `(ptr, len)` byte-buffer arguments needs
//! `unsafe` to dereference them, so it cannot live in `agentry-ffi`. It lives here instead, in
//! `agentry-runtime` (already `#![deny(unsafe_code)]` with two precedented scoped exceptions,
//! `process::addchdir` and `process::reaper::waitid_probe`) -- and reaches the final
//! `libagentry_ffi.a` anyway, because `agentry-runtime` is a normal dependency of the `agentry-ffi`
//! staticlib crate: `#[unsafe(no_mangle)]` forces external linkage on any symbol in a staticlib's
//! dependency graph regardless of whether anything in the crate root calls it, exactly the same
//! mechanism `cbindgen`/UniFFI-generated crates rely on. No change to `agentry-ffi` is needed.
//! `Scripts/rust_ffi_guardrails.py` is extended to assert this module's `#[cfg(debug_assertions)]`
//! gate mechanically (the class of check this repo already uses for equivalent invariants, e.g.
//! P4-5's `testShadowArmParameterIsAbsentFromTheReleaseInitializer` on the Swift side) rather than
//! requiring an actual release `cargo build` inside a test.
//!
//! **Third `#[allow(unsafe_code)]` site.** This module is the crate's third, alongside the two
//! named above -- `Scripts/rust_ffi_guardrails.py`'s site count is updated from two to three in this
//! same commit, with this module cited as the reason.
//!
//! **Ownership model.** `agent_claude_debug_shadow_open_v1` allocates one
//! [`super::debug_shadow::DebugShadowSession`] behind an opaque `u64` handle; every subsequent
//! `agent_claude_decode_line_debug_v1(handle, ...)` call routes to that same session (preserving
//! its `tool_name_by_tool_use_id` correlation across the session's lifetime, `debug_shadow.rs`'s own
//! doc); `agent_claude_debug_shadow_close_v1` releases it. The decode result crosses as an
//! owned `(ptr, len)` UTF-8 JSON buffer the caller must release via
//! `agent_claude_debug_shadow_free_buffer_v1` with the exact same `(ptr, len)` -- an explicit
//! ownership-transfer pair, not a NUL-terminated C string (JSON text cannot itself contain the
//! escape-free unescaped `\0` and this module has no reason to rely on that regardless).

#![allow(unsafe_code)]

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Map, Value, json};

use super::debug_shadow::{DebugShadowOutcome, DebugShadowSession};
use super::translator::StreamResult;

static SESSIONS: Mutex<Option<HashMap<u64, DebugShadowSession>>> = Mutex::new(None);
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn with_sessions<R>(f: impl FnOnce(&mut HashMap<u64, DebugShadowSession>) -> R) -> R {
    let mut guard = SESSIONS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    f(guard.get_or_insert_with(HashMap::new))
}

/// Opens a new shadow session and returns its handle. Never returns `0` (reserved as a caller-side
/// "no handle" sentinel, matching the C convention the Swift call site uses to detect an unopened
/// comparator).
#[unsafe(no_mangle)]
pub extern "C" fn agent_claude_debug_shadow_open_v1() -> u64 {
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::SeqCst);
    with_sessions(|sessions| sessions.insert(handle, DebugShadowSession::new()));
    handle
}

/// Releases the session for `handle`. A double-close or an unknown handle is a silent no-op (the
/// DEBUG-only comparator's own lifecycle discipline is Swift-side; this function does not police
/// misuse it cannot itself cause harm from).
#[unsafe(no_mangle)]
pub extern "C" fn agent_claude_debug_shadow_close_v1(handle: u64) {
    with_sessions(|sessions| {
        sessions.remove(&handle);
    });
}

/// Decodes and translates one inbound protocol line against the named session's independent
/// [`DebugShadowSession`], returning an owned UTF-8 JSON buffer describing the outcome (module doc's
/// ownership model). Writes the buffer's length to `*out_len` and returns a pointer to its first
/// byte; the caller must pass both back to [`agent_claude_debug_shadow_free_buffer_v1`] exactly
/// once.
///
/// # Safety
/// `line_ptr` must be valid for reads of `line_len` bytes for the duration of this call and is not
/// retained past return. `out_len` must be a valid, non-null, properly aligned pointer to a `usize`
/// the caller owns for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agent_claude_decode_line_debug_v1(
    handle: u64,
    line_ptr: *const u8,
    line_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    // SAFETY: `line_ptr`/`line_len` are valid for the duration of this call per this function's
    // documented preconditions, which the DEBUG-only Swift comparator (the only caller, module doc)
    // upholds.
    let line: &[u8] = if line_len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(line_ptr, line_len) } };
    let json_text = with_sessions(|sessions| match sessions.get_mut(&handle) {
        Some(session) => outcome_to_json(&session.decode_line(line)),
        None => json!({"kind": "unknown_handle"}).to_string(),
    });
    let mut bytes = json_text.into_bytes();
    bytes.shrink_to_fit();
    let len = bytes.len();
    let ptr = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    // SAFETY: `out_len` is a valid, non-null, properly-aligned, caller-owned `*mut usize` per this
    // function's documented preconditions.
    unsafe {
        *out_len = len;
    }
    ptr
}

/// Releases a buffer previously returned by [`agent_claude_decode_line_debug_v1`].
///
/// # Safety
/// `ptr`/`len` must be exactly the pair most recently returned via that function's return value and
/// its `out_len` output, and must not already have been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn agent_claude_debug_shadow_free_buffer_v1(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: `ptr`/`len` name a `Vec<u8>` allocation this module itself produced and forgot inside
    // `agent_claude_decode_line_debug_v1`, per this function's documented preconditions.
    unsafe {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

fn outcome_to_json(outcome: &DebugShadowOutcome) -> String {
    let value = match outcome {
        DebugShadowOutcome::NotComparable => json!({"kind": "not_comparable"}),
        DebugShadowOutcome::NonStream => json!({"kind": "non_stream"}),
        DebugShadowOutcome::Stream(results) => {
            json!({"kind": "stream", "results": results.iter().map(stream_result_to_json).collect::<Vec<_>>()})
        }
    };
    value.to_string()
}

/// Field-for-field mirror of `translator.rs`'s [`StreamResult`], **excluding**
/// `tool_invocation_id` -- a Rust-synthetic `InvocationId(u64)` (`translator.rs`'s own module doc)
/// that can never structurally match Swift's `UUID`; the Swift-side comparator normalizes tool
/// correlation by *relative* identity (does each arm reuse the same synthetic ID for a `tool_call`
/// and its matching `tool_result`, independently within its own arm) rather than by cross-arm value
/// equality, so the raw value is intentionally not part of this wire shape at all.
fn stream_result_to_json(result: &StreamResult) -> Value {
    let mut map = Map::new();
    map.insert("kind".to_string(), Value::String(result.kind.clone()));
    insert_opt_string(&mut map, "text", &result.text);
    insert_opt_string(&mut map, "reasoning", &result.reasoning);
    insert_opt_i64(&mut map, "promptTokens", result.prompt_tokens);
    insert_opt_i64(&mut map, "completionTokens", result.completion_tokens);
    if let Some(cost) = result.cost {
        map.insert("cost".to_string(), json!(cost));
    }
    insert_opt_string(&mut map, "toolName", &result.tool_name);
    insert_opt_string(&mut map, "toolArgs", &result.tool_args);
    insert_opt_string(&mut map, "toolOutput", &result.tool_output);
    insert_opt_string(&mut map, "toolResultJSON", &result.tool_result_json);
    insert_opt_string(&mut map, "toolArgsJSON", &result.tool_args_json);
    if let Some(is_error) = result.tool_is_error {
        map.insert("toolIsError".to_string(), Value::Bool(is_error));
    }
    insert_opt_string(&mut map, "providerSessionID", &result.provider_session_id);
    insert_opt_string(&mut map, "stopReason", &result.stop_reason);
    insert_opt_i64(&mut map, "modelContextWindow", result.model_context_window);
    insert_opt_i64(&mut map, "contextUsedTokens", result.context_used_tokens);
    insert_opt_string(&mut map, "contentMessageID", &result.content_message_id);
    Value::Object(map)
}

fn insert_opt_string(map: &mut Map<String, Value>, key: &str, value: &Option<String>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::String(value.clone()));
    }
}

fn insert_opt_i64(map: &mut Map<String, Value>, key: &str, value: Option<i64>) {
    if let Some(value) = value {
        map.insert(key.to_string(), json!(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exercises the raw FFI surface exactly the way the DEBUG-only Swift comparator does: open,
    /// decode a couple of lines through the SAME handle (proving session-state persistence crosses
    /// the FFI boundary, not just within `DebugShadowSession` directly, `debug_shadow.rs`'s own
    /// test), read back the JSON, free the buffer, close.
    #[test]
    fn open_decode_free_close_round_trips_and_preserves_tool_correlation_across_ffi_calls() {
        let handle = agent_claude_debug_shadow_open_v1();
        assert_ne!(handle, 0);

        let tool_use_line = br#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#;
        let json_one = decode_via_ffi(handle, tool_use_line);
        assert_eq!(json_one["kind"], "stream");
        assert_eq!(json_one["results"][0]["kind"], "tool_call");

        let tool_result_line = br#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#;
        let json_two = decode_via_ffi(handle, tool_result_line);
        assert_eq!(
            json_two["results"][0]["toolName"], "Bash",
            "the tool name must resolve across the FFI boundary from the earlier tool_use on the same handle"
        );

        agent_claude_debug_shadow_close_v1(handle);
    }

    #[test]
    fn an_unknown_handle_reports_unknown_handle_rather_than_crashing() {
        let json = decode_via_ffi(999_999, b"{}");
        assert_eq!(json["kind"], "unknown_handle");
    }

    #[test]
    fn an_empty_line_is_non_stream_via_the_zero_length_fast_path() {
        let handle = agent_claude_debug_shadow_open_v1();
        let json = decode_via_ffi(handle, b"");
        assert_eq!(json["kind"], "non_stream");
        agent_claude_debug_shadow_close_v1(handle);
    }

    fn decode_via_ffi(handle: u64, line: &[u8]) -> Value {
        let mut out_len: usize = 0;
        let ptr = unsafe { agent_claude_decode_line_debug_v1(handle, line.as_ptr(), line.len(), &mut out_len) };
        let bytes = unsafe { std::slice::from_raw_parts(ptr, out_len) };
        let value: Value = serde_json::from_slice(bytes).expect("valid JSON");
        unsafe { agent_claude_debug_shadow_free_buffer_v1(ptr, out_len) };
        value
    }
}
