//! P6-4 (design R2/E-P6-2 Part B, contract §5.2): "true coexistence testing" Arm A -- two
//! independent `Reaper` instances (each its own kqueue fd, its own thread, its own PID→entry map)
//! running concurrently in one process, soaked with randomized spawn/reap cycles distributed
//! across both. This is a cheap regression net for accidental process-global state leaking
//! between reaper instances (e.g. a shared kqueue fd, a shared token counter) -- it is **not**,
//! by itself, a measurement of R2 ("a second reaper or SIGCHLD handler steals statuses from
//! Swift's sole owners"), because two instances of the *same* PID-targeted code cannot steal from
//! each other by construction: every reap is `waitpid(<specific pid>)`, never `waitpid(-1)`, so
//! there is no shared resource for two well-behaved instances to race over. The load-bearing R2
//! measurement -- an adversarial foreign owner that is *not* PID-targeted -- is Arm B,
//! `agent_claude_process_coexistence_hostile.rs`, isolated in its own process because it must
//! install process-global signal disposition.

use std::sync::Arc;
use std::time::Duration;

use agentry_runtime::agent_claude::process::reaper::{ReapOutcome, Reaper};
use agentry_runtime::agent_claude::process::spawn::{SpawnConfig, spawn};

fn spawn_sh(script: &str) -> agentry_runtime::agent_claude::process::spawn::SpawnedProcess {
    spawn(&SpawnConfig {
        command: "/bin/sh",
        arguments: &["-c".to_string(), script.to_string()],
        environment: &[],
        working_directory: None,
    })
    .expect("spawn must succeed")
}

#[test]
fn two_independent_reaper_instances_never_cross_attribute_pids() {
    let reaper_a = Reaper::new();
    let reaper_b = Reaper::new();

    // 300 cycles distributed alternately across both reapers -- each cycle's exit code encodes
    // which reaper spawned it, so any cross-attribution (reaper A observing reaper B's PID's
    // outcome or vice versa) would surface as a code mismatch, not just a missing entry.
    let mut handles = Vec::new();
    for i in 0..300 {
        let (reaper, code) = if i % 2 == 0 { (Arc::clone(&reaper_a), 10) } else { (Arc::clone(&reaper_b), 20) };
        handles.push(std::thread::spawn(move || {
            let child = spawn_sh(&format!("exit {code}"));
            let token = reaper.register(child.pid).expect("register");
            let outcome = reaper
                .wait_for_exit(child.pid, token, Duration::from_secs(5))
                .expect("must be reaped within 5s");
            assert_eq!(outcome, ReapOutcome::Exited(code));
            reaper.forget(child.pid, token);
        }));
    }
    for h in handles {
        h.join().expect("cycle thread must not panic");
    }

    assert_eq!(reaper_a.echild_count(), 0);
    assert_eq!(reaper_b.echild_count(), 0);
    assert_eq!(reaper_a.registered_count(), 0);
    assert_eq!(reaper_b.registered_count(), 0);

    reaper_a.shutdown();
    reaper_b.shutdown();
}
