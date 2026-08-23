//! E-P6-3: an INV-P6-2 reader harness -- "there is no intermediate byte channel between the pipe
//! and the decoder. One reader per stream performs `read()` -> frame -> decode -> translate ->
//! non-blocking publish, inline. The stdout pipe is drained unconditionally and continuously,
//! whatever the state of the event queue" (contract section 5.3).
//!
//! **Scope, precisely.** This is a transport-plane harness, not a codec: lines are framed on raw
//! `\n` with the design's 8 MiB max-line cap, but there is no JSON-string-escape-aware
//! quote/candidacy tracking (contract section 5.4's "JSON-candidacy quote/escape tracking, only
//! active when a line starts with `{`/`[`") -- that behavior is P6-3's codec/framer port and its
//! re-chunking pass (design section 3.4), not this spike's concern. What *is* in scope and what
//! this harness actually measures: unconditional draining under backpressure, non-blocking publish
//! into a capacity-bounded queue with a reserved terminal-event slot, and the deadlock probe
//! (design section 8 E-P6-3's "child stops reading stdin while flooding stdout, parent
//! concurrently interrupts").

use std::collections::VecDeque;
use std::io::Read;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;

/// Port of `ProcessStreamFraming.swift`'s `LineFramer.Limits.default` max-line value (contract
/// section 5.4). Carry/tail-retain granularity is simplified for this spike (see module doc).
pub const FRAMER_MAX_LINE_BYTES: usize = 8 * 1024 * 1024;
pub const FRAMER_TAIL_RETAIN_BYTES: usize = 128 * 1024;

/// Port of `subscription.rs`'s existing queue constants (contract section 5.4's second cap row).
pub const QUEUE_MAX_EVENTS: usize = 256;
pub const QUEUE_MAX_BYTES: usize = 1024 * 1024;
pub const RESERVED_TERMINAL_SLOTS: usize = 1;

#[derive(Debug, Clone)]
pub enum QueueEvent {
    /// A framed line -- the `assistantDelta`-shaped lossless-but-evictable-under-pressure class
    /// (contract section 7.1's event catalog).
    Line { seq: u64, bytes: Vec<u8> },
    /// A droppable diagnostic (contract section 7.1's `framerOverflow`/`protocolDrift` row).
    FramerOverflow { retained_tail_bytes: usize },
    /// The reserved-capacity terminal-class event (`turnCompleted`/`interruptOutcome` shape) --
    /// never evicted, matching `RESERVED_TERMINAL_SLOTS`.
    Terminal(String),
    /// Emitted when a `Line` event had to be evicted for capacity -- the gap-record analogue
    /// (contract section 5.4 / `subscription.rs`'s pressure policy).
    Gap { dropped_seq: u64 },
}

fn event_byte_cost(event: &QueueEvent) -> usize {
    match event {
        QueueEvent::Line { bytes, .. } => bytes.len(),
        QueueEvent::FramerOverflow { .. } | QueueEvent::Gap { .. } => 64,
        QueueEvent::Terminal(s) => s.len(),
    }
}

struct QueueInner {
    ring: VecDeque<QueueEvent>,
    current_bytes: usize,
    /// Reserved terminal slot -- separate from `ring` so ring-capacity pressure can never evict it.
    terminal: Option<QueueEvent>,
}

pub struct BoundedEventQueue {
    inner: Mutex<QueueInner>,
    condvar: Condvar,
    pub dropped_count: AtomicU64,
    pub peak_bytes: AtomicUsize,
}

impl Default for BoundedEventQueue {
    fn default() -> Self {
        Self {
            inner: Mutex::new(QueueInner {
                ring: VecDeque::new(),
                current_bytes: 0,
                terminal: None,
            }),
            condvar: Condvar::new(),
            dropped_count: AtomicU64::new(0),
            peak_bytes: AtomicUsize::new(0),
        }
    }
}

