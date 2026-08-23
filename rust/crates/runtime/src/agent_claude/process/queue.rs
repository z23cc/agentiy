//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.3/§5.4, design §4.3/§4.4): the bounded,
//! non-blocking event queue a per-stream reader thread publishes into, implementing INV-P6-2's
//! "publish is non-blocking, whatever the state of the event queue" half. Reuses
//! [`crate::subscription`]'s already-frozen queue constants (`DEFAULT_MAX_QUEUED_EVENTS`,
//! `DEFAULT_MAX_QUEUED_BYTES`, `RESERVED_TERMINAL_SLOTS`) rather than re-declaring them, so this
//! and the eventual `SubscriptionHub` wiring (P6-6) share one source of truth for the cap.
//!
//! **Scope discipline.** This is *not* the `SubscriptionHub`/`open_subscription` machinery design
//! §7.1 describes as the eventual home for these events -- that machinery is scoped to an "agent
//! scope" object P6-5/P6-6 build. P6-4 is cargo-only process supervision: this queue is the
//! reader-thread-facing half of that contract (bounded, non-blocking, reserved terminal capacity,
//! gap-on-eviction), standing in exactly as the P6-2 spike's `stream.rs` did, until P6-6 wires a
//! reader's output into the real hub.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};

use crate::subscription::{DEFAULT_MAX_QUEUED_BYTES, DEFAULT_MAX_QUEUED_EVENTS};

#[derive(Debug, Clone)]
pub enum QueueEvent {
    /// A framed protocol line -- the `assistantDelta`-shaped lossless-but-evictable-under-pressure
    /// class (contract §7.1).
    Line { seq: u64, bytes: Vec<u8> },
    /// A droppable diagnostic (contract §7.1's `framerOverflow`/`protocolDrift` row).
    Diagnostic(&'static str),
    /// The reserved-capacity terminal-class event slot (`turnCompleted`/`interruptOutcome` shape)
    /// -- never evicted by ring pressure.
    Terminal(String),
    /// The reserved-capacity gap-record slot (contract §7.1 / `subscription.rs`'s pressure
    /// policy), mirroring `Terminal`'s "own slot, not a ring entry" treatment. Every `Line` evicted
    /// by ring pressure -- across however many separate [`push`] calls happen before the next
    /// [`BoundedEventQueue::drain`] -- coalesces into this **one** outstanding record: at most one
    /// `Gap` event can ever be observed per drain, never one per eviction and never one per `push`
    /// call either (see `push`'s own doc for the defect this closes and the weaker guarantee an
    /// earlier draft settled for).
    ///
    /// [`push`]: BoundedEventQueue::push
    Gap { first_dropped_seq: u64, dropped_count: u64 },
}

fn event_byte_cost(event: &QueueEvent) -> usize {
    match event {
        QueueEvent::Line { bytes, .. } => bytes.len(),
        QueueEvent::Diagnostic(_) | QueueEvent::Gap { .. } => 64,
        QueueEvent::Terminal(s) => s.len(),
    }
}

/// Accumulator for the reserved gap slot (see `QueueEvent::Gap`'s doc) -- not itself a
/// `QueueEvent`; materialized into one only when [`BoundedEventQueue::drain`] is called.
struct GapAccumulator {
    first_dropped_seq: u64,
    dropped_count: u64,
}

struct Inner {
    ring: VecDeque<QueueEvent>,
    current_bytes: usize,
    terminal: Option<QueueEvent>,
    /// Reserved coalesced-gap slot -- lives outside the ring entirely (like `terminal`), so it
    /// never competes with `Line`/`Diagnostic` content for `max_events`/`max_bytes` headroom and
    /// never needs a second eviction pass to make room for itself.
    gap: Option<GapAccumulator>,
}

pub struct BoundedEventQueue {
    inner: Mutex<Inner>,
    condvar: Condvar,
    pub dropped_count: AtomicU64,
    pub peak_bytes: AtomicUsize,
    max_events: usize,
    max_bytes: usize,
}

impl Default for BoundedEventQueue {
    fn default() -> Self {
        Self::with_limits(DEFAULT_MAX_QUEUED_EVENTS, DEFAULT_MAX_QUEUED_BYTES)
    }
}

impl BoundedEventQueue {
    pub fn with_limits(max_events: usize, max_bytes: usize) -> Self {
        Self {
            inner: Mutex::new(Inner {
                ring: VecDeque::new(),
                current_bytes: 0,
                terminal: None,
                gap: None,
            }),
            condvar: Condvar::new(),
            dropped_count: AtomicU64::new(0),
            peak_bytes: AtomicUsize::new(0),
            max_events,
            max_bytes,
        }
    }

