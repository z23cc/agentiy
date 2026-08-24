//! P6-4 (design §4.2/§4.4, contract §5.2, E-P6-2 Part B/R2b): the `2N + 1` thread-budget pass
//! criterion, measured with a **fully real stack** -- real `spawn`, real `stdout`/`stderr` reader
//! threads, real `reaper` -- at N = 1, 4, 16, exactly the design's registered range. Isolated in
//! its own binary and asserted `AGENT_DOMAIN_THREAD_COUNT` before/after each N, which is why this
//! lives in its own process rather than the shared `--lib` unit-test binary (see
//! `agent_claude::process::reaper`'s own unit tests, which explicitly decline this assertion for
//! exactly that reason).

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use agentry_runtime::agent_claude::process::queue::BoundedEventQueue;
use agentry_runtime::agent_claude::process::reader::{spawn_stderr_reader, spawn_stdout_reader};
use agentry_runtime::agent_claude::process::reaper::Reaper;
use agentry_runtime::agent_claude::process::spawn::{SpawnConfig, spawn};
use agentry_runtime::agent_claude::process::stderr_tail::StderrTail;
use agentry_runtime::agent_claude::process::thread_budget::AGENT_DOMAIN_THREAD_COUNT;

fn spawn_sh(script: &str) -> agentry_runtime::agent_claude::process::spawn::SpawnedProcess {
    spawn(&SpawnConfig {
        command: "/bin/sh",
        arguments: &["-c".to_string(), script.to_string()],
        environment: &[],
        working_directory: None,
    })
    .expect("spawn must succeed")
}

fn run_n_real_sessions(n: usize) {
    let before = AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
    let reaper = Reaper::new();
    assert_eq!(
        AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst),
        before + 1,
        "starting a reaper must contribute exactly one thread"
    );

    let mut stdout_handles = Vec::new();
    let mut stderr_handles = Vec::new();
    let mut children = Vec::new();
    for _ in 0..n {
        // A short sleep before writing keeps every session's reader threads alive long enough
        // for the whole batch to finish spawning before any of them reach EOF -- without it, a
        // near-instant child can exit (and its readers hit EOF) before the loop below has even
        // finished creating the remaining sessions, making the "during" assertion racy rather
        // than a real measurement of N concurrent sessions.
        let child = spawn_sh("sleep 0.3; echo out-line; echo err-line 1>&2; exit 0");
        let token = reaper.register(child.pid).expect("register");
        let queue = Arc::new(BoundedEventQueue::default());
        let tail = Arc::new(std::sync::Mutex::new(StderrTail::default()));
        let (stdout_handle, _) = spawn_stdout_reader(child.stdout_read, queue);
        let (stderr_handle, _) = spawn_stderr_reader(child.stderr_read, tail);
        stdout_handles.push(stdout_handle);
        stderr_handles.push(stderr_handle);
        children.push((child.pid, token));
    }

    // Two reader threads per session must be live concurrently with the reaper -- assert the
    // full `2N + 1` budget while sessions are still in flight, not just at quiesce.
    let during = AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
    assert_eq!(
        during,
        before + 1 + 2 * n,
        "expected exactly 2N + 1 threads (N={n}) while sessions are live"
    );

    for h in stdout_handles {
        h.join().expect("stdout reader must not panic");
    }
    for h in stderr_handles {
        h.join().expect("stderr reader must not panic");
    }
    for (pid, token) in children {
        let outcome = reaper
            .wait_for_exit(pid, token, Duration::from_secs(5))
            .unwrap_or_else(|| panic!("pid {pid} must be reaped"));
        assert!(matches!(
            outcome,
            agentry_runtime::agent_claude::process::reaper::ReapOutcome::Exited(0)
        ));
        reaper.forget(pid, token);
    }

    assert_eq!(reaper.registered_count(), 0);
    assert_eq!(reaper.echild_count(), 0);
    reaper.shutdown();

    let after = AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
    assert_eq!(
        after, before,
        "thread count must return to exactly the pre-N baseline -- zero leak at N={n}"
    );
}

// A single test function, not two: `AGENT_DOMAIN_THREAD_COUNT` is a process-global counter, and
// Rust's default test harness runs `#[test]` functions concurrently within one binary -- two
// separate tests asserting before/after deltas against it would race each other exactly the way
// `agent_claude::process::reaper`'s own unit tests explicitly decline to (see that module's doc).
// This binary exists so the assertion can own the whole process; keeping everything in one test
// function is what actually delivers that, regardless of harness concurrency defaults.
#[test]
fn thread_budget_and_thousand_session_soak_with_a_real_stack() {
    // `2N + 1` is asserted implicitly: the reaper's own contribution is always exactly 1
    // (asserted per-N inside `run_n_real_sessions`), and each of N sessions holds two real reader
    // threads for its lifetime -- the return-to-baseline assertion after each N demonstrates zero
    // leak at each registered N, matching E-P6-2 Part B's pass criterion.
    for n in [1usize, 4, 16] {
        run_n_real_sessions(n);
    }

    // The P6-4 done-when's "1,000-session leak soak shows zero FD/thread growth" -- run in
    // batches of 20 concurrent real sessions (spawn + two reader threads + reaper registration)
    // fifty times (1,000 sessions total), asserting the thread-domain counter returns to its
    // pre-soak baseline every batch, never accumulating.
    let before = AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst);
    for batch in 0..50 {
        run_n_real_sessions(20);
        assert_eq!(
            AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst),
            before,
            "batch {batch}: thread count must return to the pre-soak baseline, not accumulate"
        );
    }
    assert_eq!(AGENT_DOMAIN_THREAD_COUNT.load(Ordering::SeqCst), before);
}
