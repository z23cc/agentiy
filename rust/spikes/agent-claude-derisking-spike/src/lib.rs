//! P6-2 de-risking spike library for the Claude vertical.
//!
//! Throwaway de-risking code producing GO/NO-GO evidence for
//! `docs/designs/p6-claude-vertical-2026-08-23.md` section 8 (E-P6-1/E-P6-2/E-P6-3) and
//! `docs/architecture/rust-agent-claude-v1.md`. NOT the P6-3/P6-4 production port; nothing
//! here is linked into `rust/crates/*` or `AgentryCoreBridge`.

pub mod reaper;
pub mod spawn;
pub mod stream;
pub mod tool_owned;
