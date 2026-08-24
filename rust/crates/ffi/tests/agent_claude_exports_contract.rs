//! P6-6 done-when: "no export accepts a single protocol line (INV-P6-1), asserted against
//! `exports.txt`". A mechanical, file-content assertion rather than a prose claim -- see
//! `docs/architecture/rust-agent-claude-v1.md` §1.1 and design §3.3.

const EXPORTS: &str = include_str!("../../../ffi-contract/exports.txt");

const EXPECTED_AGENT_CLAUDE_EXPORTS: &[&str] = &[
    "CoreRuntime.agentOpenScope(RuntimeIdentity, CoreAgentClaudeScopeConfigV1) throws -> AgentClaudeScopeHandleV1",
    "CoreRuntime.agentStartOrResume(RuntimeIdentity, string, string?) throws -> AgentClaudeStartReceiptV1",
    "CoreRuntime.agentSendUserMessage(RuntimeIdentity, string, string) throws -> u64",
    "CoreRuntime.agentInterruptTurn(RuntimeIdentity, string, u64, string) throws -> AgentClaudeInterruptReceiptV1",
    "CoreRuntime.agentRespondPermission(RuntimeIdentity, string, string, AgentClaudePermissionDecisionV1) throws",
    "CoreRuntime.agentApplyModelAndEffort(RuntimeIdentity, string, string?, string?) throws -> AgentClaudeFlagSettingsReceiptV1",
    "CoreRuntime.agentShutdown(RuntimeIdentity, string) throws",
];

#[test]
fn every_named_agent_claude_export_is_present_in_the_reviewable_inventory() {
    for expected in EXPECTED_AGENT_CLAUDE_EXPORTS {
        assert!(EXPORTS.contains(expected), "exports.txt is missing or has drifted from the frozen signature: {expected}");
    }
}

#[test]
fn no_agent_claude_export_accepts_a_single_protocol_line() {
    // A raw NDJSON protocol line can only cross an export boundary as an opaque `bytes` (or a
    // line-shaped `string`) parameter -- none of this vertical's seven exports use `bytes` at all;
    // they take typed records, plain strings (scope ids, user-message text, interrupt reasons --
    // never raw wire content), u64 generations, and a decision enum.
    let agent_claude_lines: Vec<&str> = EXPORTS.lines().filter(|line| line.contains("CoreRuntime.agent")).collect();
    assert_eq!(agent_claude_lines.len(), EXPECTED_AGENT_CLAUDE_EXPORTS.len(), "unexpected agent-claude export count in exports.txt: {agent_claude_lines:?}");
    for line in agent_claude_lines {
        assert!(!line.contains("bytes"), "an agent-claude export takes a raw `bytes` parameter, which INV-P6-1 forbids for production exports: {line}");
    }
}

#[test]
fn the_debug_only_per_line_shadow_symbol_never_appears_in_the_uniffi_exports_inventory() {
    // `agent_claude_decode_line_debug_v1` (P6-5) is DEBUG-feature-gated and, by construction (not
    // merely omission -- see `agent_claude::debug_shadow_ffi`'s module doc), never a UniFFI export
    // at all: it is a hand-declared `extern "C"` symbol that `cargo run -p xtask -- generate` never
    // sees. It must never be added here as an actual export line (the symbol name may legitimately
    // appear in a `#`-prefixed explanatory comment, as it does above -- only export lines matter).
    let export_lines: Vec<&str> = EXPORTS.lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('#')).collect();
    for line in &export_lines {
        assert!(!line.to_lowercase().contains("decodelinedebug"), "a debug-only per-line symbol leaked into an actual export line: {line}");
        assert!(!line.contains("agent_claude_decode_line_debug_v1"), "a debug-only per-line symbol leaked into an actual export line: {line}");
    }
}
