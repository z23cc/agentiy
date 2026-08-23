//! P6-5 (`docs/designs/p6-claude-vertical-2026-08-23.md` §3.4/§4.5, `docs/architecture/
//! rust-agent-claude-v1.md` §2.2/§4): control-request correlation and timeouts, ported from
//! `sendControlRequest(request:timeoutSeconds:)` / `sendControlRequestWithoutResponse(request:)`
//! (`ClaudeNativeProcessSessionController.swift:780-824`). Cargo-only per the P6-5 step list:
//! this module has zero FFI dependency and is exercised entirely through a caller-supplied write
//! closure, so it is fully testable without a real spawned process (process wiring is P6-6's job).
//!
//! **The race this ports closed, verbatim.** `sendControlRequest` registers the pending
//! continuation *before* writing to stdin -- "closes a race where the CLI replies before the
//! continuation exists" (contract §2.2). [`send_control_request`] preserves that ordering exactly:
//! [`ControlCorrelator::register`] always runs before the caller-supplied `write` closure.
//!
//! **Write-failure never leaks a pending entry.** A write failure removes the just-registered
//! continuation and returns the write error to the caller rather than leaving an orphaned entry
//! that would either never resolve or (worse) resolve against a request the transport never
//! actually sent (contract §2.2: "A write failure removes the continuation/timeout and resumes the
//! caller with the write error rather than leaking a pending entry").
//!
//! **The fire-and-forget variant never registers at all.** `sendControlRequestWithoutResponse`
//! (used for permission responses, [`permission`](super::permission)) is `shutdownOnFailure: false`
//! so a dead transport doesn't shut down the session before the caller can emit a failed-turn
//! completion -- [`send_control_request_without_response`] is a thin pass-through over the write
//! closure with no correlator interaction whatsoever, matching that it never has a response to wait
//! for.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::Duration;

use super::codec::ControlResponse;

/// The result of a correlated control request, mirroring the four outcomes
/// `sendControlRequest` produces today (contract §2.2): a `control_response` arrived, the deadline
/// elapsed with none, or the outbound write itself failed.
#[derive(Debug, Clone, PartialEq)]
pub enum ControlOutcome {
    Response(ControlResponse),
    Timeout,
    WriteFailed(String),
}

/// Pending-request registry. One instance per session; every in-flight control request (interrupt
/// ACK, permission... no -- permission responses are fire-and-forget and never register here, see
/// module doc) holds exactly one entry, keyed by `request_id`, for exactly as long as it is
/// unresolved.
#[derive(Default)]
pub struct ControlCorrelator {
    pending: Mutex<HashMap<String, Sender<ControlOutcome>>>,
}

impl ControlCorrelator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers a pending continuation for `request_id` and returns the receiving half. Must be
    /// called -- and must complete -- before the corresponding outbound line is written (contract
    /// §2.2's race-closing ordering). Overwrites (rather than rejects) a pre-existing entry for the
    /// same `request_id`: request IDs are caller-generated and this module does not police their
    /// uniqueness, matching the Swift dictionary-subscript registration it ports.
    fn register(&self, request_id: &str) -> mpsc::Receiver<ControlOutcome> {
        let (sender, receiver) = mpsc::channel();
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(request_id.to_string(), sender);
        receiver
    }

    /// Removes a pending entry without resolving it -- used when a write fails immediately after
    /// registration (contract §2.2) and when a timeout has already been observed by the waiter (so
    /// a late-arriving response has nothing left to resolve; see [`Self::resolve`]'s `bool` return).
    fn unregister(&self, request_id: &str) {
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(request_id);
    }

    /// Port of `handleControlResponse`'s pending-continuation half (`:1862-1880`): called from the
    /// inbound `control_response` dispatch path. Returns `true` if a pending entry existed and was
    /// resolved; `false` if the response named a request ID with no pending entry (already timed
    /// out, already resolved, or never registered -- the caller silently drops it, matching Swift's
    /// `guard let continuation = ... else { return }`).
    pub fn resolve(&self, request_id: &str, response: ControlResponse) -> bool {
        let sender = self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(request_id);
        match sender {
            Some(sender) => sender.send(ControlOutcome::Response(response)).is_ok(),
            None => false,
        }
    }

    /// Port of `failPendingControlRequests(with:)` (`:1924-1935`) -- called on stdout EOF / shutdown
    /// to fail every still-pending request rather than leave its waiter blocked forever.
    pub fn fail_all(&self, reason: &str) {
        let pending: HashMap<String, Sender<ControlOutcome>> = std::mem::take(
            &mut *self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        for sender in pending.into_values() {
            let _ = sender.send(ControlOutcome::WriteFailed(reason.to_string()));
        }
    }

    #[cfg(test)]
    pub fn pending_count(&self) -> usize {
        self.pending.lock().unwrap_or_else(std::sync::PoisonError::into_inner).len()
    }
}

