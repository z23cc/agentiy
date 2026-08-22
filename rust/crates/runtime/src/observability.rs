//! Process-wide, bounded WARN/ERROR diagnostics ring buffer.
//!
//! Rewrite charter §11.7 asks for "agentry-runtime 内建 tracing，桥接到
//! os_log/os_signpost（Instruments 可见）与现有诊断文件通道" -- a small,
//! always-on-cheap way for WARN/ERROR-severity runtime events (and, in
//! principle, selected span intervals) to reach a production diagnostics
//! channel without a callback back into Swift (§9.5 / §5.3: no payload
//! callback, no async foreign trait driving anything).
//!
//! This module gets that outward shape -- structured WARN/ERROR events,
//! pull-based FFI drain, callback-free -- using only `std`, in exactly the
//! idiom `panic_forensics.rs` already established and already ships through
//! this same FFI boundary (`agentry_ffi::core_panic_forensics`).
//!
//! Deliberately **not** built on the `tracing` crate. `tracing` (plus a
//! `tracing-subscriber`-based os_log backend such as `tracing-oslog`) is not
//! a dependency anywhere in this workspace today, and every macOS
//! tracing-to-os_log bridge crate surveyed for this either wraps
//! unaudited/ambiguously-licensed FFI internally (fine inside that crate's
//! own boundary, irrelevant to *this* crate's `#![forbid(unsafe_code)]`) or
//! would itself need a `cargo deny` license-allow-list exception this
//! session cannot respond to. Standing up a new external dependency is a
//! supply-chain change -- new `Cargo.lock` entries, a `deny.toml` review --
//! and this session shares `Cargo.lock` with several other agents mid-edit
//! elsewhere in `rust/crates/runtime`. Adding it now is out of scope; see
//! the observability handoff report for the explicit flag. This module is
//! the seam a real `tracing::Subscriber` (or a vetted os_log crate) could
//! drain into later without changing any call site that already calls
//! [`record`].
//!
//! The os_log/os_signpost half of the bridge lives in Swift on purpose:
//! `import os` (`OSLog`, `os_signpost`) is already available to
//! `RepoPromptApp` with zero new dependencies, zero `unsafe`, and zero
//! Cargo.lock churn -- draining this ring buffer from Swift and emitting
//! into `OSLog(subsystem: "agentry.core", ...)` is strictly cheaper than
//! doing the same job from Rust through a new crate.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Number of most-recent diagnostics events retained. Small and fixed, like
/// `panic_forensics::CAPACITY`: this is a forensics aid for the next
/// investigation, not an unbounded log -- large batches of low-value events
/// would otherwise evict the WARN/ERROR record an operator actually needs.
const CAPACITY: usize = 32;

/// Severity of a recorded diagnostic event. Deliberately just these two:
/// the charter scopes this bridge to "WARN/ERROR events", not a general
/// log-level firehose -- INFO/DEBUG-level detail belongs in the existing
/// DEBUG-only `Features/Diagnostics` file channels, not a process-wide ring
/// buffer meant to survive into production.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticSeverity {
    Warn,
    Error,
}

impl DiagnosticSeverity {
    fn label(self) -> &'static str {
        match self {
            DiagnosticSeverity::Warn => "WARN",
            DiagnosticSeverity::Error => "ERROR",
        }
    }
}

/// One recorded diagnostic event, forensic-ready.
#[derive(Clone, Debug)]
pub struct DiagnosticRecord {
    pub severity: DiagnosticSeverity,
    /// Domain this event came from, e.g. `"codemap"`, `"search"`,
    /// `"inventory"`. Reuses the same domain vocabulary this codebase
    /// already uses for Sentry categories and FFI error variants, so a
    /// downstream os_log/Sentry consumer can group by names an operator
    /// already recognizes -- see `docs/architecture/agentry-rewrite-charter.md`
    /// §11.7's "signpost 命名沿用现有领域前缀".
    pub target: &'static str,
    pub message: String,
    /// Milliseconds since the Unix epoch, best-effort. Never panics on a
    /// clock error (falls back to `0`) -- a diagnostics record must not
    /// itself become a new panic source.
    pub timestamp_millis: u64,
}

