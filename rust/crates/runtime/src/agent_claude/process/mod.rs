//! P6-4 (`docs/designs/p6-claude-vertical-2026-08-23.md` §4/§11, `docs/architecture/
//! rust-agent-claude-v1.md` §5): the Rust process supervisor for the Claude vertical -- cargo-only,
//! **zero FFI dependency** (INV-P6-1 holds trivially: no export exists yet). Mirrors
//! `ProcessLauncher.swift` and `ProcessTermination.swift`'s `ChildStatusReaperRegistry`
//! architecture, not merely their syscall targeting (design §4.1/§4.2).
//!
//! Module map:
//! - [`addchdir`] -- the confirmed, unconditional `unsafe_code` prerequisite: a hand-declared
//!   `extern "C"` binding for `posix_spawn_file_actions_addchdir_np` (contract §5.1/§5.2/§12).
//! - [`spawn`] -- the `posix_spawnp` mirror, zero additional `unsafe`, attribute-for-attribute
//!   parity with `ProcessLauncher.swift` (contract §5.1).
//! - [`reaper`] -- the shared-kqueue reaper mirroring `ChildStatusReaperRegistry`'s whole
//!   architecture, including the reclamation-policy fix for the P6-2-found orphan-entry gap
//!   (contract §5.2).
//! - [`reader`] -- per-stream reader threads implementing INV-P6-2 (contract §5.3), wired to the
//!   real byte-exact [`crate::agent_claude::framer`].
//! - [`queue`] -- the bounded, non-blocking event queue a reader publishes into (contract §5.4).
//! - [`stderr_tail`] -- the 256 KiB stderr tail cap (contract §5.4).
//! - [`timer`] -- the deadline-based timer primitive the reaper's periodic probe consumes today
//!   and the turn state machine (P6-5) will reuse (design §4.7, contract §11).

pub mod addchdir;
pub mod queue;
pub mod reader;
pub mod reaper;
pub mod spawn;
pub mod stderr_tail;
pub mod thread_budget;
pub mod timer;

pub use queue::{BoundedEventQueue, QueueEvent};
pub use reader::{ReaderStats, spawn_stderr_reader, spawn_stdout_reader};
pub use reaper::{ReapOutcome, Reaper, RegisterError, terminate_and_orphan, terminate_and_reap, terminate_orphan_backstop};
pub use spawn::{SpawnConfig, SpawnError, SpawnedProcess, spawn};
pub use stderr_tail::StderrTail;
pub use thread_budget::AGENT_DOMAIN_THREAD_COUNT;
pub use timer::{Clock, Deadline, FakeClock, SystemClock};
