//! P6-4 (design R2, contract §5.2): "true coexistence testing" Arm B -- the load-bearing R2
//! measurement, replacing the P6-2 spike's purely structural argument ("no `waitpid(-1)`, no
//! SIGCHLD handler, grep confirms it") with an actual adversarial foreign owner running
//! concurrently in the same process. Two independent instances of our own PID-targeted `Reaper`
//! cannot steal from each other by construction (Arm A, `agent_claude_process_coexistence.rs`,
//! is a cheap regression net for that, not this measurement) -- R2's real danger is an owner that
//! is *not* PID-targeted: `waitpid(-1)`/`wait()` in a loop, or a SIGCHLD handler doing the same.
//! This file is that hostile owner, isolated in its own process (its own binary target) because
//! `waitpid(-1)` reaps *any* of this process's children process-wide and would otherwise
//! contaminate every other concurrently-running test in a shared test binary.
//!
//! **What this proves, precisely.** Our reaper is PID-targeted and races a genuinely
//! non-PID-targeted thief for the same children. The pass bar is not "our reaper always wins the
//! race" (that is not a guaranteed property against a hostile, unbounded-scope competitor, and
//! claiming it would be dishonest) -- it is: **every registered PID resolves to a definite,
//! correctly-typed outcome within a bounded time, never an infinite hang, and a status the thief
//! wins is surfaced as `ReapOutcome::Lost` (`ChildOwnershipLost`, contract §5.2), never silently
//! misattributed to the wrong PID.**
//!
//! Also asserts the design's R2 mechanism verbatim (contract §5.2): `sigaction(SIGCHLD, NULL,
//! &old)` reports the default disposition -- nothing in this process, including this file's own
//! hostile thread, installs a SIGCHLD handler. An earlier results doc recorded this as inspected
//! ("reaper.rs installs no SIGCHLD handler anywhere") rather than measured, the same
//! structural-argument substitution prerequisite 2 exists to eliminate; this binary is its own
//! crate root, so its `#![allow(unsafe_code)]` below is outside `Scripts/rust_ffi_guardrails.py`'s
//! `src/`-only two-site count.
#![allow(unsafe_code)]

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
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
fn survives_a_waitpid_minus_one_hostile_foreign_owner() {
    let reaper = Reaper::new();
    let stop = Arc::new(AtomicBool::new(false));
    let hostile_reaps = Arc::new(AtomicUsize::new(0));

    // The hostile foreign owner: loops `waitpid(-1, WNOHANG)` -- process-wide, not PID-targeted --
    // exactly the R2 shape ("a second reaper... steals statuses from Swift's sole owners"), just
    // implemented as the worst case this crate can construct without a second language runtime.
    let hostile_stop = Arc::clone(&stop);
    let hostile_reaps_counter = Arc::clone(&hostile_reaps);
    let hostile = std::thread::spawn(move || {
        while !hostile_stop.load(Ordering::SeqCst) {
            match nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(-1), Some(nix::sys::wait::WaitPidFlag::WNOHANG)) {
                Ok(nix::sys::wait::WaitStatus::Exited(_, _) | nix::sys::wait::WaitStatus::Signaled(_, _, _)) => {
                    hostile_reaps_counter.fetch_add(1, Ordering::SeqCst);
                }
                _ => std::thread::sleep(Duration::from_micros(200)),
            }
        }
    });

    let mut handles = Vec::new();
    for i in 0..150 {
        let reaper = Arc::clone(&reaper);
        handles.push(std::thread::spawn(move || {
            let child = spawn_sh("exit 0");
            let token = reaper.register(child.pid).expect("register");
            let outcome = reaper.wait_for_exit(child.pid, token, Duration::from_secs(5));
            (i, child.pid, token, outcome)
        }));
    }

    let mut lost = 0usize;
    let mut won = 0usize;
    for h in handles {
        let (i, pid, token, outcome) = h.join().expect("cycle thread must not panic");
        let outcome = outcome.unwrap_or_else(|| panic!("cycle {i} pid {pid}: reaper hung -- wait_for_exit timed out instead of resolving, even to Lost"));
        match outcome {
            ReapOutcome::Exited(0) => won += 1,
            ReapOutcome::Lost => lost += 1,
            other => panic!("cycle {i} pid {pid}: unexpected outcome {other:?} -- possible cross-attribution"),
        }
        reaper.forget(pid, token);
    }

    stop.store(true, Ordering::SeqCst);
    hostile.join().expect("hostile thread must not panic");

    // The property under test: no hang, no misattribution, every loss typed and counted.
    assert_eq!(won + lost, 150);
    assert_eq!(reaper.echild_count(), lost, "every hostile-won race must be counted, not silently dropped");
    eprintln!(
        "hostile-coexistence: {won} won by our reaper, {lost} stolen by the hostile waitpid(-1) \
         thief and correctly surfaced as Lost, {} total hostile reaps observed",
        hostile_reaps.load(Ordering::SeqCst)
    );

    reaper.shutdown();
}

#[test]
fn no_sigchld_handler_is_installed_by_this_process() {
    // Direct measurement, not inspection -- and, since libtest sorts by name and this file's other
    // test ('s') sorts after this one ('n'), this test cannot rely on that other test's `Reaper`
    // having already run (a filtered `cargo test -- no_sigchld` run proves it does not). Construct
    // and fully exercise a real `Reaper` -- spawn, register, wait for exit, forget, shutdown --
    // *inside this test*, so the query below covers our own reaper's machinery, not merely
    // whatever the Rust std runtime installs before any `Reaper` exists.
    let reaper = Reaper::new();
    let child = spawn_sh("exit 0");
    let token = reaper.register(child.pid).expect("register");
    let outcome = reaper
        .wait_for_exit(child.pid, token, Duration::from_secs(5))
        .expect("child must be reaped within 5s");
    assert_eq!(outcome, ReapOutcome::Exited(0));
    reaper.forget(child.pid, token);
    reaper.shutdown();

    // Query (never install -- `NULL` as the `act` argument is query-only) the process's current
    // SIGCHLD disposition and assert it is still the default.
    let mut current: libc::sigaction = unsafe { std::mem::zeroed() };
    // SAFETY: `NULL` as the second argument makes this call query-only (POSIX `sigaction(2)`); it
    // installs nothing. `current` is a valid, owned, zero-initialized `sigaction` for the kernel to
    // write the existing disposition into.
    let rc = unsafe { libc::sigaction(libc::SIGCHLD, std::ptr::null(), &mut current) };
    assert_eq!(rc, 0, "sigaction query must succeed");
    assert_eq!(
        current.sa_sigaction,
        libc::SIG_DFL,
        "no SIGCHLD handler must be installed anywhere in this process, including by our own \
         Reaper machinery just exercised above (default disposition expected)"
    );
}
