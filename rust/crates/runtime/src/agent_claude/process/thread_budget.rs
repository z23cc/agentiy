//! P6-4 (design §4.2/§4.4, contract §5.2, E-P6-2 Part B/R2b): the single, shared "agent domain
//! thread count" instrument -- per-session stdout/stderr reader threads
//! ([`crate::agent_claude::process::reader`]) plus the one process-wide reaper thread
//! ([`crate::agent_claude::process::reaper`]). Living in one neutral module (not owned by either
//! `reader` or `reaper`) is what makes the `2N + 1` budget a single measured quantity rather than
//! two counters a caller has to remember to sum.

use std::sync::atomic::{AtomicUsize, Ordering};

/// Count of OS threads spawned "by the agent domain" in this process, matching contract §5.2's
/// framing ("total process thread count attributable to the agent domain"). Asserted at
/// `2N + 1` for N = 1/4/16 concurrent sessions in `tests/agent_claude_process_thread_budget.rs`.
pub static AGENT_DOMAIN_THREAD_COUNT: AtomicUsize = AtomicUsize::new(0);

/// Increments the counter. Callers spawning a new agent-domain thread call this synchronously,
/// in the *spawning* thread, before the new thread starts -- so a caller that checks the counter
/// immediately after the spawn call observes the increment deterministically, rather than racing
/// the new thread's first scheduled instruction (which [`ThreadBudgetGuard`] alone, constructed
/// inside the new thread's own closure, would not guarantee).
pub fn increment() {
    AGENT_DOMAIN_THREAD_COUNT.fetch_add(1, Ordering::SeqCst);
}

/// RAII guard: decrements on drop (including on panic-driven unwind), so a thread's contribution
/// to the budget is released exactly once regardless of how its closure returns. Pair with
/// [`increment`] called synchronously by the spawning thread beforehand -- construct this as the
/// first statement inside the spawned closure.
pub struct ThreadBudgetGuard;

impl ThreadBudgetGuard {
    /// Marks this thread's slot as already accounted for by a prior [`increment`] call; decrements
    /// on drop only.
    pub fn already_counted() -> Self {
        Self
    }
}

impl Drop for ThreadBudgetGuard {
    fn drop(&mut self) {
        AGENT_DOMAIN_THREAD_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}
