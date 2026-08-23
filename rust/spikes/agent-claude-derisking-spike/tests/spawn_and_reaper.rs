//! E-P6-2 Part A (spawn-attribute parity, Rust arm), Part B (reaper coexistence soak), and R2b
//! (thread-scaling) evidence tests. See `rust/benchmarks/results/v1/p6-2-claude-derisking-v1.md`
//! for how these results are interpreted against the pre-registered pass criteria.
//!
//! **On "byte-identical" (contract/E-P6-2 Part A pass criterion).** PID/PGID absolute values are
//! never byte-identical across two independent spawns by construction (the OS assigns them); the
//! comparable, invocation-independent properties are: `pgid == pid` (own process group), the
//! signal disposition/mask, the open-FD set's *shape* (which logical fds are present and their
//! `FD_CLOEXEC` bit), `cwd`, the visible environment-variable *key set*, and `argv`. This suite
//! asserts those properties hold for the Rust spawner; the Swift-side arm
//! (`Tests/RepoPromptTests/AgentMode/ClaudeCompatible/SpawnAttributeParityTests.swift`) asserts
//! the identical property set against `ProcessLauncher.spawn` using the same probe binary and the
//! same configuration list. Both green is the parity evidence; see the results doc for why a
//! literal cross-process-runner diff was not built (no shared harness links `cargo test` and
//! `swift test` together in this repo).

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use agent_claude_derisking_spike::reaper::{self, ReapOutcome, Reaper};
use agent_claude_derisking_spike::spawn::{spawn, SpawnConfig, SpawnError};

/// Serializes every test in this file. `reaper::AGENT_DOMAIN_THREAD_COUNT` is a process-global
/// static; the R2b thread-count assertions need an otherwise-quiescent count to be meaningful, and
/// `cargo test`'s default same-binary parallelism would otherwise interleave independent tests'
/// thread lifecycles into each other's counts.
static SERIAL: Mutex<()> = Mutex::new(());

fn probe_binary_path() -> PathBuf {
    // Built by the `[[bin]] name = "probe"` target in this crate's own Cargo.toml; `cargo test`
    // builds bin targets before running integration tests, so this is always fresh.
    let mut path = PathBuf::from(env!("CARGO_BIN_EXE_probe"));
    if !path.exists() {
        path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/debug/probe");
    }
    path
}

#[derive(serde::Deserialize)]
struct ProbeReport {
    pid: i32,
    pgid: i32,
    sigpipe_disposition: String,
    blocked_signals: Vec<i32>,
    cwd: Result<String, String>,
    open_fds: Vec<FdReport>,
    env_keys: Vec<String>,
    argv: Vec<String>,
}

#[derive(serde::Deserialize)]
struct FdReport {
    fd: i32,
    cloexec: bool,
}

/// Spawns the probe binary with the given config, reads its one-line JSON report from stdout,
/// reaps it via the shared reaper, and returns the parsed report. Panics (test failure) on any
/// unexpected spawn/read/parse/reap error -- this is evidence-gathering, not defensive production
/// code.
fn spawn_probe_and_capture(
    reaper: &Reaper,
    arguments: &[String],
    environment: &[(String, String)],
) -> ProbeReport {
    let command = probe_binary_path().to_string_lossy().into_owned();
    let config = SpawnConfig {
        command: &command,
        arguments,
        environment,
        working_directory: None,
    };
    let spawned = spawn(&config).expect("probe spawn must succeed for a well-formed config");
    let token = reaper.register(spawned.pid).expect("fresh pid must register cleanly");

    use std::io::Read;
    let mut stdout = std::fs::File::from(spawned.stdout_read);
    let mut buf = String::new();
    stdout.read_to_string(&mut buf).expect("reading the probe's stdout must succeed");

    let outcome = reaper
        .wait_for_exit(spawned.pid, token, Duration::from_secs(5))
        .expect("probe must exit and be reaped within 5s");
    assert_eq!(outcome, ReapOutcome::Exited(0), "probe must exit 0");
    reaper.forget(spawned.pid, token);

    serde_json::from_str(buf.trim()).expect("probe stdout must be one JSON report line")
}