    /// Non-blocking by construction -- never waits for space (INV-P6-2's non-blocking-publish
    /// half). Evicts the oldest ring entries and merges every evicted `Line` into the one reserved
    /// gap slot (see `QueueEvent::Gap`'s doc) when `event` would exceed either cap.
    ///
    /// **Two defects an earlier draft had, in order of discovery.** The first version evicted one
    /// oldest entry and, if it was a `Line`, immediately pushed a replacement `Gap` *back onto the
    /// same ring* before re-checking the loop condition; pop-one/push-one leaves `ring.len()`
    /// unchanged, so a count-cap-bound workload never made the loop's predicate false and a single
    /// `push` call walked the entire ring converting every resident `Line` into its own `Gap`
    /// (measured steady state ~255 `Gap`s + 1 `Line` out of a 256-capacity ring). A second draft
    /// moved the `Gap` push to after the loop and reserved headroom for it, bounding production to
    /// one `Gap` per `push` call -- an improvement, but under sustained count pressure (a flood
    /// that evicts on every single `push`) that still degrades to roughly half the ring being `Gap`
    /// records at equilibrium, not the "coalesce lossy notification" property contract §7.1
    /// actually wants. This version closes it exactly, mirroring the `terminal` reserved slot
    /// already in this struct: eviction merges into `Inner::gap`, which never occupies a ring
    /// entry and is only materialized into a `QueueEvent::Gap` by `drain`. At most one `Gap` can
    /// ever be observed per drain, regardless of how many `push` calls evicted content in between.
    pub fn push(&self, event: QueueEvent) {
        let cost = event_byte_cost(&event);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while guard.ring.len() >= self.max_events || guard.current_bytes + cost > self.max_bytes {
            let Some(evicted) = guard.ring.pop_front() else {
                break; // ring already empty but the incoming event alone exceeds the byte cap --
                       // admitted anyway below.
            };
            guard.current_bytes -= event_byte_cost(&evicted);
            self.dropped_count.fetch_add(1, Ordering::SeqCst);
            if let QueueEvent::Line { seq, .. } = evicted {
                match &mut guard.gap {
                    Some(existing) => existing.dropped_count += 1,
                    None => {
                        guard.gap = Some(GapAccumulator {
                            first_dropped_seq: seq,
                            dropped_count: 1,
                        });
                    }
                }
            }
        }
        guard.current_bytes += cost;
        guard.ring.push_back(event);
        self.peak_bytes.fetch_max(guard.current_bytes, Ordering::SeqCst);
        drop(guard);
        self.condvar.notify_all();
    }

    /// Terminal events use the reserved slot and are never evicted by ring pressure.
    pub fn push_terminal(&self, event: QueueEvent) {
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.terminal = Some(event);
        drop(guard);
        self.condvar.notify_all();
    }

    /// Drains the ring, prepending the single coalesced `Gap` record (if any content was evicted
    /// since the last drain) -- chronologically first, since it represents the oldest content this
    /// queue ever held.
    ///
    /// **Bug an earlier draft had, found by review (pre-existing since the first P6-4 landing,
    /// `603b4c10`).** `current_bytes` was never reset here -- it only ever decreases inside
    /// `push`'s eviction loop, by the byte cost of items actually still resident. Every drained
    /// event's bytes stayed charged against the budget forever, so the effective byte budget
    /// shrank monotonically across drain cycles: once the stale surplus approached `max_bytes`,
    /// every subsequent `push` would evict the *entire* ring (eviction can only reclaim bytes for
    /// resident items, never the surplus) and then admit anyway via the ring-empty break --
    /// steady state ~1 resident event, in a long-running session that drains and refills
    /// repeatedly (the P6-8 soak shape), the same symptom class the two eviction-coalescing fixes
    /// above exist to prevent, reached by a different route. Every test up to this point
    /// constructed a fresh queue, pushed, drained once, and asserted -- none pushed again after a
    /// drain, which is why the leak went unnoticed through two prior correction passes. Draining
    /// the ring empties it completely, so resetting to exactly `0` (not merely subtracting the
    /// drained items' cost) is correct: `terminal` and the gap accumulator never contribute to
    /// `current_bytes` in the first place.
    pub fn drain(&self) -> Vec<QueueEvent> {
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let gap = guard.gap.take().map(|g| QueueEvent::Gap {
            first_dropped_seq: g.first_dropped_seq,
            dropped_count: g.dropped_count,
        });
        let mut drained = Vec::with_capacity(guard.ring.len() + usize::from(gap.is_some()));
        drained.extend(gap);
        drained.extend(guard.ring.drain(..));
        guard.current_bytes = 0;
        drained
    }

