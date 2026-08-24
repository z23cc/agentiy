//! P6-5 (design §4.5, `docs/architecture/rust-agent-claude-v1.md` §3): the turn lifecycle /
//! terminal-event authority state machine, ported from
//! `ClaudeNativeProcessSessionController.swift:1269-1489` (the result->idle deferral window) and
//! `:1608-1649` (`determineTurnStatus`). Design R4 names this "the single most behaviorally
//! delicate part of the vertical" and requires it ported as a state machine, not paraphrased --
//! every rule below is anchored to its Swift source line range, not restated from memory of intent.
//!
//! ```text
//! Idle ──send_user_message──▶ TurnInFlight{turn_id}
//! TurnInFlight ──payload.type=="result" && translated=="message_stop"──▶
//!     if observed_session_state_changed:  ResultObserved{status}   (turn NOT dequeued; in-flight stays true)
//!     else:                                Completed{status}        (legacy immediate path)
//! ResultObserved ──session_state_changed(text=="idle")──▶ Completed{status}
//! ResultObserved ──fallback_timer(1.0s, generation-tokened)──▶ Completed{status}  + `lifecycle.idleFallback`
//! any ──stdout EOF──▶ flush deferred with original status; remaining turn IDs ⇒ Failed + one `.error`
//! any ──shutdown──▶ flush deferred with original status (never rewritten to Failed)
//! ```
//!
//! **A discrepancy found while porting, recorded rather than silently resolved either way.**
//! `shutdown()` (`ClaudeNativeProcessSessionController.swift:518-526`) calls `clearTurnIDQueue()`
//! (`:525`) *before* `cancelAuthoritativeLifecycleState()` (`:526`). Since
//! `cancelAuthoritativeLifecycleState`'s flush loop (`:1454-1465`) guards each iteration on
//! `hasPendingTurnIDs` and `break`s the instant that is false, and the queue was just cleared, the
//! *actual* current Swift behavior is: **no deferred `turnCompleted` events are ever emitted on
//! `shutdown()`** -- they are silently dropped, contradicting this file's own contract table ("any
//! -- shutdown --> flush deferred with original status"), which describes `EOF`'s ordering
//! (`handleStdoutEOF`, `:1899-1921`, correctly calls `cancelAuthoritativeLifecycleState()` *before*
//! draining) as if it also held for `shutdown()`. [`TurnState::on_shutdown`] below implements the
//! **contract's stated behavior** (flush-then-clear), not the Swift source's actual current
//! ordering -- P6-7's turn-level differential will need either a Swift-side fix (reorder
//! `shutdown()`'s two calls) or a registered intentional-drift item before that differential can go
//! green on this exact edge case. Flagged for the campaign record; not resolved by this module.
//!
//! **The exact delta, for P6-7:** this is narrower than "shutdown ordering disagrees" -- the two
//! arms already agree on the *silent-drop* half (turn IDs that never received any result are
//! cleared with no event on both sides, `on_shutdown`'s `pending_turn_ids.clear()` mirroring
//! Swift's unconditional `clearTurnIDQueue()`). They disagree only on the *deferred-flush* half:
//! **Rust's `on_shutdown` emits one `TurnCompleted` event per already-resulted-but-not-yet-idle-
//! confirmed turn (N = `pending_deferred.len()` at shutdown time), preserving each entry's original
//! status; Swift's current `shutdown()` emits zero, because its queue-clear-before-flush ordering
//! makes `cancelAuthoritativeLifecycleState`'s guard exit immediately.** All other shutdown
//! behavior -- the silent-drop half, and every EOF-path behavior -- is identical between the two
//! arms.

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use super::process::timer::{Clock, Deadline};

/// The default idle-fallback interval (contract §3: "default **1.0 s**").
pub const DEFAULT_IDLE_FALLBACK: Duration = Duration::from_millis(1000);

