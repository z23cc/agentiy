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

// Not part of `agentry-runtime`'s `src/` -- a separate binary crate root under this package's
// `tests/support/`, outside `Scripts/rust_ffi_guardrails.py`'s two-site `agent_claude::process`
// unsafe-code count, which scans `rust/crates/runtime/src` only. This test-support-only binary is
// never shipped and carries its own crate-root `#![allow(unsafe_code)]` for the two deliberate,
// documented raw signal calls below (`SIG_IGN` install, `raise(SIGSEGV)`), each with its own
// `SAFETY` comment at the call site.
#![allow(unsafe_code)]

use std::io::Write;
use std::time::{Duration, Instant};

fn main() {
    let args: Vec<String> = std::env::args().collect();
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
            let bytes: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(9 * 1024 * 1024);
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
        other => {
            eprintln!("unknown synthetic-cli mode: {other}");
            std::process::exit(2);
        }
    }
}
