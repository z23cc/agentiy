//! P6-4 (design §3.4/§8 E-P6-3, contract §5.3/§5.4): the reader/framer adversarial matrix, driven
//! against the real `agent_claude::process::reader` module and the real byte-exact
//! `agent_claude::framer::LineFramer` -- not the P6-2 spike's scoped-down raw-`\n`-split harness.
//! Uses `agent-claude-synthetic-cli` (see `tests/support/synthetic_cli.rs`) as a portable,
//! dependency-free stand-in for `claude`, matching design §3.4's named synthetic-CLI matrix
//! (well-behaved, hostile, silent, huge-line, crash-on-signal) plus E-P6-3's flood/mid-line-stall/
//! stdin-starved-flood rows.

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use agentry_runtime::agent_claude::process::queue::{BoundedEventQueue, QueueEvent};
use agentry_runtime::agent_claude::process::reader::spawn_stdout_reader;
use agentry_runtime::agent_claude::process::spawn::{SpawnConfig, spawn};

fn synthetic_cli() -> &'static str {
    env!("CARGO_BIN_EXE_agent-claude-synthetic-cli")
}

fn spawn_synthetic(args: &[&str]) -> agentry_runtime::agent_claude::process::spawn::SpawnedProcess {
    let arguments: Vec<String> = args.iter().map(ToString::to_string).collect();
    spawn(&SpawnConfig {
        command: synthetic_cli(),
        arguments: &arguments,
        environment: &[],
        working_directory: None,
    })
    .expect("spawn synthetic-cli")
}