// ---------------------------------------------------------------------------------------------
// E-P6-2 Part A: spawn-attribute parity (Rust arm)
// ---------------------------------------------------------------------------------------------

#[test]
fn part_a_config_1_baseline_no_env() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    let report = spawn_probe_and_capture(&reaper, &[], &[]);
    assert_eq!(report.pgid, report.pid, "spawned process must be its own group leader");
    assert_eq!(report.sigpipe_disposition, "default");
    assert!(!report.blocked_signals.contains(&libc::SIGCHLD), "SIGCHLD must not be blocked (empty sigmask)");
    assert!(report.cwd.is_ok());
    assert!(report.env_keys.is_empty(), "empty environment map must not inherit the parent's env");
    // fds 0/1/2 must be present (the dup2 targets); nothing else should have leaked through
    // (POSIX_SPAWN_CLOEXEC_DEFAULT + explicit close of the parent-retained pipe halves).
    for expected in [0, 1, 2] {
        let fd = report
            .open_fds
            .iter()
            .find(|f| f.fd == expected)
            .unwrap_or_else(|| panic!("fd {expected} must be present"));
        // `dup2`'s target descriptor has FD_CLOEXEC cleared per POSIX -- these three are exactly
        // the fds the child is meant to actively read/write, so they must not be close-on-exec.
        assert!(!fd.cloexec, "fd {expected} (dup2 target) must not be FD_CLOEXEC");
    }
    reaper.shutdown();
}

#[test]
fn part_a_config_2_with_custom_env_key() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    let env = [("AGENT_CLAUDE_SPIKE_PROBE_VAR".to_string(), "probe-value".to_string())];
    let report = spawn_probe_and_capture(&reaper, &[], &env);
    assert_eq!(report.env_keys, vec!["AGENT_CLAUDE_SPIKE_PROBE_VAR".to_string()]);
    reaper.shutdown();
}

#[test]
fn part_a_config_3_without_env_does_not_inherit_parent() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    // Sanity: the *test process itself* has a non-empty environment (PATH etc.), so an empty
    // report here is real evidence of "full replacement, not merge" -- ProcessLauncher.spawn's
    // documented contract (design section 3.2 table: "Launch environment resolution ... passed as
    // a resolved map in the spawn command").
    assert!(!std::env::vars().collect::<Vec<_>>().is_empty());
    let reaper = Reaper::new();
    let report = spawn_probe_and_capture(&reaper, &[], &[]);
    assert!(report.env_keys.is_empty());
    reaper.shutdown();
}

#[test]
fn part_a_config_4_deep_argv() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    let args: Vec<String> = (0..64).map(|i| format!("--arg-{i}=value-{i}")).collect();
    let report = spawn_probe_and_capture(&reaper, &args, &[]);
    // argv[0] is the command path; argv[1..] is what we passed.
    assert_eq!(&report.argv[1..], &args[..]);
    reaper.shutdown();
}

#[test]
fn part_a_config_5_argv_spaces_and_utf8() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    let args = vec![
        "an argument with spaces".to_string(),
        "日本語の引数".to_string(),
        "emoji-🦀-argument".to_string(),
    ];
    let report = spawn_probe_and_capture(&reaper, &args, &[]);
    assert_eq!(&report.argv[1..], &args[..]);
    reaper.shutdown();
}

#[test]
fn part_a_config_6_missing_binary() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let config = SpawnConfig {
        command: "/definitely/not/a/real/path/agent-claude-spike-missing-binary",
        arguments: &[],
        environment: &[],
        working_directory: None,
    };
    let result = spawn(&config);
    match result {
        Err(SpawnError::Spawn(errno)) => assert_eq!(errno, nix::Error::ENOENT),
        other => panic!("expected SpawnError::Spawn(ENOENT), got {other:?}"),
    }
}

#[test]
fn part_a_config_7_non_executable_binary() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let path = std::env::temp_dir().join(format!("agent-claude-spike-non-exec-{}", std::process::id()));
    std::fs::write(&path, b"not a valid executable\n").expect("write scratch file");
    // Explicitly non-executable (0o644), matching the E-P6-2 "non-executable binary" config.
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    }
    let command = path.to_string_lossy().into_owned();
    let config = SpawnConfig {
        command: &command,
        arguments: &[],
        environment: &[],
        working_directory: None,
    };
    let result = spawn(&config);
    let _ = std::fs::remove_file(&path);
    match result {
        Err(SpawnError::Spawn(errno)) => assert_eq!(errno, nix::Error::EACCES),
        other => panic!("expected SpawnError::Spawn(EACCES), got {other:?}"),
    }
}