    pub fn take_terminal(&self, timeout: std::time::Duration) -> Option<QueueEvent> {
        let guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (mut guard, _) = self
            .condvar
            .wait_timeout_while(guard, timeout, |g| g.terminal.is_none())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.terminal.take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_single_push_that_evicts_many_lines_coalesces_into_the_one_reserved_gap_slot() {
        // Regression test for the first defect an earlier draft had (see `push`'s own doc): fill
        // the ring with many tiny `Line`s that fit comfortably (no eviction yet), then make one
        // `push` call whose byte cost forces evicting all of them at once -- the reserved gap slot
        // must absorb all twenty, not spawn twenty ring entries.
        let queue = BoundedEventQueue::with_limits(64, 100);
        for seq in 0..20u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 2] });
        }
        // 20 * 2 = 40 resident bytes; admitting a 100-byte event needs current_bytes back to 0
        // (40 + 100 > 100 at every count down to zero, 0 + 100 == 100 stops it there) -- evicts
        // exactly all twenty in this one call.
        queue.push(QueueEvent::Line { seq: 999, bytes: vec![b'y'; 100] });
        let drained = queue.drain();
        let gap_count = drained.iter().filter(|e| matches!(e, QueueEvent::Gap { .. })).count();
        assert_eq!(gap_count, 1, "twenty evicted Lines must coalesce into exactly one Gap, got {drained:?}");
        assert!(
            matches!(drained.first(), Some(QueueEvent::Gap { dropped_count: 20, .. })),
            "the coalesced Gap must report all 20 evicted Lines: {drained:?}"
        );
        assert!(
            drained.iter().any(|e| matches!(e, QueueEvent::Line { seq: 999, .. })),
            "the newly admitted event must be present: {drained:?}"
        );
    }

    #[test]
    fn sustained_count_pressure_across_many_separate_pushes_still_yields_exactly_one_gap() {
        // The second, subtler defect an earlier draft had (see `push`'s own doc): bounding `Gap`
        // production to "at most one per `push` call" still degrades to roughly half the ring
        // being `Gap` records under *sustained* count pressure across many separate `push` calls
        // (a real flood evicts on nearly every call). The reserved gap slot closes this exactly:
        // regardless of how many of the 64 pushes below evict something, at most one `Gap` can
        // ever be observed at drain time.
        let queue = BoundedEventQueue::with_limits(8, 1_048_576);
        for seq in 0..64u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 8] });
        }
        let drained = queue.drain();
        assert!(drained.len() <= 9, "ring must never exceed its configured event cap plus the one gap slot: {drained:?}");
        let gap_count = drained.iter().filter(|e| matches!(e, QueueEvent::Gap { .. })).count();
        assert!(gap_count <= 1, "sustained pressure across many pushes must still yield at most one Gap: {drained:?}");
        let line_count = drained.iter().filter(|e| matches!(e, QueueEvent::Line { .. })).count();
        assert_eq!(line_count, 8, "every non-gap ring slot must be real retained Line content, not further gap residue: {drained:?}");
    }

    #[test]
    fn drain_resets_the_byte_budget_so_a_refill_after_drain_starts_clean() {
        // Regression test for the exact defect review found: an earlier `drain` never reset
        // `current_bytes`, so every drained event's bytes stayed charged against the budget
        // forever -- a long-running session that drains and refills repeatedly (the P6-8 soak
        // shape) would see the effective byte budget shrink monotonically until every `push`
        // evicted the entire ring. Fill to exactly the byte cap, drain, then push the same volume
        // again: without the reset this second batch would immediately start evicting (producing
        // a Gap); with it, all 8 land clean.
        let queue = BoundedEventQueue::with_limits(8, 100);
        for seq in 0..8u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 10] });
        }
        assert_eq!(queue.drain().len(), 8, "first batch must land in full");
        for seq in 8..16u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 10] });
        }
        let refilled = queue.drain();
        assert!(
            !refilled.iter().any(|e| matches!(e, QueueEvent::Gap { .. })),
            "a drained queue must start from a clean byte budget, not a stale carried-over one: {refilled:?}"
        );
        assert_eq!(refilled.len(), 8, "the second batch must also land in full: {refilled:?}");
    }

    #[test]
    fn a_single_oversized_event_is_admitted_anyway() {
        let queue = BoundedEventQueue::with_limits(8, 64);
        queue.push(QueueEvent::Line { seq: 1, bytes: vec![b'x'; 200] });
        let drained = queue.drain();
        assert_eq!(drained.len(), 1, "the oversized item is admitted alone despite exceeding the byte cap: {drained:?}");
    }
}