#[test]
fn well_behaved_single_line_is_framed_and_queued() {
    let child = spawn_synthetic(&["well-behaved"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    handle.join().expect("reader thread must not panic");
    let lines: Vec<_> = queue
        .drain()
        .into_iter()
        .filter_map(|e| match e {
            QueueEvent::Line { bytes, .. } => Some(bytes),
            _ => None,
        })
        .collect();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0], br#"{"type":"result","subtype":"success"}"#);
    assert_eq!(stats.lines_read.load(std::sync::atomic::Ordering::SeqCst), 1);
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn huge_line_triggers_framer_overflow_and_reader_does_not_hang() {
    let child = spawn_synthetic(&["huge-line", "9437184"]); // 9 MiB, over the 8 MiB cap
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    handle.join().expect("reader thread must not panic or hang");
    // Asserted at the reader-stats level, not via queue presence: the eventual truncated-tail
    // line this overflow produces is itself large enough to exceed the queue's byte cap on its
    // own, and the bounded queue's own admit-anyway-and-evict-everything policy for an oversized
    // single item (contract §5.4) can legitimately evict the earlier diagnostic entry -- that is
    // correct pressure-relief behavior, not something this test should fight.
    assert!(stats.framer_overflows.load(std::sync::atomic::Ordering::SeqCst) >= 1);
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn mid_line_stall_completes_without_deadlock() {
    let child = spawn_synthetic(&["mid-line-stall", "300"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    handle.join().expect("reader thread must complete once the stall resolves");
    assert_eq!(stats.lines_read.load(std::sync::atomic::Ordering::SeqCst), 1);
    let lines: Vec<_> = queue
        .drain()
        .into_iter()
        .filter_map(|e| match e {
            QueueEvent::Line { bytes, .. } => Some(bytes),
            _ => None,
        })
        .collect();
    assert_eq!(lines.len(), 1);
    assert_eq!(std::str::from_utf8(&lines[0]).unwrap(), r#"{"type":"stream_event","seq":0}"#);
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn silent_then_well_behaved_reader_does_not_falsely_terminate() {
    let child = spawn_synthetic(&["silent", "1"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, _stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    handle.join().expect("reader must wait out the silence and still frame the eventual line");
    let lines: Vec<_> = queue
        .drain()
        .into_iter()
        .filter_map(|e| match e {
            QueueEvent::Line { bytes, .. } => Some(bytes),
            _ => None,
        })
        .collect();
    assert_eq!(lines.len(), 1);
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn flood_bounded_memory_and_zero_terminal_loss() {
    let child = spawn_synthetic(&["flood", "400"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    // Push a terminal event mid-flood from this thread; the reserved slot must survive ring
    // eviction regardless of how much flood volume follows.
    std::thread::sleep(Duration::from_millis(100));
    queue.push_terminal(QueueEvent::Terminal("turnCompleted".to_string()));
    handle.join().expect("reader must drain the whole flood without blocking");
    assert!(stats.lines_read.load(std::sync::atomic::Ordering::SeqCst) > 0);
    let terminal = queue.take_terminal(Duration::from_millis(10));
    assert!(matches!(terminal, Some(QueueEvent::Terminal(s)) if s == "turnCompleted"));
    assert!(
        queue.peak_bytes.load(std::sync::atomic::Ordering::SeqCst) <= 1_048_576,
        "peak queue bytes must never exceed the registered 1 MiB cap"
    );
    // Regression net for `queue.rs`'s eviction-coalescing fix (see that module's `push` doc): an
    // earlier draft degraded the entire ring into individual `Gap` records under this exact
    // sustained-flood, count-cap-bound shape. The drained ring after a real flood must still
    // retain actual `Line` content, not just gap markers.
    let drained = queue.drain();
    let retained_lines = drained
        .iter()
        .filter(|event| matches!(event, QueueEvent::Line { .. }))
        .count();
    assert!(
        retained_lines > 0,
        "sustained flood pressure must not evict every retained Line from the ring: {drained:?}"
    );
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn deadlock_probe_stdin_starved_flood_reader_never_stalls() {
    // The named deadlock probe (design §8 E-P6-3): a child that floods stdout and never reads
    // stdin, with the parent concurrently attempting a stdin write that will block once the pipe
    // buffer fills. INV-P6-2's claim is that the *stdout reader* thread is never affected by that
    // stall -- proven here by observing its heartbeat counter keep advancing throughout.
    let child = spawn_synthetic(&["stdin-starved-flood", "1200"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));

    let mut stdin = std::fs::File::from(child.stdin_write);
    let writer = std::thread::spawn(move || {
        // This write will block once the pipe buffer fills, since the child never reads stdin.
        // Its outcome is irrelevant to the assertion below -- only that it does not affect the
        // stdout reader thread, running independently.
        let payload = vec![b'x'; 8 * 1024 * 1024];
        let _ = stdin.write_all(&payload);
    });

    let first = stats.loop_iterations.load(std::sync::atomic::Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(400));
    let second = stats.loop_iterations.load(std::sync::atomic::Ordering::SeqCst);
    assert!(second > first, "reader thread's loop-iteration heartbeat must advance while the stdin writer is stalled");

    handle.join().expect("reader must drain to EOF once the child exits");
    let _ = writer.join();
    let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
}

#[test]
fn crash_on_signal_reader_reaches_clean_eof() {
    let child = spawn_synthetic(&["crash-on-signal"]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, _stats) = spawn_stdout_reader(child.stdout_read, Arc::clone(&queue));
    handle.join().expect("reader must reach EOF cleanly when the child dies by signal, not hang");
    let lines: Vec<_> = queue
        .drain()
        .into_iter()
        .filter_map(|e| match e {
            QueueEvent::Line { bytes, .. } => Some(bytes),
            _ => None,
        })
        .collect();
    assert_eq!(lines, vec![b"ready".to_vec()]);

    let reaper = agentry_runtime::agent_claude::process::reaper::Reaper::new();
    let token = reaper.register(child.pid).expect("register");
    let outcome = reaper
        .wait_for_exit(child.pid, token, Duration::from_secs(3))
        .expect("crashed child must still be reaped");
    assert!(
        matches!(outcome, agentry_runtime::agent_claude::process::reaper::ReapOutcome::Signaled(sig) if sig == nix::libc::SIGABRT),
        "expected Signaled(SIGABRT), got {outcome:?}"
    );
    reaper.forget(child.pid, token);
    reaper.shutdown();
}
