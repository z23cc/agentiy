#![no_main]

use agentry_runtime::agent_claude::event::AgentClaudeEvent;
use libfuzzer_sys::fuzz_target;

// P6-6 (`docs/designs/p6-claude-vertical-2026-08-23.md` §11 P6-6, `docs/architecture/
// rust-agent-claude-v1.md`): fail-closed decode of the `agent-command-v1` versioned batched event
// envelope (design D-6) -- the one hand-rolled wire decode this vertical's FFI/bridge surface
// introduces (every *command* crosses as a plain typed UniFFI record/enum, already marshaled
// safely by generated code; only the *event* payload this scope publishes is a hand-decoded JSON
// object). Arbitrary bytes must never panic -- only cleanly decode or reject.
fuzz_target!(|input: &[u8]| {
    let _ = AgentClaudeEvent::decode(input);
});
