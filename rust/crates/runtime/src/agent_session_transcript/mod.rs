//! ADR-0011 P6-b (B track; design §4.1.1 layer table, §7.1, §8 row "P6-b"): the Agent Session Host
//! transcript / snapshot reducer, ported one-for-one from
//! `Sources/RepoPromptDomainRuntime/AgentSessionHost/AgentSessionHostSessionState.swift`.
//!
//! Everything here is a pure value-state fold: event + cursor → transcript, pending interactions,
//! command-idempotency maps, and the derived `AgentSessionSnapshot`. No I/O, no clocks, no identity
//! generation. The host still appends records through the existing `AgentSessionLog` FFI; this
//! module only reduces. Determinism is what makes the Swift ⇄ Rust differential harness
//! (`Tests/RepoPromptDomainRuntimeTests/AgentSessionTranscriptRustDifferentialTests.swift`)
//! meaningful.
//!
//! Inventory (Swift type → Rust type):
//!
//! | Swift (`RepoPromptDomainRuntime`) | Rust |
//! |-----------------------------------|------|
//! | `AgentSessionHostSessionState`    | [`SessionState`] |
//! | `AgentSessionHostMutableSummary`  | proto `SessionSummary` fields inside [`SessionState`] |
//!
//! The Swift original stays in place until the host cutover (ADR-0011 decision 11). The frozen
//! `agent_host_v1` `TranscriptEntry` / `RunLifecycleEvent` / `RuntimeEvent` families are inputs,
//! not edited.

#![allow(clippy::module_name_repetitions)]

mod canonical;
mod state;

pub use canonical::hex_bytes;
pub use state::SessionState;
