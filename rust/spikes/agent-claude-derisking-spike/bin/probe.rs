//! E-P6-2 Part A attribute-report probe child.
//!
//! Launched via *both* `ProcessLauncher.spawn` (Swift arm) and
//! `agent_claude_derisking_spike::spawn::spawn` (Rust arm) with identical inputs; reports its own
//! `getpgid(0)`, blocked-signal mask, `SIGPIPE` disposition, open-FD set with `FD_CLOEXEC` flags,
//! visible environment-variable keys, argv, and `getcwd()` as one JSON object on stdout, then
//! exits 0. The two reports are diffed offline (`scripts/compare_probe_reports.py` in this spike
//! directory) per contract section 5.1 / design E-P6-2 Part A.
//!
//! This binary is a leaf process, not a library the eventual P6-4 production port consumes, so it
//! is not held to `spawn.rs`'s zero-`unsafe` bar; reading (not installing) `SIGPIPE`'s disposition
//! and enumerating the FD table require direct `libc` calls that `nix` does not wrap as read-only
//! safe functions.
//!
//! **`#![no_main]`, deliberately.** A normal `fn main()` Rust binary has its `SIGPIPE` disposition
//! forced to `SIG_IGN` by `std::rt::init` (the language-start shim that runs before `main`'s body,
//! well-documented Rust behavior predating the still-unstable `#[unix_sigpipe]` attribute) --
//! **regardless of what the spawning process requested**. That would silently make this probe
//! always report `"ignore"` for `SIGPIPE`, contaminating the exact measurement E-P6-2 Part A exists
//! to take, and would falsely look like a spawner bug. Bypassing `lang_start` via a raw C `main`
//! entry point skips that reset entirely, so this probe reports the disposition it actually
//! inherited from the spawn. Discovered empirically during this spike: an early version of this
//! probe (plain `fn main()`) reported `"ignore"` for every config, including ones where the Rust
//! spawner correctly requested `SIG_DFL`.

#![no_main]

use std::collections::BTreeMap;
use std::os::raw::{c_char, c_int};

use serde::Serialize;

#[derive(Serialize)]
struct FdReport {
    fd: i32,
    cloexec: bool,
}

#[derive(Serialize)]
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

fn sigpipe_disposition() -> String {
    // Read-only in effect: reinstalling the currently-installed disposition is a no-op syscall,
    // and this is the only way POSIX `sigaction` exposes the *current* disposition.
    let mut old: libc::sigaction = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut old) };
    if rc != 0 {
        return format!("sigaction-query-failed-errno-{}", std::io::Error::last_os_error().raw_os_error().unwrap_or(-1));
    }
    let handler = old.sa_sigaction;
    if handler == libc::SIG_DFL {
        "default".to_string()
    } else if handler == libc::SIG_IGN {
        "ignore".to_string()
    } else {
        "handler".to_string()
    }
}

fn blocked_signals() -> Vec<i32> {
    let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::pthread_sigmask(0 /* SIG_BLOCK with NULL set = query-only */, std::ptr::null(), &mut set) };
    if rc != 0 {
        return Vec::new();
    }
    let mut blocked = Vec::new();
    // 1..=31 covers every standard signal number on Darwin (NSIG is 32).
    for signum in 1..32 {
        let is_member = unsafe { libc::sigismember(&set, signum) };
        if is_member == 1 {
            blocked.push(signum);
        }
    }
    blocked
}

fn open_fds() -> Vec<FdReport> {
    let max_fd = unsafe { libc::getdtablesize() };
    let mut reports = Vec::new();
    for fd in 0..max_fd {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        if flags == -1 {
            continue; // closed fd (EBADF)
        }
        reports.push(FdReport {
            fd,
            cloexec: flags & libc::FD_CLOEXEC != 0,
        });
    }
    reports
}

fn cwd() -> Result<String, String> {
    std::env::current_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .map_err(|e| e.to_string())
}

/// Real C entry point -- `#![no_main]` above means Rust generates no `lang_start` wrapper, so
/// `std::rt::init` (and its `SIGPIPE`-to-`SIG_IGN` reset) never runs before this.
#[no_mangle]
pub extern "C" fn main(_argc: c_int, _argv: *const *const c_char) -> c_int {
    // Report which caller-supplied environment keys are actually visible (for the "with/without
    // inherited env keys" E-P6-2 configuration axis). `std::env::vars()` reads the `environ`
    // global the OS/libc populates at process start -- independent of `std::rt::init` -- so it
    // works correctly even without `lang_start`.
    let env_keys: Vec<String> = {
        let map: BTreeMap<String, String> = std::env::vars().collect();
        map.into_keys().collect()
    };
    // `std::env::args()` on macOS reads `_NSGetArgv`/`_NSGetArgc`, likewise independent of
    // `lang_start`.
    let argv: Vec<String> = std::env::args().collect();

    let report = ProbeReport {
        pid: std::process::id() as i32,
        pgid: unsafe { libc::getpgid(0) },
        sigpipe_disposition: sigpipe_disposition(),
        blocked_signals: blocked_signals(),
        cwd: cwd(),
        open_fds: open_fds(),
        env_keys,
        argv,
    };

    println!("{}", serde_json::to_string(&report).expect("report must serialize"));
    0
}