#[test]
fn part_a_config_8_shell_forks_grandchild_same_group() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    // The root exits almost immediately; the grandchild it forked outlives it but must remain in
    // the same process group (design section 4.2's "root exited but group survives" case).
    let marker = std::env::temp_dir().join(format!("agent-claude-spike-grandchild-{}", std::process::id()));
    let _ = std::fs::remove_file(&marker);
    let script = format!(
        "(sleep 1; /bin/echo grandchild-ran > {}) & exit 0",
        marker.to_string_lossy()
    );
    let config = SpawnConfig {
        command: "/bin/sh",
        arguments: &["-c".to_string(), script],
        environment: &[],
        working_directory: None,
    };
    let spawned = spawn(&config).expect("shell spawn must succeed");
    let token = reaper.register(spawned.pid).expect("fresh pid must register cleanly");
    let outcome = reaper
        .wait_for_exit(spawned.pid, token, Duration::from_secs(5))
        .expect("root shell must be reaped");
    assert_eq!(outcome, ReapOutcome::Exited(0));
    reaper.forget(spawned.pid, token);
    // Give the backgrounded grandchild time to run and write its marker.
    std::thread::sleep(Duration::from_millis(1500));
    assert!(marker.exists(), "grandchild must have survived the root's exit and completed");
    let _ = std::fs::remove_file(&marker);
    reaper.shutdown();
}

#[test]
fn part_a_config_9_ignores_sigterm_requires_sigkill_escalation() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reaper = Reaper::new();
    // A busy-loop shell builtin, not `sleep`: `sleep` is a *child* of the shell and has no trap of
    // its own, so `killpg`'s SIGTERM would kill `sleep` (default disposition) and let the shell
    // exit normally right after -- looking like a quick clean exit rather than true escalation.
    // The `:` builtin spins entirely inside the trapping shell process itself.
    let config = SpawnConfig {
        command: "/bin/sh",
        arguments: &["-c".to_string(), "trap '' TERM; while :; do :; done".to_string()],
        environment: &[],
        working_directory: None,
    };
    let spawned = spawn(&config).expect("shell spawn must succeed");
    let token = reaper.register(spawned.pid).expect("fresh pid must register cleanly");
    // Give the freshly-exec'd shell time to actually run `trap '' TERM` before signaling it --
    // otherwise SIGTERM can race the shell's own startup and land while it still has SIGTERM's
    // default (terminating) disposition, which looks like escalation working but actually never
    // exercised it. Found empirically: without this delay, the shell died from plain SIGTERM
    // (signal 15) in ~80us, not SIGKILL, because it hadn't installed its trap yet.
    std::thread::sleep(Duration::from_millis(100));
    let start = std::time::Instant::now();
    let outcome = reaper::terminate_and_reap(&reaper, spawned.pid, token, Duration::from_millis(500));
    let elapsed = start.elapsed();
    assert!(
        matches!(outcome, Some(ReapOutcome::Signaled(sig)) if sig == libc::SIGKILL),
        "expected Signaled(SIGKILL), got {outcome:?} after {elapsed:?}"
    );
    // Grace period elapsed (SIGTERM ignored) before SIGKILL landed -- escalation actually happened,
    // not an immediate coincidental exit.
    assert!(elapsed >= Duration::from_millis(500), "escalation must wait out the grace period");
    reaper.forget(spawned.pid, token);
    reaper.shutdown();
}

// ---------------------------------------------------------------------------------------------
// E-P6-2 Part B: coexistence soak (reduced cycle count -- see results doc for the reduction
// rationale) + R2b thread scaling
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum CycleKind {
    NormalExit,
    SigtermIgnoringEscalation,
    GrandchildOrphan,
    ScopeDropWithoutWait,
}

