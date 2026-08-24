//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.3/§5.4, design §4.3): per-stream reader
//! threads implementing INV-P6-2 -- "one reader per stream performs `read()` -> frame -> decode ->
//! translate -> non-blocking publish, inline. The stdout pipe is drained unconditionally and
//! continuously, whatever the state of the event queue." Promoted from the P6-2 spike
//! (`rust/spikes/agent-claude-derisking-spike/src/stream.rs`), with two production upgrades over
//! the spike's scoped-down harness: the real byte-exact [`crate::agent_claude::framer::LineFramer`]
//! (JSON-candidacy quote/escape tracking) rather than a raw `\n` split, and a real stderr tail
//! ([`super::stderr_tail::StderrTail`]) rather than treating stderr like stdout.
//!
//! **Scope discipline: framing only, not decode/translate.** This module frames stdout into lines
//! and publishes them; it does not decode or translate them (`agent_claude::codec`/`translator`
//! are P6-3-landed but consumed by the turn state machine, P6-5). Wiring a reader's framed-line
//! output through the codec/translator into turn-lifecycle events is P6-5's job -- this module's
//! contract is the transport half only: "one reader per stream, never blocks, drains
//! unconditionally, publishes non-blocking."
//!
//! **QoS, named rather than silently applied.** Contract §5.3 states reader threads (and the
//! reaper thread) should run at `userInitiated` QoS, matching `ProcessTermination.swift:107-110`'s
//! queue QoS. Setting Darwin thread QoS class programmatically
//! (`pthread_set_qos_class_self_np`) is FFI requiring its own `unsafe` block, and this crate's
//! *only* confirmed, contract-sanctioned `unsafe_code` exception is
//! [`crate::agent_claude::process::addchdir`] (contract §5.2/§12's specifically-named prerequisite
//! -- QoS-class setting is not named there or in the design's P6-4 done-when list). Deferred here
//! by name rather than silently applied via a second unsafe site or silently dropped: threads run
//! at the process's default QoS today; if a later step's measurement shows this materially matters
//! (E-P6-2/E-P6-3's thread-count and latency criteria did not surface it as material at the
//! registered N range), it is a one-function, one-`unsafe`-block addition with its own scoped
//! exception, not a design change.

use std::fs::File;
use std::io::Read;
use std::os::fd::OwnedFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::JoinHandle;

use crate::agent_claude::framer::{FramerDiagnostic, LineFramer};

use super::queue::{BoundedEventQueue, QueueEvent};
use super::stderr_tail::StderrTail;
use super::thread_budget::{self, ThreadBudgetGuard};

pub struct ReaderStats {
    pub lines_read: AtomicU64,
    pub bytes_read: AtomicU64,
    pub framer_overflows: AtomicU64,
    /// Heartbeat: incremented every loop iteration regardless of whether a full line was
    /// available. A no-deadlock test samples this twice across a wait window and requires it to
    /// have advanced -- direct evidence the reader thread was never blocked (INV-P6-2).
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

/// Spawns the stdout reader thread: blocking `read()` -> real `LineFramer` -> non-blocking
/// `queue.push` per line (and per overflow diagnostic). Returns when the pipe reaches EOF.
pub fn spawn_stdout_reader(
    fd: OwnedFd,
    queue: Arc<BoundedEventQueue>,
) -> (JoinHandle<()>, Arc<ReaderStats>) {
    let stats = Arc::new(ReaderStats::default());
    let thread_stats = Arc::clone(&stats);
    // Incremented synchronously here, in the spawning thread, before the new thread starts -- see
    // `thread_budget::increment`'s doc for why this must not happen inside the new thread's own
    // closure.
    thread_budget::increment();
    let handle = std::thread::Builder::new()
        .name("agent-stdout-reader".to_string())
        .spawn(move || {
            let _budget = ThreadBudgetGuard::already_counted();
            let mut stream = File::from(fd);
            let mut framer = LineFramer::default();
            let mut buf = [0u8; 64 * 1024];
            let mut seq: u64 = 0;
            loop {
                thread_stats.loop_iterations.fetch_add(1, Ordering::SeqCst);
                let n = match stream.read(&mut buf) {
                    Ok(0) => break, // EOF
                    Ok(n) => n,
                    Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                thread_stats
                    .bytes_read
                    .fetch_add(n as u64, Ordering::SeqCst);
                framer.feed(
                    &buf[..n],
                    |diagnostic| {
                        if matches!(diagnostic, FramerDiagnostic::Overflow { .. }) {
                            thread_stats.framer_overflows.fetch_add(1, Ordering::SeqCst);
                        }
                        queue.push(QueueEvent::Diagnostic("framer.overflow"));
                    },
                    |line| {
                        thread_stats.lines_read.fetch_add(1, Ordering::SeqCst);
                        queue.push(QueueEvent::Line { seq, bytes: line });
                        seq += 1;
                    },
                );
            }
            // Flush any carry that never terminated with a delimiter before EOF, mirroring
            // `LineFramer.flush` -- a line that never got a trailing `\n` before the process
            // exited is still a line, not silently dropped.
            framer.flush(|line| {
                thread_stats.lines_read.fetch_add(1, Ordering::SeqCst);
                queue.push(QueueEvent::Line { seq, bytes: line });
                seq += 1;
            });
        })
        .expect("spawning the stdout reader thread must succeed");
    (handle, stats)
}

/// Spawns the stderr reader thread: blocking `read()` -> [`StderrTail`] append (256 KiB cap, no
/// framing/decode -- stderr is a diagnostic tail, not a protocol stream). Returns when the pipe
/// reaches EOF.
pub type StderrChunkObserver = Arc<dyn Fn(&[u8]) + Send + Sync + 'static>;

pub fn spawn_stderr_reader(
    fd: OwnedFd,
    tail: Arc<std::sync::Mutex<StderrTail>>,
) -> (JoinHandle<()>, Arc<ReaderStats>) {
    spawn_stderr_reader_with_observer(fd, tail, None)
}

/// Variant used by the integrated scope to mirror the DEBUG `process.stderr` raw-event record
/// without inserting another byte queue or changing INV-P6-2. The observer runs inline after the
/// bounded tail append and must remain non-blocking; the raw logger performs one serialized file
/// append, matching the legacy Swift diagnostic path.
pub fn spawn_stderr_reader_with_observer(
    fd: OwnedFd,
    tail: Arc<std::sync::Mutex<StderrTail>>,
    observer: Option<StderrChunkObserver>,
) -> (JoinHandle<()>, Arc<ReaderStats>) {
    let stats = Arc::new(ReaderStats::default());
    let thread_stats = Arc::clone(&stats);
    thread_budget::increment();
    let handle = std::thread::Builder::new()
        .name("agent-stderr-reader".to_string())
        .spawn(move || {
            let _budget = ThreadBudgetGuard::already_counted();
            let mut stream = File::from(fd);
            let mut buf = [0u8; 64 * 1024];
            loop {
                thread_stats.loop_iterations.fetch_add(1, Ordering::SeqCst);
                let n = match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                thread_stats
                    .bytes_read
                    .fetch_add(n as u64, Ordering::SeqCst);
                tail.lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .append(&buf[..n]);
                if let Some(observer) = &observer {
                    observer(&buf[..n]);
                }
            }
        })
        .expect("spawning the stderr reader thread must succeed");
    (handle, stats)
}