/// Port of `sendControlRequest(request:timeoutSeconds:)` (`:780-824`). `write` performs the actual
/// outbound line write (production: the serialized single-write framing over the process's stdin;
/// tests substitute a closure). Registration happens before `write` runs (race-closing order,
/// module doc); a write failure unregisters and returns `WriteFailed` without ever blocking on the
/// receiver; otherwise blocks up to `timeout` for a resolution.
pub fn send_control_request<W>(
    correlator: &ControlCorrelator,
    request_id: &str,
    timeout: Duration,
    write: W,
) -> ControlOutcome
where
    W: FnOnce() -> Result<(), String>,
{
    let receiver = correlator.register(request_id);
    if let Err(write_error) = write() {
        correlator.unregister(request_id);
        return ControlOutcome::WriteFailed(write_error);
    }
    match receiver.recv_timeout(timeout) {
        Ok(outcome) => outcome,
        Err(RecvTimeoutError::Timeout) => {
            correlator.unregister(request_id);
            ControlOutcome::Timeout
        }
        Err(RecvTimeoutError::Disconnected) => {
            // The sender was dropped without sending -- treated identically to an explicit
            // WriteFailed(fail_all) resolution never reaching this specific waiter; unregister is a
            // no-op here (the entry is already gone, `fail_all` removed it) but is harmless/idempotent.
            correlator.unregister(request_id);
            ControlOutcome::WriteFailed("control correlator dropped without a response".to_string())
        }
    }
}

/// Port of `sendControlRequestWithoutResponse(request:)` (`:826-841`... conceptually; the fire-
/// and-forget variant) -- used for permission responses (`shutdownOnFailure: false`). Never
/// registers a pending continuation: there is nothing to correlate a response against because the
/// caller does not wait for one.
pub fn send_control_request_without_response<W>(write: W) -> Result<(), String>
where
    W: FnOnce() -> Result<(), String>,
{
    write()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;

    fn response(request_id: &str) -> ControlResponse {
        ControlResponse {
            request_id: request_id.to_string(),
            subtype: "success".to_string(),
            response: Some(Map::new()),
            error: None,
            pending_permission_requests: Vec::new(),
        }
    }

    #[test]
    fn register_happens_before_write_closing_the_race_where_a_response_beats_the_continuation() {
        // The write closure itself resolves the request (simulating a same-thread/instant CLI
        // reply) -- this only succeeds at all if `register` has already run by the time `write`
        // executes, which is exactly contract §2.2's race-closing guarantee.
        let correlator = ControlCorrelator::new();
        let correlator_ref = &correlator;
        let outcome = send_control_request(&correlator, "req-1", Duration::from_secs(1), || {
            assert!(
                correlator_ref.resolve("req-1", response("req-1")),
                "the continuation must already be registered when the write closure runs"
            );
            Ok(())
        });
        assert_eq!(outcome, ControlOutcome::Response(response("req-1")));
    }

    #[test]
    fn write_failure_removes_the_pending_entry_and_resumes_with_the_write_error_not_a_leak() {
        let correlator = ControlCorrelator::new();
        let outcome = send_control_request(&correlator, "req-2", Duration::from_secs(1), || {
            Err("pipe closed".to_string())
        });
        assert_eq!(outcome, ControlOutcome::WriteFailed("pipe closed".to_string()));
        assert_eq!(correlator.pending_count(), 0, "a failed write must not leak a pending entry");
    }

    #[test]
    fn no_response_within_the_deadline_times_out_and_unregisters() {
        let correlator = ControlCorrelator::new();
        let outcome = send_control_request(&correlator, "req-3", Duration::from_millis(20), || Ok(()));
        assert_eq!(outcome, ControlOutcome::Timeout);
        assert_eq!(correlator.pending_count(), 0);
    }

    #[test]
    fn a_response_delivered_from_another_thread_resolves_the_waiter() {
        let correlator = Arc::new(ControlCorrelator::new());
        let writer_ran = Arc::new(AtomicBool::new(false));
        let correlator_for_thread = Arc::clone(&correlator);
        let writer_ran_for_thread = Arc::clone(&writer_ran);
        let outcome = send_control_request(&correlator, "req-4", Duration::from_secs(2), move || {
            writer_ran_for_thread.store(true, Ordering::SeqCst);
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(10));
                correlator_for_thread.resolve("req-4", response("req-4"));
            });
            Ok(())
        });
        assert!(writer_ran.load(Ordering::SeqCst));
        assert_eq!(outcome, ControlOutcome::Response(response("req-4")));
    }

    #[test]
    fn resolving_an_unknown_request_id_is_a_silent_no_op_matching_swifts_guard_let_else_return() {
        let correlator = ControlCorrelator::new();
        assert!(!correlator.resolve("never-registered", response("never-registered")));
    }

    #[test]
    fn fail_all_resolves_every_pending_waiter_and_none_are_left_registered() {
        let correlator = Arc::new(ControlCorrelator::new());
        let mut handles = Vec::new();
        for i in 0..3 {
            let correlator = Arc::clone(&correlator);
            handles.push(thread::spawn(move || {
                send_control_request(&correlator, &format!("req-fail-{i}"), Duration::from_secs(5), || Ok(()))
            }));
        }
        // Give the waiters a moment to register before failing them all.
        thread::sleep(Duration::from_millis(20));
        assert_eq!(correlator.pending_count(), 3);
        correlator.fail_all("stdout EOF");
        for handle in handles {
            let outcome = handle.join().unwrap();
            assert_eq!(outcome, ControlOutcome::WriteFailed("stdout EOF".to_string()));
        }
        assert_eq!(correlator.pending_count(), 0);
    }

    #[test]
    fn fire_and_forget_never_registers_a_pending_continuation() {
        let calls = Arc::new(AtomicBool::new(false));
        let calls_ref = Arc::clone(&calls);
        let result = send_control_request_without_response(move || {
            calls_ref.store(true, Ordering::SeqCst);
            Ok(())
        });
        assert!(result.is_ok());
        assert!(calls.load(Ordering::SeqCst));
    }
}