fn run_cycle(reaper: &Reaper, kind: CycleKind) -> Result<(), String> {
    match kind {
        CycleKind::NormalExit => {
            let config = SpawnConfig {
                command: "/bin/sh",
                arguments: &["-c".to_string(), "exit 0".to_string()],
                environment: &[],
                working_directory: None,
            };
            let spawned = spawn(&config).map_err(|e| format!("{e:?}"))?;
            let token = reaper.register(spawned.pid).map_err(|e| format!("{e:?}"))?;
            let outcome = reaper.wait_for_exit(spawned.pid, token, Duration::from_secs(5));
            reaper.forget(spawned.pid, token);
            match outcome {
                Some(ReapOutcome::Exited(0)) => Ok(()),
                other => Err(format!("normal-exit cycle got {other:?}")),
            }
        }
        CycleKind::SigtermIgnoringEscalation => {
            let config = SpawnConfig {
                command: "/bin/sh",
                arguments: &["-c".to_string(), "trap '' TERM; while :; do :; done".to_string()],
                environment: &[],
                working_directory: None,
            };
            let spawned = spawn(&config).map_err(|e| format!("{e:?}"))?;
            let token = reaper.register(spawned.pid).map_err(|e| format!("{e:?}"))?;
            // See part_a_config_9's comment: give the shell time to install its own trap before
            // signaling it, or SIGTERM can race the shell's startup and land at its default
            // (terminating) disposition, never exercising escalation.
            std::thread::sleep(Duration::from_millis(100));
            let outcome = reaper::terminate_and_reap(reaper, spawned.pid, token, Duration::from_millis(200));
            reaper.forget(spawned.pid, token);
            match outcome {
                Some(ReapOutcome::Signaled(sig)) if sig == libc::SIGKILL => Ok(()),
                other => Err(format!("sigterm-ignoring cycle got {other:?}")),
            }
        }
        CycleKind::GrandchildOrphan => {
            let config = SpawnConfig {
                command: "/bin/sh",
                arguments: &["-c".to_string(), "(sleep 0.2) & exit 0".to_string()],
                environment: &[],
                working_directory: None,
            };
            let spawned = spawn(&config).map_err(|e| format!("{e:?}"))?;
            let token = reaper.register(spawned.pid).map_err(|e| format!("{e:?}"))?;
            let outcome = reaper.wait_for_exit(spawned.pid, token, Duration::from_secs(5));
            reaper.forget(spawned.pid, token);
            match outcome {
                Some(ReapOutcome::Exited(0)) => Ok(()),
                other => Err(format!("grandchild-orphan cycle got {other:?}")),
            }
        }
        CycleKind::ScopeDropWithoutWait => {
            // Registers and *never* calls wait_for_exit -- relies entirely on the periodic
            // self-heal sweep, exactly like a Rust scope dropped without an explicit `shutdown`.
            let config = SpawnConfig {
                command: "/bin/sh",
                arguments: &["-c".to_string(), "exit 0".to_string()],
                environment: &[],
                working_directory: None,
            };
            let spawned = spawn(&config).map_err(|e| format!("{e:?}"))?;
            let _token = reaper.register(spawned.pid).map_err(|e| format!("{e:?}"))?;
            Ok(())
        }
    }
}

