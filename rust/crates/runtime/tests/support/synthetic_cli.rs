//! P6-4 test-support binary: a synthetic CLI stand-in for `claude`, driven from the integration
//! tests under `rust/crates/runtime/tests/agent_claude_process_*.rs`. Not shipped -- this is a
//! `[[bin]]` target that exists purely so the reader/spawn/reaper test matrix (design §3.4's named
//! "well-behaved, hostile, silent, huge-line, crash-on-signal" set, plus E-P6-3's flood/
//! mid-line-stall/oversized-line/stdin-starved-flood) has a portable, dependency-free driver --
//! no reliance on `python3`/shell availability or path, matching this repo's Rust-first norm.
//!
//! Modes (first argv entry):
//! - `well-behaved` -- one well-formed NDJSON-shaped line, then a clean exit(0).
//! - `hostile` -- traps nothing (default disposition change is done via `trap`-less shell in the
//!   reaper's own SIGTERM-ignoring test); this binary's "hostile" is SIGTERM-ignoring, needing an
//!   explicit disposition change -- see `hostile-ignore-sigterm`.
//! - `hostile-ignore-sigterm` -- ignores SIGTERM (`SIG_IGN`) after printing a ready line, loops
//!   until killed. Requires the caller to synchronize on the ready line before signaling.
//! - `silent <seconds>` -- writes nothing for `<seconds>`, then exits(0). Models a CLI that goes
//!   quiet (design §11's "the CLI goes silent" case) without ever violating the framer/reader.
//! - `huge-line <bytes>` -- writes one line of `<bytes>` `'a'` characters (no embedded newline)
//!   followed by a single trailing `\n`, then exits. Used to drive the framer's overflow path from
//!   a real child process rather than an in-process byte array.
//! - `crash-on-signal` -- prints a ready line, then raises `SIGSEGV` against itself, terminating
//!   by signal rather than exit -- proves the reaper reports `Signaled`, not a hang, for a child
//!   that dies mid-stream without ever calling `exit`.
//! - `flood <ms>` -- writes short well-formed lines back-to-back for `<ms>` milliseconds as fast
//!   as possible, then exits(0). Drives sustained backpressure on the reader/queue.
//! - `mid-line-stall <ms>` -- writes a partial line (no trailing `\n`), sleeps `<ms>`, then
//!   completes the line and exits(0). Proves a stalled mid-object write does not wedge the reader.
//! - `stdin-starved-flood <ms>` -- floods stdout for `<ms>` milliseconds while **never reading
//!   stdin at all** -- the deadlock probe (design §8 E-P6-3): a parent write to this child's stdin
//!   will block once the pipe buffer fills, and INV-P6-2 requires that this never stalls the
//!   *stdout reader* thread regardless.
//! - `scripted <script-path>` -- P6-6: an interactive `agent_claude::scope::AgentClaudeScope`
//!   driver. A background thread reads NDJSON lines from stdin and immediately ACKs any
//!   `control_request` (as a `control_response` success naming the same `request_id`) unless
//!   ACKing has been disabled by the script -- this is what lets a scope-level test exercise the
//!   real interrupt round trip without hand-rolling the protocol. The main thread executes the
//!   script file line by line: `OUT <raw json>` writes that line verbatim to stdout (flushed);
//!   `SLEEP <ms>` sleeps; `NOACK`/`ACK` toggle the background ACK responder (`NOACK` before an
//!   interrupt drives the 1.5 s ACK-timeout outcome); `AWAITACKS <n>` (P6-7, §15.5) blocks the
//!   main thread until the responder has sent at least `<n>` ACKs, a race-free way to sequence a
//!   script's own `OUT` directives *after* `agent_claude::scope::AgentClaudeScope::
//!   start_or_resume`'s session-startup handshake (`initialize`, plus `set_permission_mode` when
//!   configured) has completed, rather than guessing a `SLEEP` long enough to outlast it;
//!   `NOACK_AFTER <n>` (P6-7, §15.5) is the race-free complement for the opposite need -- ACK the
//!   handshake's own `<n>` request(s) normally, then permanently stop ACKing every request after
//!   that, enforced inside the responder thread's own send decision (not a script-side poll), so a
//!   script that wants to starve a *specific* post-handshake control request (interrupt/
//!   apply_model_and_effort ACK-timeout tests) cannot lose a race against `NOACK`'s main-thread-
//!   polled toggle taking effect too late; `ACK_SESSION_ID <id>` (P6-7 D-9/R9 follow-up) sets the
//!   `session_id` the responder embeds in every subsequent ACK's `response` body -- lets a test
//!   prove `send_initialize_request`'s `recordObservedSessionID`-mirroring `session_id` capture
//!   (`scope.rs:508-513`) without any `OUT` stream line ever carrying `session_id` itself, isolating
//!   that capture path from the pre-existing stream-message one (`translator.rs:110-111,143-145`).
//!   Exiting the script (EOF) exits the process, producing a normal stdout EOF.
//! - `stdin-closed-after-delay <delay-ms> <idle-ms>` -- P6-6: reads and ACKs exactly one control
//!   request first (P6-7, §15.5 -- the session-startup `initialize` handshake `start_or_resume`
//!   now sends and blocks on), then sleeps `<delay-ms>`, closes fd 0 (single-threaded, no
//!   background reader for *this* step -- unlike `scripted`, so there is no close-vs-blocked-read
//!   race), then sleeps `<idle-ms>` before exiting, keeping stdout/the process alive throughout.
//!   Deterministically breaks the parent's *next* stdin write after the handshake (`EPIPE`) once
//!   `<delay-ms>` has elapsed, without ever EOF-ing stdout -- drives the interrupt/
//!   apply-model-and-effort `failed` outcome (`ControlOutcome::WriteFailed`) without racing
//!   `on_stdout_eof`'s own turn-flush.
//!
//! Mode resolution normally reads the first argv entry (`raw_argv_for_testing: true`, the
//! runtime-crate-level tests' escape hatch -- see `agent_claude::scope::AgentClaudeScopeConfig`).
//! `CoreAgentClaudeScopeConfigV1`, the FFI-crossing config, has no such escape hatch (contract
//! §2.5's real flag injection is unconditional there), which would permanently pin this binary's
//! `args[1]` to `"-p"` for any FFI-layer test driving a real scope through the production
//! `build_arguments` path. `AGENT_CLAUDE_SYNTHETIC_CLI_ARGS`, when set, overrides the mode/args
//! entirely from an env var instead of positional argv (newline-joined -- env var *values* cannot
//! carry embedded NUL bytes, contract §5.1's spawn layer validates that; none of this binary's
//! mode/argument tokens are ever expected to contain a literal newline) -- sidestepping flag
//! injection without touching `build_arguments` or this binary's existing positional-argv
//! contract at all. `AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_LAUNCH_PATH` optionally records the
//! original production argv plus only the comma-delimited, explicitly named environment keys in
//! `AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_ENV_KEYS`; this lets Swift/Rust variant differentials prove
//! launch parity without ever dumping the ambient environment or secrets. Test-support-only;
//! never read by production.