impl BoundedEventQueue {
    /// Non-blocking by construction: never waits for space. Evicts the oldest ring entry (and
    /// records a `Gap`) when `event` would exceed either the event-count or byte-budget cap.
    /// This is the property INV-P6-2 depends on -- the reader thread that calls this must never
    /// stall regardless of how full the queue is.
    pub fn push(&self, event: QueueEvent) {
        let cost = event_byte_cost(&event);
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        while guard.ring.len() >= QUEUE_MAX_EVENTS || guard.current_bytes + cost > QUEUE_MAX_BYTES {
            let Some(evicted) = guard.ring.pop_front() else {
                break; // ring already empty but a single event exceeds the byte cap -- admit it anyway
            };
            guard.current_bytes -= event_byte_cost(&evicted);
            self.dropped_count.fetch_add(1, Ordering::SeqCst);
            if let QueueEvent::Line { seq, .. } = evicted {
                guard.ring.push_back(QueueEvent::Gap { dropped_seq: seq });
                guard.current_bytes += event_byte_cost(&QueueEvent::Gap { dropped_seq: seq });
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

pub struct ReaderStats {
    pub lines_read: AtomicU64,
    pub bytes_read: AtomicU64,
    pub framer_overflows: AtomicU64,
    /// Heartbeat: the reader increments this every loop iteration, whether or not a full line was
    /// available. A test asserting no-deadlock samples this twice across a wait window and
    /// requires it to have advanced -- direct evidence the reader thread was never blocked.
    pub loop_iterations: AtomicU64,
}

impl Default for ReaderStats {
    fn default() -> Self {
        Self {
            lines_read: AtomicU64::new(0),
            bytes_read: AtomicU64::new(0),
            framer_overflows: AtomicU64::new(0),
            loop_iterations: AtomicU64::new(0),
        }
    }
}

/// Spawns the one-reader-per-stream thread implementing INV-P6-2: blocking `read()`, frame on
/// `\n` with an 8 MiB cap (overflow: drop the carry buffer's prefix, retain the last 128 KiB tail,
/// emit a `FramerOverflow` diagnostic -- contract section 5.4), non-blocking `queue.push` per
/// line. Returns when the pipe reaches EOF (mirrors `handleStdoutEOF`, contract section 3 EOF
/// handling scope -- this harness does not itself drive a turn-lifecycle state machine).
pub fn spawn_reader(mut stdout: std::fs::File, queue: Arc<BoundedEventQueue>) -> (JoinHandle<()>, Arc<ReaderStats>) {
    let stats = Arc::new(ReaderStats::default());
    let thread_stats = Arc::clone(&stats);
    let handle = std::thread::Builder::new()
        .name("agent-stdout-reader".to_string())
        .spawn(move || {
            let mut carry: Vec<u8> = Vec::new();
            let mut buf = [0u8; 64 * 1024];
            let mut seq: u64 = 0;
            loop {
                thread_stats.loop_iterations.fetch_add(1, Ordering::SeqCst);
                let n = match stdout.read(&mut buf) {
                    Ok(0) => break, // EOF
                    Ok(n) => n,
                    Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                thread_stats.bytes_read.fetch_add(n as u64, Ordering::SeqCst);
                carry.extend_from_slice(&buf[..n]);

                loop {
                    let Some(newline_at) = carry.iter().position(|&b| b == b'\n') else {
                        break;
                    };
                    let line: Vec<u8> = carry.drain(..=newline_at).collect();
                    let line = &line[..line.len() - 1]; // strip the trailing \n
                    thread_stats.lines_read.fetch_add(1, Ordering::SeqCst);
                    queue.push(QueueEvent::Line { seq, bytes: line.to_vec() });
                    seq += 1;
                }

                if carry.len() > FRAMER_MAX_LINE_BYTES {
                    let retained_tail_bytes = FRAMER_TAIL_RETAIN_BYTES.min(carry.len());
                    let tail_start = carry.len() - retained_tail_bytes;
                    carry = carry[tail_start..].to_vec();
                    thread_stats.framer_overflows.fetch_add(1, Ordering::SeqCst);
                    queue.push(QueueEvent::FramerOverflow { retained_tail_bytes });
                }
            }
        })
        .expect("spawning the stdout reader thread must succeed");
    (handle, stats)
}
