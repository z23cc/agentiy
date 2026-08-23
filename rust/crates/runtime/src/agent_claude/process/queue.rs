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
    /// Emitted when a `Line` event was evicted for capacity -- the gap-record analogue (contract
    /// §7.1 / `subscription.rs`'s pressure policy).
    Gap { dropped_seq: u64 },
}

fn event_byte_cost(event: &QueueEvent) -> usize {
    match event {
        QueueEvent::Line { bytes, .. } => bytes.len(),
        QueueEvent::Diagnostic(_) | QueueEvent::Gap { .. } => 64,
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
    /// half). Evicts the oldest ring entry (and records a `Gap`) when `event` would exceed either
    /// cap.
    pub fn push(&self, event: QueueEvent) {
        let cost = event_byte_cost(&event);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while guard.ring.len() >= self.max_events || guard.current_bytes + cost > self.max_bytes {
            let Some(evicted) = guard.ring.pop_front() else {
                break; // ring already empty but a single event exceeds the byte cap -- admit anyway
            };
            guard.current_bytes -= event_byte_cost(&evicted);
            self.dropped_count.fetch_add(1, Ordering::SeqCst);
            if let QueueEvent::Line { seq, .. } = evicted {
                let gap = QueueEvent::Gap { dropped_seq: seq };
                guard.current_bytes += event_byte_cost(&gap);
                guard.ring.push_back(gap);
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