impl DiagnosticRecord {
    /// Single forensic line safe to hand to a Swift caller or a log line.
    pub fn describe(&self) -> String {
        format!(
            "[{}] target={} at t={}ms: {}",
            self.severity.label(),
            self.target,
            self.timestamp_millis,
            self.message
        )
    }
}

static RING: Mutex<VecDeque<DiagnosticRecord>> = Mutex::new(VecDeque::new());

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// Records a WARN/ERROR-severity diagnostic event for later FFI drain.
/// Cheap (one lock, one push, no I/O, no allocation beyond the message
/// string itself) and never panics -- poisoned-lock recovery mirrors
/// `panic_forensics::record_panic`, since a poisoned runtime is exactly the
/// moment this ring buffer's contents matter most.
///
/// Call sites: any domain module that wants a production-visible WARN/ERROR
/// trail without inventing its own ad hoc counter or `eprintln!`. Nothing
/// in this crate calls it yet -- populating call sites (codemap batch
/// failures, search batch degraded-mode fallbacks, inventory bulk-load
/// rejections, ...) is deliberately left as a follow-up so this change
/// stays additive and reviewable on its own; see the observability handoff
/// report for the specific recommended call sites.
pub fn record_diagnostic(severity: DiagnosticSeverity, target: &'static str, message: impl Into<String>) {
    let record = DiagnosticRecord {
        severity,
        target,
        message: message.into(),
        timestamp_millis: now_millis(),
    };
    let mut ring = RING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if ring.len() == CAPACITY {
        ring.pop_front();
    }
    ring.push_back(record);
}

/// Drains (removes and returns) every currently-buffered diagnostic event,
/// oldest first. Pull-based and callback-free by design (charter §9.5 /
/// §5.3): the FFI caller decides when and how often to drain -- e.g. once
/// per app-observability tick -- rather than Rust pushing events across the
/// boundary on its own schedule. Draining clears the ring, so repeated
/// drains never return the same event twice.
pub fn drain_diagnostics() -> Vec<DiagnosticRecord> {
    let mut ring = RING.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    ring.drain(..).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Single test, not split across functions: `RING` is process-global and
    // `cargo test` runs test functions concurrently, so two tests both
    // pushing/draining it would race over which entries survive eviction or
    // whose drain wins -- same rationale as `panic_forensics`'s single test.
    #[test]
    fn records_drain_in_order_and_cap_the_ring() {
        // Start from a clean slate regardless of what other (concurrently
        // running, process-global-`RING`-sharing) tests in this binary may
        // have left behind.
        drain_diagnostics();

        record_diagnostic(DiagnosticSeverity::Warn, "codemap", "first");
        record_diagnostic(DiagnosticSeverity::Error, "search", "second");

        let drained = drain_diagnostics();
        assert_eq!(drained.len(), 2);
        assert_eq!(drained[0].severity, DiagnosticSeverity::Warn);
        assert_eq!(drained[0].target, "codemap");
        assert!(drained[0].message.contains("first"));
        assert_eq!(drained[1].severity, DiagnosticSeverity::Error);
        assert_eq!(drained[1].target, "search");
        assert!(drained[1].describe().contains("ERROR"));

        // Draining is destructive: a second drain sees nothing left over.
        assert!(drain_diagnostics().is_empty());

        for index in 0..CAPACITY + 5 {
            record_diagnostic(DiagnosticSeverity::Warn, "inventory", format!("bulk #{index}"));
        }
        let capped = drain_diagnostics();
        assert_eq!(capped.len(), CAPACITY);
        // The ring evicts oldest-first, so only the most recent `CAPACITY`
        // pushes should survive.
        assert!(capped.last().unwrap().message.contains(&format!("#{}", CAPACITY + 4)));
    }
}