// Not part of `agentry-runtime`'s `src/` -- a separate binary crate root under this package's
// `tests/support/`, outside `Scripts/rust_ffi_guardrails.py`'s two-site `agent_claude::process`
// unsafe-code count, which scans `rust/crates/runtime/src` only. This test-support-only binary is
// never shipped and carries its own crate-root `#![allow(unsafe_code)]` for the two deliberate,
// documented raw signal calls below (`SIG_IGN` install, `raise(SIGSEGV)`), each with its own
// `SAFETY` comment at the call site.
#![allow(unsafe_code)]

use std::collections::BTreeMap;
use std::io::{BufRead, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

fn record_launch_if_requested(args: &[String]) {
    let Ok(path) = std::env::var("AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_LAUNCH_PATH") else {
        return;
    };
    let environment = std::env::var("AGENT_CLAUDE_SYNTHETIC_CLI_RECORD_ENV_KEYS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|key| !key.is_empty())
        .filter_map(|key| {
            std::env::var(key)
                .ok()
                .map(|value| (key.to_string(), value))
        })
        .collect::<BTreeMap<_, _>>();
    let record = serde_json::json!({
        "argv": args.iter().skip(1).collect::<Vec<_>>(),
        "environment": environment,
    });
    std::fs::write(
        path,
        serde_json::to_vec(&record).expect("serialize launch record"),
    )
    .expect("write synthetic launch record");
}

fn main() {
    let mut args: Vec<String> = std::env::args().collect();
    record_launch_if_requested(&args);
    if let Ok(raw) = std::env::var("AGENT_CLAUDE_SYNTHETIC_CLI_ARGS") {
        let mut overridden = vec![args[0].clone()];
        overridden.extend(raw.split('\n').map(str::to_owned));
        args = overridden;
    }
    let mode = args.get(1).map(String::as_str).unwrap_or("well-behaved");
    let mut stdout = std::io::stdout();
    match mode {
        "well-behaved" => {
            writeln!(stdout, r#"{{"type":"result","subtype":"success"}}"#).expect("write");
        }
        "hostile-ignore-sigterm" => {
            // SAFETY: none -- this test-support binary is not part of `agentry-runtime`'s
            // `unsafe_code` scope (it is a separate crate target under `tests/support`, not
            // `src/`), so the crate-wide `deny(unsafe_code)` does not apply here at all.
            unsafe {
                libc::signal(libc::SIGTERM, libc::SIG_IGN);
            }
            writeln!(stdout, "ready").expect("write");
            stdout.flush().expect("flush");
            loop {
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        "silent" => {
            let seconds: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);
            std::thread::sleep(Duration::from_secs(seconds));
            writeln!(stdout, r#"{{"type":"result","subtype":"success"}}"#).expect("write");
        }
        "huge-line" => {
            let bytes: usize = args
                .get(2)
                .and_then(|s| s.parse().ok())
                .unwrap_or(9 * 1024 * 1024);
            let chunk = vec![b'a'; 64 * 1024];
            let mut written = 0usize;
            while written < bytes {
                let take = chunk.len().min(bytes - written);
                stdout.write_all(&chunk[..take]).expect("write");
                written += take;
            }
            writeln!(stdout).expect("write newline");
        }
        "crash-on-signal" => {
            writeln!(stdout, "ready").expect("write");
            stdout.flush().expect("flush");
            // Raises SIGABRT against ourselves -- a deliberate, controlled way to terminate by
            // signal rather than `exit()`, matching the design's "crash-on-signal" synthetic-CLI
            // row. SIGABRT (not SIGSEGV) specifically: Rust's standard runtime installs its own
            // SIGSEGV handler at startup for stack-overflow-guard-page detection, which can
            // observe a `raise(SIGSEGV)` with no genuine faulting address and simply return
            // rather than re-raise -- letting the process exit(0) normally instead of terminating
            // by signal (confirmed empirically during this test's development). SIGABRT has no
            // such special-cased handler and reliably terminates by signal.
            // SAFETY: abort() takes no arguments, never returns, and has no precondition.
            unsafe {
                libc::abort();
            }
        }
        "flood" => {
            let ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(500);
            let deadline = Instant::now() + Duration::from_millis(ms);
            let mut i: u64 = 0;
            while Instant::now() < deadline {
                writeln!(stdout, r#"{{"type":"stream_event","seq":{i}}}"#).expect("write");
                i += 1;
            }
        }
        "stdin-closed-after-delay" => {
            let delay_ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(50);
            let idle_ms: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(3_000);
            // P6-7 (§15.5): `AgentClaudeScope::start_or_resume` now blocks on a session-startup
            // control-request handshake (`initialize`, contract §2.5) before returning, so this
            // mode -- whose whole point is driving the *next* control request (interrupt/
            // apply_model_and_effort) into a closed pipe -- must ACK exactly that first request
            // before starting its delay/close/idle sequence, or `start_or_resume` would never
            // return. One blocking read, one write, still no background responder -- so there is
            // still no close-vs-blocked-read race for the request this mode exists to fail.
            let stdin = std::io::stdin();
            let mut line = String::new();
            if stdin.lock().read_line(&mut line).unwrap_or(0) > 0 {
                if let Ok(value) = serde_json::from_str::<serde_json::Value>(line.trim()) {
                    if let Some(request_id) = value.get("request_id").and_then(|v| v.as_str()) {
                        let response = serde_json::json!({
                            "type": "control_response",
                            "response": {"subtype": "success", "request_id": request_id},
                        });
                        let _ = writeln!(stdout, "{response}");
                        let _ = stdout.flush();
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(delay_ms));
            // SAFETY: `close(0)` on this process's own stdin fd. No other thread in this
            // single-threaded mode ever reads fd 0, so this is not racing a blocked read() the
            // way `scripted`'s background ACK responder would -- the pipe's read side is fully
            // gone the instant this returns, and the parent's next write reliably gets `EPIPE`.
            unsafe {
                libc::close(0);
            }
            std::thread::sleep(Duration::from_millis(idle_ms));
        }
        "mid-line-stall" => {
            let ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(300);
            write!(stdout, r#"{{"type":"stream_ev"#).expect("write");
            stdout.flush().expect("flush");
            std::thread::sleep(Duration::from_millis(ms));
            writeln!(stdout, r#"ent","seq":0}}"#).expect("write");
        }
        "stdin-starved-flood" => {
            let ms: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1500);
            let deadline = Instant::now() + Duration::from_millis(ms);
            let mut i: u64 = 0;
            while Instant::now() < deadline {
                writeln!(stdout, r#"{{"type":"stream_event","seq":{i}}}"#).expect("write");
                i += 1;
            }
        }
        "scripted" => {
            let script_path = args.get(2).cloned().unwrap_or_default();
            let script = std::fs::read_to_string(&script_path).unwrap_or_else(|error| {
                panic!("failed to read scripted-mode script {script_path:?}: {error}")
            });
            let ack_enabled = Arc::new(AtomicBool::new(true));
            let ack_flag = Arc::clone(&ack_enabled);
            let ack_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
            let ack_count_for_thread = Arc::clone(&ack_count);
            // u64::MAX ("never limit") until a script sets a lower bound via `NOACK_AFTER <n>`.
            let noack_after = Arc::new(std::sync::atomic::AtomicU64::new(u64::MAX));
            let noack_after_for_thread = Arc::clone(&noack_after);
            // Pre-scanned from the script (rather than left to the main thread's line-by-line
            // execution) so a leading `ACK_SESSION_ID <id>` is guaranteed to be in place before the
            // responder thread below is even spawned -- the responder starts reading stdin
            // immediately and can ACK the session-startup `initialize` handshake before the main
            // thread would otherwise reach a mid-script `ACK_SESSION_ID` line, which would silently
            // lose the race and ACK that first request with no `session_id` at all.
            let initial_ack_session_id = script.lines().find_map(|raw_line| {
                let line = raw_line.trim();
                let (directive, rest) = line.split_once(' ').unwrap_or((line, ""));
                (directive == "ACK_SESSION_ID").then(|| rest.trim().to_string())
            });
            let ack_session_id: Arc<std::sync::Mutex<Option<String>>> =
                Arc::new(std::sync::Mutex::new(initial_ack_session_id));
            let ack_session_id_for_thread = Arc::clone(&ack_session_id);
            // Background stdin responder: ACKs every control_request as an immediate success
            // control_response naming the same request_id, unless the script has disabled it via
            // `NOACK` (used to drive the 1.5 s interrupt-ACK-timeout outcome from the real scope).
            let _responder = std::thread::spawn(move || {
                let stdin = std::io::stdin();
                for line in stdin.lock().lines() {
                    let Ok(line) = line else { break };
                    if line.trim().is_empty() {
                        continue;
                    }
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
                        continue;
                    };
                    if value.get("type").and_then(|v| v.as_str()) != Some("control_request") {
                        continue;
                    }
                    if !ack_flag.load(Ordering::SeqCst) {
                        continue;
                    }
                    if ack_count_for_thread.load(Ordering::SeqCst)
                        >= noack_after_for_thread.load(Ordering::SeqCst)
                    {
                        // NOACK_AFTER's permanent cutoff: checked (and enforced) entirely inside
                        // this responder thread's own send decision, so it cannot lose a race
                        // against a script-side directive that has not been polled/executed yet.
                        continue;
                    }
                    let Some(request_id) = value.get("request_id").and_then(|v| v.as_str()) else {
                        continue;
                    };
                    let mut response_body =
                        serde_json::json!({"subtype": "success", "request_id": request_id});
                    // `session_id` belongs in the *nested* `response.response` body (the real
                    // Claude Code SDK's own envelope shape, `codec::ControlResponse.response:
                    // Option<Map>`), not as a sibling of `subtype`/`request_id` at the outer
                    // `response` level -- `send_initialize_request` reads `response.get("session_id")`
                    // off exactly that inner map (`scope.rs:507-513`'s `send_startup_control_request`
                    // return value).
                    if let Some(session_id) = ack_session_id_for_thread
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .clone()
                    {
                        response_body["response"] = serde_json::json!({"session_id": session_id});
                    }
                    let response =
                        serde_json::json!({"type": "control_response", "response": response_body});
                    let mut out = std::io::stdout();
                    let _ = writeln!(out, "{response}");
                    let _ = out.flush();
                    ack_count_for_thread.fetch_add(1, Ordering::SeqCst);
                }
            });
            for raw_line in script.lines() {
                let line = raw_line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                let (directive, rest) = line.split_once(' ').unwrap_or((line, ""));
                match directive {
                    "OUT" => {
                        writeln!(stdout, "{rest}").expect("write scripted OUT line");
                        stdout.flush().expect("flush");
                    }
                    "SLEEP" => {
                        let ms: u64 = rest.trim().parse().unwrap_or(0);
                        std::thread::sleep(Duration::from_millis(ms));
                    }
                    "NOACK" => ack_enabled.store(false, Ordering::SeqCst),
                    "ACK" => ack_enabled.store(true, Ordering::SeqCst),
                    "NOACK_AFTER" => {
                        let limit: u64 = rest.trim().parse().unwrap_or(0);
                        noack_after.store(limit, Ordering::SeqCst);
                    }
                    "ACK_SESSION_ID" => {
                        *ack_session_id
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner) =
                            Some(rest.trim().to_string());
                    }
                    "AWAITACKS" => {
                        let target: u64 = rest.trim().parse().unwrap_or(0);
                        while ack_count.load(Ordering::SeqCst) < target {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                    }
                    other => eprintln!("scripted: ignoring unknown directive {other:?}"),
                }
            }
            // Deliberately not joined: exiting the process (dropping stdin) unblocks the
            // responder's read loop, and this binary has nothing left to do once the script ends.
        }
        other => {
            eprintln!("unknown synthetic-cli mode: {other}");
            std::process::exit(2);
        }
    }
}
