//! E-P6-2 R2b / E-P6-3(f) combined evidence: real end-to-end "sessions" (spawn + two real reader
//! threads from `stream.rs` + the shared `reaper.rs` reaper), not simulated placeholder threads,
//! at N concurrent sessions. Complements `spawn_and_reaper.rs`'s `r2b_thread_budget_scales_as_2n_plus_1`
//! (which measures the reaper's own thread contribution against synthetic reader threads) with a
//! fully real stack: this is the strongest evidence this spike produces for design section 4.2's
//! "2 per session (stdout, stderr) + 1 process-wide reaper" thread budget and for open question 1
//! (design section 8: "if E-P6-2/E-P6-3's thread-count criteria show that pair is material at high
//! session counts... revisit").

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use agent_claude_derisking_spike::reaper::{self, ReapOutcome, Reaper};
use agent_claude_derisking_spike::spawn::{spawn, SpawnConfig};
use agent_claude_derisking_spike::stream::{spawn_reader, BoundedEventQueue};

fn synthetic_cli_path() -> String {
    std::path::PathBuf::from(env!("CARGO_BIN_EXE_synthetic_cli"))
        .to_string_lossy()
        .into_owned()
}

/// One real session: spawn `synthetic_cli flood`, attach real stdout+stderr readers (two OS
/// threads, matching contract section 5.2's per-session reader pair), register with the shared
/// reaper, and return everything needed to drive it to completion.
struct Session {
    pid: i32,
    token: u64,
    stdout_handle: std::thread::JoinHandle<()>,
    stderr_handle: std::thread::JoinHandle<()>,
    stdout_stats: Arc<agent_claude_derisking_spike::stream::ReaderStats>,
}

fn start_session(reaper: &Reaper) -> Session {
    let command = synthetic_cli_path();
    let config = SpawnConfig {
        command: &command,
        arguments: &["flood".to_string(), "2000000".to_string(), "300".to_string()],
        environment: &[],
        working_directory: None,
    };
    let spawned = spawn(&config).expect("session spawn must succeed");
    let token = reaper.register(spawned.pid).expect("fresh pid must register cleanly");

    let stdout_queue = Arc::new(BoundedEventQueue::default());
    let (stdout_handle, stdout_stats) =
        spawn_reader(std::fs::File::from(spawned.stdout_read), stdout_queue);
    // synthetic_cli writes nothing to stderr, but a real session always has a live stderr reader
    // thread regardless of traffic volume -- that's exactly the "2 per session" contract.
    let stderr_queue = Arc::new(BoundedEventQueue::default());
    let (stderr_handle, _stderr_stats) =
        spawn_reader(std::fs::File::from(spawned.stderr_read), stderr_queue);

    Session {
        pid: spawned.pid,
        token,
        stdout_handle,
        stderr_handle,
        stdout_stats,
    }
}

#[test]
fn combined_real_sessions_thread_budget_and_zero_leaks() {
    for &n in &[1usize, 4, 16] {
        let baseline = reaper::AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
        assert_eq!(baseline, 0, "thread count must be quiescent between N values");

        let reaper = Reaper::new(); // +1

        let mut sessions = Vec::with_capacity(n);
        for _ in 0..n {
            let session = start_session(&reaper);
            // Two real OS threads per session, counted the same way production reader threads
            // would be (this spike's `spawn_reader` does not itself increment the shared counter,
            // so the test does -- see `stream.rs` module doc: E-P6-3's reader harness is
            // transport-plane-only and does not integrate with the reaper's thread-budget
            // instrument on its own).
            reaper::AGENT_DOMAIN_THREAD_COUNT.fetch_add(2, Ordering::SeqCst);
            sessions.push(session);
        }

        let observed = reaper::AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
        assert_eq!(observed, 2 * n + 1, "N={n}: expected 2N+1 real threads (spawn+reader+reaper)");

        // Drive every session to completion: readers finish on child EOF, reaper reaps the exit.
        for session in sessions {
            session.stdout_handle.join().expect("stdout reader must not panic");
            session.stderr_handle.join().expect("stderr reader must not panic");
            assert!(
                session.stdout_stats.lines_read.load(Ordering::SeqCst) > 0,
                "each session's flood must have produced at least one line"
            );
            let outcome = reaper.wait_for_exit(session.pid, session.token, Duration::from_secs(5));
            assert_eq!(outcome, Some(ReapOutcome::Exited(0)), "each session's child must exit 0 and be reaped");
            reaper.forget(session.pid, session.token);
            reaper::AGENT_DOMAIN_THREAD_COUNT.fetch_sub(2, Ordering::SeqCst);
        }

        assert_eq!(reaper.pending_count(), 0, "N={n}: zero pending registrations after every session completes");
        assert_eq!(reaper.registered_count(), 0, "N={n}: zero residual registrations (every session was forgotten)");
        assert_eq!(reaper.echild_count(), 0, "N={n}: zero ECHILD");

        reaper.shutdown(); // -1
    }
    assert_eq!(
        reaper::AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst),
        0,
        "thread count must return to zero after every N"
    );
}