/// The four cancelled-signal tokens, substring-matched case-insensitively/trimmed (contract §3,
/// `isCancelledTurnSignal`/`:1758-1768`). Shared verbatim with
/// [`super::translator::should_suppress_result_error_emission`]'s interrupt-signal check -- same
/// vocabulary, different call site (design: "not drift, and must not become drift").
const CANCELLED_SIGNAL_TOKENS: [&str; 4] =
    ["interrupt", "cancel", "aborted", "request was aborted"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnStatus {
    Completed,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TurnEvent {
    /// `.turnCompleted(turnID:status:)`.
    TurnCompleted { turn_id: u64, status: TurnStatus },
    /// `.error(...)` -- emitted exactly once, immediately before the EOF drain of turn IDs that
    /// never saw any result at all (contract §3's "EOF beyond the deferred queue").
    Error(String),
}

/// Port of D-4: the three `assertionFailure` sites (`:1372`, `:1401`, `:1439`) become counted
/// diagnostics plus a lossless `protocolDrift` event -- "a Rust panic in the authority is a worse
/// outcome than a logged inconsistency" (charter §14.1). **Not** raised for the flush loop's own
/// early exit (`cancelAuthoritativeLifecycleState`'s `guard hasPendingTurnIDs else { break }`,
/// `:1460`) -- that site is a silent `break` in the Swift source too, not an `assertionFailure`;
/// [`TurnState::flush_deferred`] preserves that exact asymmetry rather than generalizing all three
/// call sites into a uniform diagnostic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnDiagnostic {
    /// `:1372` -- a `result`/`message_stop` arrived with no pending turn ID at all.
    ResultWithNoPendingTurnId,
    /// `:1401` -- an `idle` `session_state_changed` released a deferred completion but the turn-ID
    /// queue was already empty.
    DeferredIdleCompletionWithNoPendingTurnId,
    /// `:1439` -- the idle-fallback timer fired but the turn-ID queue was already empty.
    IdleFallbackWithNoPendingTurnId,
}

/// The turn lifecycle / terminal-event authority. One instance per agent session (mirrors the
/// controller's per-session state at `:140-207`). Generic over [`Clock`] so tests can substitute
/// [`super::process::timer::FakeClock`] for the sleep-length-discontinuity property, exactly as
/// [`super::process::timer`]'s own tests do (that primitive is proven once there and reused here,
/// per that module's doc comment).
pub struct TurnState<C: Clock> {
    clock: Arc<C>,
    idle_fallback: Duration,

    pending_turn_ids: VecDeque<u64>,
    next_turn_id: u64,

    /// Port of `pendingAuthoritativeTurnStatuses` (`:197`) -- statuses already determined from a
    /// `result` but awaiting `idle` confirmation (or the fallback). FIFO-paired with the *front* of
    /// `pending_turn_ids`: the Nth deferred status always corresponds to the Nth-oldest turn ID
    /// still in the queue, exactly as the Swift source pairs them implicitly (neither side stores
    /// an explicit turn-ID<->status association; both rely on send order == completion order).
    pending_deferred: VecDeque<TurnStatus>,

    /// Port of `observedSessionStateChangedEvents` (`:192`) -- a session-scoped latch set the
    /// *first time any* `session_state_changed` result is produced (not only `idle`), and never
    /// cleared. Before this is set, turn completion is immediate ("legacy mode"); after, every
    /// completion defers to the idle/fallback release.
    observed_session_state_changed: bool,

    /// Port of `turnWasInterrupted` (`:185`) -- consumed on read (reset to `false` the moment
    /// [`Self::determine_status`] observes it `true`), so exactly one subsequent result
    /// determination sees it (contract §3: "matching 'the very next result after an ACKed interrupt
    /// is a cancellation side effect, not a real failure'").
    turn_was_interrupted: bool,

    /// Port of `authoritativeIdleFallbackTask` (`:206`): exactly one live deadline is represented
    /// by this slot. [`fallback_generation`](Self::fallback_generation) separately fences the
    /// scope's sleeping worker so an old wakeup cannot poll a replacement deadline.
    fallback: Option<Deadline<C>>,
    /// Monotonic token for the currently armed fallback. The scope uses it to ensure a sleeping
    /// worker for an older turn can never poll (and accidentally release) a newly armed fallback.
    fallback_generation: u64,
}

impl<C: Clock> TurnState<C> {
    pub fn new(clock: Arc<C>) -> Self {
        Self::with_idle_fallback(clock, DEFAULT_IDLE_FALLBACK)
    }

    pub fn with_idle_fallback(clock: Arc<C>, idle_fallback: Duration) -> Self {
        Self {
            clock,
            idle_fallback,
            pending_turn_ids: VecDeque::new(),
            // P6-6: starts at 1, not 0. `next_turn_id` doubles as the interrupt-fencing
            // `turn_generation` (contract §4) at the scope layer, which needs an unambiguous
            // "no turn has ever been sent" sentinel distinct from any real generation -- 0 is that
            // sentinel. Turn-ID *values* are otherwise opaque outside this module (no test or
            // caller depends on the sequence starting at any particular number), so this is a safe,
            // non-behavior-changing renumbering, not a contract change.
            next_turn_id: 1,
            pending_deferred: VecDeque::new(),
            observed_session_state_changed: false,
            turn_was_interrupted: false,
            fallback: None,
            fallback_generation: 0,
        }
    }

    /// Port of `beginTurnTracking()` (`:2470-2475`): `Idle`/`TurnInFlight` -> `TurnInFlight` (a new
    /// turn ID is always appended, whether or not a previous turn is still deferred-in-flight --
    /// the Swift source imposes no "wait for idle before sending again" constraint at this layer;
    /// that policy, if any, is host-side, design §7.2).
    pub fn send_user_message(&mut self) -> u64 {
        let turn_id = self.next_turn_id;
        self.next_turn_id += 1;
        self.pending_turn_ids.push_back(turn_id);
        turn_id
    }

    /// Port of `hasPendingTurnIDs` (`:2480-2482`) -- `turnInFlight` in the design's vocabulary.
    pub fn has_pending_turn_ids(&self) -> bool {
        !self.pending_turn_ids.is_empty()
    }

    /// Port of `determineTurnStatus(from:stopReasonHint:)` (`:1608-1649`). Consumes
    /// `turn_was_interrupted` on read (module doc). `nested_stop_reason` is
    /// `payload["event"]["delta"]["stop_reason"]` (`:1629-1635`); `result_errors` is the collected
    /// `extractResultErrors(from:)` output (`:1637`).
    pub fn determine_status(
        &mut self,
        is_error: bool,
        subtype: &str,
        stop_reason: &str,
        stop_reason_hint: Option<&str>,
        nested_stop_reason: Option<&str>,
        result_errors: &[String],
    ) -> TurnStatus {
        if self.turn_was_interrupted {
            self.turn_was_interrupted = false;
            return TurnStatus::Cancelled;
        }

        let subtype = subtype.trim().to_lowercase();
        let stop_reason = stop_reason.trim().to_lowercase();

        if is_cancelled_turn_signal(Some(&subtype))
            || is_cancelled_turn_signal(Some(&stop_reason))
            || is_cancelled_turn_signal(stop_reason_hint)
            || is_cancelled_turn_signal(nested_stop_reason)
            || result_errors
                .iter()
                .any(|message| is_cancelled_turn_signal(Some(message)))
        {
            return TurnStatus::Cancelled;
        }

        if is_error || subtype.contains("error") || !result_errors.is_empty() {
            return TurnStatus::Failed;
        }
        TurnStatus::Completed
    }

    /// Port of `turnWasInterrupted = true` (`:469`, the successful-interrupt-ACK side effect).
    /// P6-6 wires this to the interrupt command's `acknowledged` outcome (design §5.3); exposed here
    /// as a standalone setter so the state machine is independently testable ahead of that wiring.
    pub fn mark_interrupted(&mut self) {
        self.turn_was_interrupted = true;
    }

    #[cfg(test)]
    fn turn_was_interrupted_for_testing(&self) -> bool {
        self.turn_was_interrupted
    }

    /// Port of the `result`/`message_stop` branch of `handleStreamPayload` (`:1370-1388`). Call only
    /// when `payload.type == "result"` (`isResultPayload`) *and* the translated stream result's
    /// kind is `"message_stop"` -- forwarded `message_delta`/`message_stop` stream events translate
    /// to the same kind but must never reach this method (contract §3: "do **not** carry
    /// `isResultPayload == true`, so they ... never dequeue a turn ID or complete anything").
    pub fn on_authoritative_result(
        &mut self,
        status: TurnStatus,
        mut diagnostic: impl FnMut(TurnDiagnostic),
    ) -> Option<TurnEvent> {
        if !self.has_pending_turn_ids() {
            diagnostic(TurnDiagnostic::ResultWithNoPendingTurnId);
            return None;
        }
        if self.observed_session_state_changed {
            self.pending_deferred.push_back(status);
            self.schedule_fallback_if_needed();
            None
        } else {
            let turn_id = self
                .pending_turn_ids
                .pop_front()
                .expect("checked has_pending_turn_ids above");
            Some(TurnEvent::TurnCompleted { turn_id, status })
        }
    }

    /// Port of `session_state_changed` handling inside `handleStreamPayload` (`:1347-1355`): sets
    /// the session-scoped latch unconditionally (module doc), then releases a deferred completion
    /// only when `text`, lowercased/trimmed, is exactly `"idle"` (`:1351-1353`).
    pub fn on_session_state_changed(
        &mut self,
        text: &str,
        diagnostic: impl FnMut(TurnDiagnostic),
    ) -> Option<TurnEvent> {
        self.observed_session_state_changed = true;
        if text.trim().to_lowercase() == "idle" {
            self.complete_next_deferred(diagnostic)
        } else {
            None
        }
    }

    /// Port of `completeNextDeferredTurnIfPending()` (`:1395-1408`).
    fn complete_next_deferred(
        &mut self,
        mut diagnostic: impl FnMut(TurnDiagnostic),
    ) -> Option<TurnEvent> {
        let status = self.pending_deferred.pop_front()?;
        self.fallback = None;
        let Some(turn_id) = self.pending_turn_ids.pop_front() else {
            diagnostic(TurnDiagnostic::DeferredIdleCompletionWithNoPendingTurnId);
            return None;
        };
        let event = TurnEvent::TurnCompleted { turn_id, status };
        self.schedule_fallback_if_needed();
        Some(event)
    }

    /// Port of `scheduleAuthoritativeIdleFallbackIfNeeded()` (`:1414-1430`): arms a fallback only
    /// when the deferred queue is non-empty and nothing is already armed -- "only ever one live
    /// fallback task at a time," and rescheduling after each release is the caller's responsibility
    /// via [`Self::complete_next_deferred`]/[`Self::poll_fallback`] both calling this.
    fn schedule_fallback_if_needed(&mut self) {
        if self.pending_deferred.is_empty() {
            self.fallback = None;
            return;
        }
        if self.fallback.is_some() {
            return;
        }
        self.fallback_generation = self.fallback_generation.wrapping_add(1).max(1);
        self.fallback = Some(Deadline::arm(Arc::clone(&self.clock), self.idle_fallback));
    }

    /// Returns the generation-fenced sleep ticket the scope should schedule for the currently
    /// armed fallback. Repeated reads return the same generation; the scope de-duplicates them.
    pub fn fallback_poll_ticket(&self) -> Option<(u64, Duration)> {
        self.fallback
            .as_ref()
            .map(|_| (self.fallback_generation, self.idle_fallback))
    }

    /// Polls only when `generation` still names the currently armed fallback. A worker waking after
    /// `idle` released the old turn, or after a newer fallback was armed, becomes a no-op.
    pub fn poll_fallback_for_generation(
        &mut self,
        generation: u64,
        diagnostic: impl FnMut(TurnDiagnostic),
    ) -> Option<TurnEvent> {
        if self.fallback.is_none() || generation != self.fallback_generation {
            return None;
        }
        self.poll_fallback(diagnostic)
    }

    /// Port of `handleAuthoritativeIdleFallbackFired(generation:)` (`:1432-1449`). The caller
    /// polls this after the deadline; a no-op (`None`) when no fallback is armed or it has not yet
    /// reached its deadline. Production callers use [`Self::poll_fallback_for_generation`] so stale
    /// sleeping workers are rejected before this deadline is inspected.
    pub fn poll_fallback(
        &mut self,
        mut diagnostic: impl FnMut(TurnDiagnostic),
    ) -> Option<TurnEvent> {
        let fired = self.fallback.as_mut().is_some_and(Deadline::poll);
        if !fired {
            return None;
        }
        self.fallback = None;
        let Some(status) = self.pending_deferred.pop_front() else {
            // Structurally unreachable (a fallback is only ever armed while `pending_deferred` is
            // non-empty, `schedule_fallback_if_needed`), kept as a diagnostic rather than a panic
            // for the same D-4 reason as the other two sites, not because this one is expected to
            // fire in practice.
            return None;
        };
        let Some(turn_id) = self.pending_turn_ids.pop_front() else {
            diagnostic(TurnDiagnostic::IdleFallbackWithNoPendingTurnId);
            return None;
        };
        let event = TurnEvent::TurnCompleted { turn_id, status };
        self.schedule_fallback_if_needed();
        Some(event)
    }

    /// Port of `cancelAuthoritativeLifecycleState()` (`:1454-1465`) -- shared by both
    /// [`Self::on_shutdown`] and [`Self::on_stdout_eof`]. Cancels the fallback, then drains
    /// `pending_deferred` in order, each paired with the next turn ID, **preserving each entry's
    /// already-determined status verbatim** (never rewritten to `Failed` -- "the result that
    /// established the status was already observed; only the `idle` confirmation was missing").
    /// Deliberately **not** diagnosed if the turn-ID queue runs out mid-drain (`:1460`'s silent
    /// `break`, module doc's `TurnDiagnostic` note) -- this is the one flush-loop asymmetry the
    /// Swift source itself does not flag as drift.
    fn flush_deferred(&mut self) -> Vec<TurnEvent> {
        self.fallback = None;
        let mut events = Vec::new();
        while let Some(status) = self.pending_deferred.pop_front() {
            let Some(turn_id) = self.pending_turn_ids.pop_front() else {
                break;
            };
            events.push(TurnEvent::TurnCompleted { turn_id, status });
        }
        self.pending_deferred.clear();
        events
    }

    /// Port of `shutdown()`'s authoritative-lifecycle half. Implements the **contract's stated**
    /// flush-then-clear behavior (module doc's discrepancy note): flush every deferred completion
    /// with its original status, then silently drop any turn IDs that never had a result at all
    /// (matching `shutdown()`'s separate, unconditional `clearTurnIDQueue()`, `:525` -- no `.error`,
    /// no `.failed` completions for those, unlike EOF).
    pub fn on_shutdown(&mut self) -> Vec<TurnEvent> {
        let events = self.flush_deferred();
        self.pending_turn_ids.clear();
        events
    }

    /// Port of `handleStdoutEOF()`'s authoritative-lifecycle half (`:1899-1921`): flush deferred
    /// completions first (`cancelAuthoritativeLifecycleState()`, correctly ordered *before* the
    /// drain here, unlike `shutdown()` -- module doc), then drain every turn ID that never received
    /// any result at all as `Failed`, preceded by exactly one `Error` event if that drained set is
    /// non-empty (contract §3: "preceded by exactly one `.error`").
    pub fn on_stdout_eof(&mut self) -> Vec<TurnEvent> {
        let mut events = self.flush_deferred();
        if !self.pending_turn_ids.is_empty() {
            events.push(TurnEvent::Error(
                "Claude process exited unexpectedly.".to_string(),
            ));
            while let Some(turn_id) = self.pending_turn_ids.pop_front() {
                events.push(TurnEvent::TurnCompleted {
                    turn_id,
                    status: TurnStatus::Failed,
                });
            }
        }
        events
    }
}

/// Port of `isCancelledTurnSignal(_:)` (`:1758-1768`) -- substring match, not exact, case-
/// insensitive/trimmed. Shared vocabulary with
/// [`super::translator::should_suppress_result_error_emission`]'s `is_interrupted_turn_signal`
/// (design: "not drift, and must not become drift" -- listed verbatim in both places rather than
/// factored into one shared function, matching that the two Swift call sites
/// (`ClaudeNativeProcessSessionController.swift` and the package translator) are themselves
/// independent copies, not a shared helper).
fn is_cancelled_turn_signal(value: Option<&str>) -> bool {
    let Some(value) = value else { return false };
    let value = value.trim().to_lowercase();
    if value.is_empty() {
        return false;
    }
    CANCELLED_SIGNAL_TOKENS
        .iter()
        .any(|token| value.contains(token))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_claude::process::timer::FakeClock;

    fn state() -> (TurnState<FakeClock>, Arc<FakeClock>) {
        let clock = FakeClock::new();
        (
            TurnState::with_idle_fallback(Arc::clone(&clock), Duration::from_millis(1000)),
            clock,
        )
    }

    fn no_diagnostics() -> impl FnMut(TurnDiagnostic) {
        |d| panic!("unexpected diagnostic: {d:?}")
    }

    // MARK: - Legacy immediate-completion mode (before any session_state_changed is observed)

    #[test]
    fn legacy_mode_completes_immediately_on_the_first_authoritative_result() {
        let (mut turns, _clock) = state();
        let turn_id = turns.send_user_message();
        assert!(turns.has_pending_turn_ids());
        let event = turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        assert_eq!(
            event,
            Some(TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            })
        );
        assert!(
            !turns.has_pending_turn_ids(),
            "legacy mode must dequeue immediately, not defer"
        );
    }

    // MARK: - Deferred mode: observedSessionStateChangedEvents latch

    #[test]
    fn the_latch_is_set_by_any_session_state_changed_text_not_only_idle() {
        let (mut turns, _clock) = state();
        turns.send_user_message();
        // A non-idle session_state_changed (e.g. "running") still sets the latch (module doc).
        assert_eq!(
            turns.on_session_state_changed("running", no_diagnostics()),
            None
        );
        let event = turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        assert_eq!(
            event, None,
            "once the latch is set, completion must defer even on the very next result"
        );
        assert!(
            turns.has_pending_turn_ids(),
            "turnInFlight must stay true across the deferral window"
        );
    }

    #[test]
    fn deferred_mode_releases_on_the_idle_session_state_changed_and_dequeues_exactly_then() {
        let (mut turns, _clock) = state();
        let turn_id = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        assert!(
            turns.has_pending_turn_ids(),
            "must not dequeue before idle arrives"
        );

        // Case-insensitive / trimmed, matching the translator's own session_state_changed text
        // normalization (contract §2.3) -- the state machine trims/lowercases again defensively.
        let event = turns.on_session_state_changed("  IDLE  ", no_diagnostics());
        assert_eq!(
            event,
            Some(TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            })
        );
        assert!(!turns.has_pending_turn_ids());
    }

    #[test]
    fn a_second_deferred_turn_reschedules_the_fallback_after_the_first_releases() {
        let (mut turns, clock) = state();
        let first = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        let second = turns.send_user_message();
        turns.on_authoritative_result(TurnStatus::Failed, no_diagnostics());

        assert_eq!(
            turns.on_session_state_changed("idle", no_diagnostics()),
            Some(TurnEvent::TurnCompleted {
                turn_id: first,
                status: TurnStatus::Completed
            })
        );
        assert!(
            turns.has_pending_turn_ids(),
            "the second deferred turn must still be pending"
        );

        // The fallback must have been rescheduled for the second entry -- confirmed by jumping the
        // clock and polling, rather than by inspecting private state.
        clock.jump_forward(Duration::from_millis(1000) + Duration::from_secs(600));
        let fallback_event = turns.poll_fallback(no_diagnostics());
        assert_eq!(
            fallback_event,
            Some(TurnEvent::TurnCompleted {
                turn_id: second,
                status: TurnStatus::Failed
            })
        );
    }

    // MARK: - The idle-fallback timer

    #[test]
    fn fallback_fires_exactly_once_after_the_deadline_and_not_before() {
        let (mut turns, clock) = state();
        let turn_id = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());

        assert_eq!(
            turns.poll_fallback(no_diagnostics()),
            None,
            "must not fire before the deadline"
        );
        clock.jump_forward(Duration::from_millis(1000) + Duration::from_secs(600));
        assert_eq!(
            turns.poll_fallback(no_diagnostics()),
            Some(TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            })
        );
        assert_eq!(
            turns.poll_fallback(no_diagnostics()),
            None,
            "must not fire a second time"
        );
    }

    #[test]
    fn stale_fallback_generation_cannot_release_a_replacement_turn() {
        let (mut turns, clock) = state();
        let first = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        let (first_generation, _) = turns.fallback_poll_ticket().expect("first fallback ticket");

        assert_eq!(
            turns.on_session_state_changed("idle", no_diagnostics()),
            Some(TurnEvent::TurnCompleted {
                turn_id: first,
                status: TurnStatus::Completed
            })
        );

        let second = turns.send_user_message();
        turns.on_authoritative_result(TurnStatus::Failed, no_diagnostics());
        let (second_generation, _) = turns
            .fallback_poll_ticket()
            .expect("replacement fallback ticket");
        assert_ne!(first_generation, second_generation);

        clock.jump_forward(Duration::from_millis(1000) + Duration::from_secs(600));
        assert_eq!(
            turns.poll_fallback_for_generation(first_generation, no_diagnostics()),
            None,
            "a stale worker must not poll the replacement deadline"
        );
        assert!(turns.has_pending_turn_ids());
        assert_eq!(
            turns.poll_fallback_for_generation(second_generation, no_diagnostics()),
            Some(TurnEvent::TurnCompleted {
                turn_id: second,
                status: TurnStatus::Failed
            })
        );
    }

    #[test]
    fn idle_arriving_after_the_fallback_already_released_does_not_double_complete() {
        let (mut turns, clock) = state();
        turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        clock.jump_forward(Duration::from_millis(1000) + Duration::from_secs(600));
        turns.poll_fallback(no_diagnostics());

        // A stale "idle" arriving after the fallback already completed the turn must be a no-op:
        // pending_deferred is empty, so on_session_state_changed's complete_next_deferred returns
        // None via its `?` on an empty pop_front, never re-emitting a completion.
        assert_eq!(
            turns.on_session_state_changed("idle", no_diagnostics()),
            None
        );
    }

    // MARK: - The sessionStateChanged(idle) classification trap (design §5.2/§7.1)

    #[test]
    fn session_state_changed_idle_is_the_turn_boundary_not_a_progress_ping() {
        // This is the named trap test: an implementation that treated `session_state_changed(idle)`
        // as droppable/coalescible progress (rather than routing it through this state machine at
        // all) would silently lose the only signal that ever releases a deferred completion. Proven
        // here by never seeing a completion without it.
        let (mut turns, clock) = state();
        let turn_id = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());

        // Advance time without ever delivering idle or letting the fallback fire: no completion.
        clock.jump_forward(Duration::from_millis(500));
        assert_eq!(turns.poll_fallback(no_diagnostics()), None);
        assert!(turns.has_pending_turn_ids());

        // Now deliver idle: exactly one completion, for the right turn.
        assert_eq!(
            turns.on_session_state_changed("idle", no_diagnostics()),
            Some(TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            })
        );
    }

    // MARK: - determine_status / the interrupt short-circuit

    #[test]
    fn turn_was_interrupted_short_circuits_to_cancelled_and_is_consumed_on_read() {
        let (mut turns, _clock) = state();
        turns.mark_interrupted();
        assert!(turns.turn_was_interrupted_for_testing());
        let status = turns.determine_status(
            true,
            "error_during_execution",
            "",
            None,
            None,
            &["boom".to_string()],
        );
        assert_eq!(
            status,
            TurnStatus::Cancelled,
            "an ACKed interrupt makes the very next result a cancellation, not a failure"
        );
        assert!(
            !turns.turn_was_interrupted_for_testing(),
            "must be consumed on read"
        );

        // The SECOND result after the interrupt is evaluated normally -- proving the flag was truly
        // consumed, not merely ignored-then-reset-by-something-else.
        let status = turns.determine_status(
            true,
            "error_during_execution",
            "",
            None,
            None,
            &["boom again".to_string()],
        );
        assert_eq!(status, TurnStatus::Failed);
    }

    #[test]
    fn cancelled_signal_tokens_are_substring_matched_across_every_input_including_nested_and_errors()
     {
        let (mut turns, _clock) = state();
        assert_eq!(
            turns.determine_status(false, "user_cancelled_it", "", None, None, &[]),
            TurnStatus::Cancelled
        );
        assert_eq!(
            turns.determine_status(false, "", "the request was aborted", None, None, &[]),
            TurnStatus::Cancelled
        );
        assert_eq!(
            turns.determine_status(false, "", "", Some("Interrupt"), None, &[]),
            TurnStatus::Cancelled
        );
        assert_eq!(
            turns.determine_status(false, "", "", None, Some("cancelled by nested delta"), &[]),
            TurnStatus::Cancelled
        );
        assert_eq!(
            turns.determine_status(
                false,
                "",
                "",
                None,
                None,
                &["Aborted mid-flight".to_string()]
            ),
            TurnStatus::Cancelled
        );
    }

    #[test]
    fn is_error_or_error_subtype_or_nonempty_errors_maps_to_failed_when_not_cancelled() {
        let (mut turns, _clock) = state();
        assert_eq!(
            turns.determine_status(true, "success", "", None, None, &[]),
            TurnStatus::Failed
        );
        assert_eq!(
            turns.determine_status(false, "error_max_turns", "", None, None, &[]),
            TurnStatus::Failed
        );
        assert_eq!(
            turns.determine_status(
                false,
                "success",
                "",
                None,
                None,
                &["Maximum turns exceeded".to_string()]
            ),
            TurnStatus::Failed
        );
    }

    #[test]
    fn no_error_and_no_cancel_signal_maps_to_completed() {
        let (mut turns, _clock) = state();
        assert_eq!(
            turns.determine_status(false, "success", "end_turn", None, None, &[]),
            TurnStatus::Completed
        );
    }

    #[test]
    fn result_with_no_pending_turn_id_raises_the_protocol_drift_diagnostic_not_a_panic() {
        let (mut turns, _clock) = state();
        let mut diagnostics = Vec::new();
        let event = turns.on_authoritative_result(TurnStatus::Completed, |d| diagnostics.push(d));
        assert_eq!(event, None);
        assert_eq!(diagnostics, vec![TurnDiagnostic::ResultWithNoPendingTurnId]);
    }

    // MARK: - EOF: flush deferred (preserving original status) then drain the rest as Failed,
    // preceded by exactly one Error.

    #[test]
    fn eof_flushes_deferred_with_original_status_then_fails_the_rest_after_one_error() {
        let (mut turns, _clock) = state();
        let deferred_turn = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        // Deferred with a non-Failed status -- EOF must NOT rewrite this to Failed.
        turns.on_authoritative_result(TurnStatus::Cancelled, no_diagnostics());

        // Two more turns are sent but never receive any result at all before EOF.
        let never_resulted_1 = turns.send_user_message();
        let never_resulted_2 = turns.send_user_message();

        let events = turns.on_stdout_eof();
        assert_eq!(
            events,
            vec![
                TurnEvent::TurnCompleted {
                    turn_id: deferred_turn,
                    status: TurnStatus::Cancelled
                },
                TurnEvent::Error("Claude process exited unexpectedly.".to_string()),
                TurnEvent::TurnCompleted {
                    turn_id: never_resulted_1,
                    status: TurnStatus::Failed
                },
                TurnEvent::TurnCompleted {
                    turn_id: never_resulted_2,
                    status: TurnStatus::Failed
                },
            ],
            "deferred status preserved verbatim, then exactly one Error, then the rest as Failed, in FIFO order"
        );
        assert!(!turns.has_pending_turn_ids());
    }

    #[test]
    fn eof_with_nothing_pending_at_all_emits_no_events() {
        let (mut turns, _clock) = state();
        assert_eq!(turns.on_stdout_eof(), Vec::new());
    }

    #[test]
    fn eof_with_only_deferred_entries_and_no_stale_turns_emits_no_error() {
        let (mut turns, _clock) = state();
        let turn_id = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        let events = turns.on_stdout_eof();
        assert_eq!(
            events,
            vec![TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            }]
        );
    }

    // MARK: - Shutdown: flush deferred, then silently drop the rest (module doc's discrepancy note)

    #[test]
    fn shutdown_flushes_deferred_with_original_status_and_silently_drops_never_resulted_turns() {
        let (mut turns, _clock) = state();
        let deferred_turn = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Failed, no_diagnostics());
        let _never_resulted = turns.send_user_message();

        let events = turns.on_shutdown();
        assert_eq!(
            events,
            vec![TurnEvent::TurnCompleted {
                turn_id: deferred_turn,
                status: TurnStatus::Failed
            }],
            "shutdown must flush deferred completions with their original status, never rewritten"
        );
        assert!(
            !turns.has_pending_turn_ids(),
            "shutdown clears the whole queue, including never-resulted turns"
        );
    }

    #[test]
    fn shutdown_never_rewrites_a_completed_deferred_status_to_failed() {
        let (mut turns, _clock) = state();
        let turn_id = turns.send_user_message();
        turns.on_session_state_changed("running", no_diagnostics());
        turns.on_authoritative_result(TurnStatus::Completed, no_diagnostics());
        assert_eq!(
            turns.on_shutdown(),
            vec![TurnEvent::TurnCompleted {
                turn_id,
                status: TurnStatus::Completed
            }]
        );
    }

    #[test]
    fn shutdown_with_nothing_pending_emits_no_events() {
        let (mut turns, _clock) = state();
        assert_eq!(turns.on_shutdown(), Vec::new());
    }
}
