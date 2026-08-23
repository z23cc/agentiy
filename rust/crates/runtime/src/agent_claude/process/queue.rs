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
    /// Emitted when one or more `Line` events were evicted for capacity in a single [`push`]
    /// call -- the gap-record analogue (contract §7.1 / `subscription.rs`'s pressure policy).
    /// Coalesced: exactly one `Gap` is ever produced per `push`, however many `Line`s that one
    /// call evicted to make room (see `push`'s own doc for the bug this coalescing fixes).
    ///
    /// [`push`]: BoundedEventQueue::push
    Gap { first_dropped_seq: u64, dropped_count: u64 },
}

/// Fixed accounting cost for a `Diagnostic`/`Gap` event -- also reserved headroom in [`push`] so a
/// single push never needs a second eviction pass to make room for the coalesced `Gap` it might
/// emit.
///
/// [`push`]: BoundedEventQueue::push
const GAP_COST: usize = 64;

fn event_byte_cost(event: &QueueEvent) -> usize {
    match event {
        QueueEvent::Line { bytes, .. } => bytes.len(),
        QueueEvent::Diagnostic(_) | QueueEvent::Gap { .. } => GAP_COST,
        QueueEvent::Terminal(s) => s.len(),
    }
}

struct Inner {
    ring: VecDeque<QueueEvent>,
    current_bytes: usize,
    terminal: Option<QueueEvent>,
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
            }),
            condvar: Condvar::new(),
            dropped_count: AtomicU64::new(0),
            peak_bytes: AtomicUsize::new(0),
            max_events,
            max_bytes,
        }
    }

    /// Non-blocking by construction -- never waits for space (INV-P6-2's non-blocking-publish
    /// half). Evicts the oldest ring entries and records **at most one** coalesced `Gap` when
    /// `event` would exceed either cap.
    ///
    /// **The bug an earlier draft had.** That version evicted one oldest entry, and if it was a
    /// `Line`, immediately pushed a replacement `Gap` back onto the *same* ring before re-checking
    /// the loop condition. Because pop-one/push-one leaves `ring.len()` unchanged, a count-cap-
    /// bound workload (many small events, nowhere near the byte cap) never made the count
    /// predicate false, so a single `push` call walked the *entire* ring converting every resident
    /// `Line` into its own `Gap` -- measured steady state ~255 `Gap`s + 1 `Line` out of a
    /// 256-capacity ring under sustained flood pressure. This version defers the `Gap` push until
    /// after eviction is decided, reserving headroom for it up front (two slots and `cost +
    /// GAP_COST` bytes, not just one and `cost`) so it never needs a second eviction pass -- at
    /// most one `Gap` record is created per `push`, however many `Line`s that call evicted. Full
    /// coalesce-by-key / lossy-before-lossless prioritization (`subscription.rs`'s richer policy)
    /// is out of scope here -- this module's only guarantee is bounding `Gap` production to one
    /// record per `push` call.
    pub fn push(&self, event: QueueEvent) {
        let cost = event_byte_cost(&event);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Reserve room for both the incoming event and a possible coalesced `Gap`, unconditionally
        // -- whether or not this pass ends up evicting a `Line` (and therefore actually needing to
        // emit one). Mildly conservative when no `Gap` turns out to be needed; never wrong.
        let reserved_slots = self.max_events.saturating_sub(2).max(1);
        let mut first_dropped_seq: Option<u64> = None;
        let mut dropped_lines: u64 = 0;
        while guard.ring.len() >= reserved_slots || guard.current_bytes + cost + GAP_COST > self.max_bytes {
            let Some(evicted) = guard.ring.pop_front() else {
                break; // ring already empty -- the incoming event (plus reserved gap headroom)
                       // alone exceeds the byte cap; admitted anyway below.
            };
            guard.current_bytes -= event_byte_cost(&evicted);
            self.dropped_count.fetch_add(1, Ordering::SeqCst);
            if let QueueEvent::Line { seq, .. } = evicted {
                first_dropped_seq.get_or_insert(seq);
                dropped_lines += 1;
            }
        }
        if let Some(first_dropped_seq) = first_dropped_seq {
            let gap = QueueEvent::Gap { first_dropped_seq, dropped_count: dropped_lines };
            guard.current_bytes += event_byte_cost(&gap);
            guard.ring.push_back(gap);
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

    pub fn drain(&self) -> Vec<QueueEvent> {
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.ring.drain(..).collect()
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
    fn a_single_push_that_evicts_many_lines_emits_only_one_coalesced_gap() {
        // Regression test for the exact defect an earlier draft had (see `push`'s own doc): a
        // naive "pop one, push a replacement Gap back" loop never shrinks `ring.len()` (pop one,
        // push one), so a count- or byte-bound eviction pass inside a *single* `push` call walked
        // the entire ring, converting every resident `Line` into its own `Gap`. Fill the ring with
        // many tiny `Line`s that fit comfortably (no eviction yet), then make one `push` call whose
        // byte cost forces evicting all of them at once -- that one call must coalesce into exactly
        // one `Gap`, not twenty.
        let queue = BoundedEventQueue::with_limits(64, 100);
        for seq in 0..20u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 2] });
        }
        queue.push(QueueEvent::Line { seq: 999, bytes: vec![b'y'; 80] });
        let drained = queue.drain();
        let gap_count = drained.iter().filter(|e| matches!(e, QueueEvent::Gap { .. })).count();
        assert_eq!(gap_count, 1, "one push evicting many Lines must coalesce into exactly one Gap, got {drained:?}");
        assert!(
            drained.iter().any(|e| matches!(e, QueueEvent::Line { seq: 999, .. })),
            "the newly admitted event must be present: {drained:?}"
        );
    }

    #[test]
    fn sustained_count_pressure_never_evicts_every_retained_line() {
        // Complementary regression net at the count-cap boundary (rather than the byte-cap
        // boundary above): pushing far more small `Line`s than `max_events` must still leave at
        // least one `Line` resident, not degrade the whole ring into `Gap`s.
        let queue = BoundedEventQueue::with_limits(8, 1_048_576);
        for seq in 0..64u64 {
            queue.push(QueueEvent::Line { seq, bytes: vec![b'x'; 8] });
        }
        let drained = queue.drain();
        assert!(drained.len() <= 8, "ring must never exceed its configured event cap: {drained:?}");
        let line_count = drained.iter().filter(|e| matches!(e, QueueEvent::Line { .. })).count();
        assert!(line_count >= 1, "sustained count pressure must not evict every retained Line: {drained:?}");
    }

    #[test]
    fn a_single_oversized_event_is_admitted_anyway() {
        let queue = BoundedEventQueue::with_limits(8, 64);
        queue.push(QueueEvent::Line { seq: 1, bytes: vec![b'x'; 200] });
        let drained = queue.drain();
        assert_eq!(drained.len(), 1, "the oversized item is admitted alone despite exceeding the byte cap: {drained:?}");
    }
}