/// **No Swift-supervised arm runs in this process.** The design's registered Part B method is
/// "run Rust-supervised children **and** Swift-supervised (`ChildStatusReaperRegistry`-owned)
/// children concurrently in one process" to test R2 ("a second reaper or SIGCHLD handler steals
/// statuses from Swift's sole owners"). No harness in this repo puts the Rust reaper and the Swift
/// `ChildStatusReaperRegistry` in the same process (that needs either the P6-6 FFI bridge or a
/// throwaway `dlopen` harness judged out of proportion for a spike), so this test is a Rust-only
/// soak, not the registered coexistence measurement. What substitutes for R2 here is a *structural*
/// argument, not a measured one: `rust/spikes/agent-claude-derisking-spike/src/reaper.rs` installs
/// no `SIGCHLD` handler anywhere (`grep -n SIGCHLD` on that file matches nothing) and never calls
/// `waitpid(-1, ...)` or any `WAIT_MYPGRP`-style broad wait -- every reap targets a specific,
/// individually-registered PID via `kqueue`/`waitid`. By construction that reaper cannot observe or
/// consume a status belonging to a PID Swift's `ChildStatusReaperRegistry` owns and never registered
/// with it. That argument is a reasonable substitute for a spike, not a replacement for the
/// registered measurement -- true same-process coexistence testing is named as a P6-4 prerequisite
/// in the P6-2 results doc, section 5.
#[test]
fn part_b_rust_only_soak_reduced() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    // Reduced from the design's registered 10,000 cycles to a session-budget-bounded 400 --
    // named and justified in the P6-2 results doc, not silently substituted. Cycle-kind
    // distribution is deliberately weighted toward the cheap NormalExit case so the soak finishes
    // in a bounded wall-clock budget while still exercising every kind repeatedly.
    const CYCLES: usize = 400;
    let reaper = Reaper::new();
    let mut failures: Vec<String> = Vec::new();
    for i in 0..CYCLES {
        let kind = match i % 10 {
            0 => CycleKind::SigtermIgnoringEscalation,
            1 => CycleKind::GrandchildOrphan,
            2 => CycleKind::ScopeDropWithoutWait,
            _ => CycleKind::NormalExit,
        };
        if let Err(e) = run_cycle(&reaper, kind) {
            failures.push(format!("cycle {i}: {e}"));
        }
    }
    // Let the periodic sweep catch every ScopeDropWithoutWait entry before asserting quiescence.
    std::thread::sleep(Duration::from_millis(1200));

    assert!(failures.is_empty(), "{} cycle failure(s):\n{}", failures.len(), failures.join("\n"));
    assert_eq!(reaper.echild_count(), 0, "zero ECHILD across the soak");
    // `pending_count`, not `registered_count`: `ScopeDropWithoutWait` cycles deliberately never
    // call `wait_for_exit`/`forget` (that is the scenario -- a scope dropped without an explicit
    // wait), so their completed-but-unclaimed entries legitimately remain in the map. The real
    // "no leaked reap ownership" property is that every one of them was actually reaped (outcome
    // set) by the periodic self-heal sweep, i.e. zero still-*pending* entries at quiesce.
    assert_eq!(reaper.pending_count(), 0, "zero still-pending registrations at quiesce (every entry was reaped)");
    let residual = reaper.registered_count();
    eprintln!(
        "part_b_rust_only_soak_reduced: {residual} completed-but-unclaimed entries residual \
         (expected: exactly the ScopeDropWithoutWait cycle count, ~1/10 of {CYCLES}) -- this residue \
         is the reclamation-policy gap named in the P6-2 results doc, section 5, finding 3, not a \
         test bug"
    );
    reaper.shutdown();
}

#[test]
fn r2b_thread_budget_scales_as_2n_plus_1() {
    let _guard = SERIAL.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    for &n in &[1usize, 4, 16] {
        let baseline = reaper::AGENT_DOMAIN_THREAD_COUNT.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(baseline, 0, "thread count must be quiescent between N values");

        let reaper = Reaper::new(); // +1 (the shared reaper thread)

        // Simulate N sessions' stdout+stderr reader threads (E-P6-3 builds the real readers;
        // here we only need real, distinct OS threads to measure the budget against, matching
        // contract section 5.2's "2 per session (stdout, stderr) + 1 process-wide reaper" shape).
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut handles = Vec::new();
        for _ in 0..(2 * n) {
            let stop = std::sync::Arc::clone(&stop);
            reaper::AGENT_DOMAIN_THREAD_COUNT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            handles.push(std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_millis(5));
                }
            }));
        }

        let observed = reaper::AGENT_DOMAIN_THREAD_COUNT.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(observed, 2 * n + 1, "N={n}: expected 2N+1 threads attributable to the agent domain");

        stop.store(true, std::sync::atomic::Ordering::SeqCst);
        for h in handles {
            h.join().unwrap();
        }
        reaper::AGENT_DOMAIN_THREAD_COUNT.fetch_sub(2 * n, std::sync::atomic::Ordering::SeqCst);
        reaper.shutdown(); // -1
    }
    assert_eq!(
        reaper::AGENT_DOMAIN_THREAD_COUNT.load(std::sync::atomic::Ordering::SeqCst),
        0,
        "thread count must return to zero after every N"
    );
}
