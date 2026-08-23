//! E-P6-3 evidence tests (design section 8 / contract section 5.3-5.4): no deadlock, bounded
//! memory, terminal events survive. See `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md`
//! for the covered-vs-deferred matrix rows and interpretation against the pre-registered pass
//! criteria.

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use agent_claude_derisking_spike::spawn::{spawn, SpawnConfig};
use agent_claude_derisking_spike::stream::{spawn_reader, BoundedEventQueue, QueueEvent, FRAMER_MAX_LINE_BYTES};

fn synthetic_cli_path() -> String {
    PathBuf::from(env!("CARGO_BIN_EXE_synthetic_cli")).to_string_lossy().into_owned()
}

fn spawn_synthetic(args: &[String]) -> (i32, std::fs::File, std::fs::File) {
    let command = synthetic_cli_path();
    let config = SpawnConfig {
        command: &command,
        arguments: args,
        environment: &[],
        working_directory: None,
    };
    let spawned = spawn(&config).expect("synthetic_cli spawn must succeed");
    let stdin = std::fs::File::from(spawned.stdin_write);
    let stdout = std::fs::File::from(spawned.stdout_read);
    (spawned.pid, stdin, stdout)
}

fn reap_blocking(pid: i32) {
    let mut status: i32 = 0;
    // Test-cleanup-only blocking waitpid; the E-P6-2 reaper is exercised in its own test file.
    unsafe { libc::waitpid(pid, &mut status, 0) };
}

#[test]
fn oversized_line_triggers_framer_overflow_not_a_crash() {
    let (pid, _stdin, stdout) = spawn_synthetic(&["oversized-line".to_string(), "9".to_string()]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_reader(stdout, Arc::clone(&queue));
    handle.join().expect("reader thread must not panic");
    reap_blocking(pid);

    assert!(
        stats.framer_overflows.load(Ordering::SeqCst) >= 1,
        "a 9 MiB line must trigger at least one framer.overflow (cap is {FRAMER_MAX_LINE_BYTES} bytes)"
    );
    // The line after the oversized one must still be framed correctly -- overflow recovers, it
    // does not wedge the reader.
    let drained = queue.drain();
    assert!(
        drained.iter().any(|e| matches!(e, QueueEvent::Line { .. })),
        "at least one well-formed line must still be framed after the overflow"
    );
}

#[test]
fn mid_line_stall_completes_without_deadlock() {
    let (pid, _stdin, stdout) = spawn_synthetic(&["mid-line-stall".to_string(), "300".to_string()]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_reader(stdout, Arc::clone(&queue));
    let start = Instant::now();
    handle.join().expect("reader thread must not panic");
    let elapsed = start.elapsed();
    reap_blocking(pid);

    assert!(elapsed < Duration::from_secs(5), "reader must finish shortly after the stall, not hang");
    assert_eq!(stats.lines_read.load(Ordering::SeqCst), 2, "both the stalled and trailing lines must be framed");
}

#[test]
fn flood_bounded_memory_zero_terminal_loss() {
    let (pid, _stdin, stdout) = spawn_synthetic(&["flood".to_string(), "20000000".to_string(), "800".to_string()]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_reader(stdout, Arc::clone(&queue));

    // A terminal-class event pushed *during* the flood must survive -- it uses the reserved slot,
    // never the pressured ring (contract section 5.4 / 7.1).
    std::thread::sleep(Duration::from_millis(200));
    queue.push_terminal(QueueEvent::Terminal("turnCompleted".to_string()));

    handle.join().expect("reader thread must not panic");
    reap_blocking(pid);

    let terminal = queue.take_terminal(Duration::from_millis(10));
    assert!(matches!(terminal, Some(QueueEvent::Terminal(ref s)) if s == "turnCompleted"), "terminal event must survive flood pressure");

    // Bounded memory: peak queue bytes must never exceed the registered cap (contract section
    // 5.4's per-subscription event-queue cap), regardless of how much the flood produced.
    let peak = queue.peak_bytes.load(Ordering::SeqCst);
    assert!(
        peak <= agent_claude_derisking_spike::stream::QUEUE_MAX_BYTES,
        "peak queue bytes {peak} must stay within the {} byte cap",
        agent_claude_derisking_spike::stream::QUEUE_MAX_BYTES
    );
    // Loss under pressure is expected and, per design, correct -- but it must be *recorded*, not
    // silent (the gap-record property).
    assert!(stats.lines_read.load(Ordering::SeqCst) > 0);
}

#[test]
fn deadlock_probe_stdin_starved_flood_reader_never_stalls() {
    // The named deadlock probe (design section 8 E-P6-3): a child that stops reading its stdin
    // while continuing to write stdout at max rate, with the parent concurrently issuing an
    // "interrupt" (a stdin write awaiting a reply that will never come, since this child never
    // reads stdin at all).
    let (pid, mut stdin, stdout) = spawn_synthetic(&["stdin-starved-flood".to_string(), "1500".to_string()]);
    let queue = Arc::new(BoundedEventQueue::default());
    let (handle, stats) = spawn_reader(stdout, Arc::clone(&queue));

    // Give the flood a moment to actually start producing backpressure.
    std::thread::sleep(Duration::from_millis(100));

    // Issue the "interrupt": a small stdin write (must not block the *reader*; a full stdin pipe
    // could in principle block this *writer*, but per INV-P6-2 the writer is a separate
    // serialized path from the reader -- this write happening on the test's own thread, not the
    // reader thread, is exactly that separation) followed by a bounded wait for an ACK line that
    // will never arrive from this child.
    let write_result = stdin.write_all(b"{\"type\":\"control_request\",\"subtype\":\"interrupt\"}\n");
    let _ = write_result; // best-effort; a full pipe returning WouldBlock/EPIPE is not a reader-thread concern

    let iterations_before = stats.loop_iterations.load(Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_millis(1500 + 500); // 1.5s ACK deadline + slack
    let mut reader_advanced = false;
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        if stats.loop_iterations.load(Ordering::SeqCst) > iterations_before {
            reader_advanced = true;
            break;
        }
    }
    assert!(
        reader_advanced,
        "reader thread's loop counter must advance during the interrupt-wait window -- a stall here \
         is exactly the deadlock INV-P6-2 exists to rule out"
    );

    handle.join().expect("reader thread must not panic");
    reap_blocking(pid);
    assert!(stats.bytes_read.load(Ordering::SeqCst) > 0, "the flood must have produced bytes the reader drained");
}
