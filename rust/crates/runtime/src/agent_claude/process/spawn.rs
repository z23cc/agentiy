//! P6-4 (`docs/architecture/rust-agent-claude-v1.md` §5.1, design §4.1): the production
//! `posix_spawnp` mirror of `ProcessLauncher.swift` (336 lines) -- every attribute load-bearing,
//! ported line-for-line, per the design's decision to reject `tokio::process` (§4.1) and mirror
//! `posix_spawn` directly via `nix`. Promoted from the P6-2 spike
//! (`rust/spikes/agent-claude-derisking-spike/src/spawn.rs`), with the previously-deferred
//! `chdir` support now implemented via [`crate::agent_claude::process::addchdir`] -- closing the
//! spike's named partial (E-P6-2 Part A's "with cwd" row).
//!
//! Attribute-for-attribute parity with `ProcessLauncher.swift:85-335`:
//! - three pipes (stdin/stdout/stderr), every fd `FD_CLOEXEC`, plus `POSIX_SPAWN_CLOEXEC_DEFAULT`
//!   (Darwin-specific; achievable without `unsafe` via `PosixSpawnFlags::from_bits_truncate` on the
//!   raw `libc` constant -- confirmed during P6-2, see the spike's `spawn.rs` module doc);
//! - `dup2` into 0/1/2, close the parent-retained ends inside the child;
//! - `addchdir_np` for the working directory (this module's addition over the spike);
//! - `posix_spawnattr_setsigdefault(SIGPIPE)`, empty sigmask, new pgroup -- flags `SETSIGDEF` /
//!   `SETSIGMASK` / `SETPGROUP`;
//! - returns `pid` doubling as `processGroupID`, since the child is its own new group's leader.
//!
//! **Zero additional `unsafe` in this module.** Every `nix::spawn`/`nix::unistd`/`nix::fcntl` call
//! used here is a safe `pub fn`; the one genuinely unsafe piece (`addchdir_np`) is isolated to
//! [`crate::agent_claude::process::addchdir`] and consumed here only through its safe wrapper.

use std::ffi::CString;
use std::os::fd::{AsRawFd, OwnedFd};

use nix::fcntl::{FcntlArg, FdFlag, fcntl};
use nix::spawn::{PosixSpawnAttr, PosixSpawnFileActions, PosixSpawnFlags, posix_spawnp};
use nix::sys::signal::{SigSet, Signal};
use nix::unistd::{Pid, pipe};

use super::addchdir::add_chdir;

#[derive(Debug)]
pub enum SpawnError {
    Pipe(nix::Error),
    CloseOnExec(nix::Error),
    FileActions(&'static str, nix::Error),
    /// `posix_spawn_file_actions_addchdir_np` failed; the payload is the raw `errno` value it
    /// returned (see `addchdir::add_chdir`'s doc -- this family returns the code directly).
    Chdir(i32),
    Attributes(&'static str, nix::Error),
    InvalidArgument(&'static str),
    Spawn(nix::Error),
}

impl std::fmt::Display for SpawnError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pipe(error) => write!(formatter, "pipe() failed: {error}"),
            Self::CloseOnExec(error) => write!(formatter, "setting FD_CLOEXEC failed: {error}"),
            Self::FileActions(step, error) => write!(formatter, "posix_spawn_file_actions_{step} failed: {error}"),
            Self::Chdir(errno) => write!(formatter, "posix_spawn_file_actions_addchdir_np failed: errno {errno}"),
            Self::Attributes(step, error) => write!(formatter, "posix_spawnattr_{step} failed: {error}"),
            Self::InvalidArgument(what) => write!(formatter, "invalid spawn argument: {what}"),
            Self::Spawn(error) => write!(formatter, "posix_spawnp failed: {error}"),
        }
    }
}

impl std::error::Error for SpawnError {}

pub struct SpawnConfig<'a> {
    pub command: &'a str,
    pub arguments: &'a [String],
    /// Full replacement environment, exactly as `ProcessLauncher.spawn`'s `environment` parameter
    /// -- **not** merged with the parent's environment (design §5.1: "the already-resolved
    /// environment map"). Never logged (design R8) -- callers must not attach this to any
    /// diagnostic sink.
    pub environment: &'a [(String, String)],
    pub working_directory: Option<&'a str>,
}

#[derive(Debug)]
pub struct SpawnedProcess {
    pub pid: i32,
    /// Equal to `pid` -- the child is the leader of its own new process group
    /// (`POSIX_SPAWN_SETPGROUP` with pgroup `0`), matching `ProcessLauncher.swift:5-12,325-333`.
    pub process_group_id: i32,
    pub stdin_write: OwnedFd,
    pub stdout_read: OwnedFd,
    pub stderr_read: OwnedFd,
}

fn set_cloexec(fd: &OwnedFd) -> Result<(), nix::Error> {
    fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
    Ok(())
}

fn cstring(value: &str, what: &'static str) -> Result<CString, SpawnError> {
    CString::new(value).map_err(|_| SpawnError::InvalidArgument(what))
}

/// Mirrors `ProcessLauncher.spawn` (`ProcessLauncher.swift:85-335`) attribute-for-attribute,
/// including the working directory (`addchdir_np`).
pub fn spawn(config: &SpawnConfig) -> Result<SpawnedProcess, SpawnError> {
    // Three pipes, close-on-exec on every fd -- ProcessLauncher.swift:92-156.
    let (stdin_read, stdin_write) = pipe().map_err(SpawnError::Pipe)?;
    let (stdout_read, stdout_write) = pipe().map_err(SpawnError::Pipe)?;
    let (stderr_read, stderr_write) = pipe().map_err(SpawnError::Pipe)?;
    for fd in [
        &stdin_read,
        &stdin_write,
        &stdout_read,
        &stdout_write,
        &stderr_read,
        &stderr_write,
    ] {
        set_cloexec(fd).map_err(SpawnError::CloseOnExec)?;
    }

    // File actions: dup2 into 0/1/2, close the parent-retained ends inside the child, then
    // (if requested) chdir -- ProcessLauncher.swift:178-196. Order matches Swift: dup2/close
    // before chdir, since chdir affects only the child's subsequent relative-path resolution,
    // not the already-dup'd fds.
    let mut file_actions = PosixSpawnFileActions::init().map_err(|e| SpawnError::FileActions("init", e))?;
    file_actions
        .add_dup2(stdin_read.as_raw_fd(), libc::STDIN_FILENO)
        .map_err(|e| SpawnError::FileActions("adddup2(stdin)", e))?;
    file_actions
        .add_dup2(stdout_write.as_raw_fd(), libc::STDOUT_FILENO)
        .map_err(|e| SpawnError::FileActions("adddup2(stdout)", e))?;
    file_actions
        .add_dup2(stderr_write.as_raw_fd(), libc::STDERR_FILENO)
        .map_err(|e| SpawnError::FileActions("adddup2(stderr)", e))?;
    file_actions
        .add_close(stdin_write.as_raw_fd())
        .map_err(|e| SpawnError::FileActions("addclose(stdin write)", e))?;
    file_actions
        .add_close(stdout_read.as_raw_fd())
        .map_err(|e| SpawnError::FileActions("addclose(stdout read)", e))?;
    file_actions
        .add_close(stderr_read.as_raw_fd())
        .map_err(|e| SpawnError::FileActions("addclose(stderr read)", e))?;
    if let Some(dir) = config.working_directory {
        let dir_c = cstring(dir, "working_directory")?;
        add_chdir(&mut file_actions, &dir_c).map_err(SpawnError::Chdir)?;
    }

    // Attributes: sigdefault(SIGPIPE), empty sigmask, new pgroup, CLOEXEC_DEFAULT --
    // ProcessLauncher.swift:213-275.
    let mut attr = PosixSpawnAttr::init().map_err(|e| SpawnError::Attributes("init", e))?;

    let mut default_signals = SigSet::empty();
    default_signals.add(Signal::SIGPIPE);
    attr.set_sigdefault(&default_signals)
        .map_err(|e| SpawnError::Attributes("setsigdefault", e))?;

    attr.set_sigmask(&SigSet::empty())
        .map_err(|e| SpawnError::Attributes("setsigmask", e))?;

    attr.set_pgroup(Pid::from_raw(0))
        .map_err(|e| SpawnError::Attributes("setpgroup", e))?;

    let base_flags = PosixSpawnFlags::POSIX_SPAWN_SETSIGDEF
        | PosixSpawnFlags::POSIX_SPAWN_SETSIGMASK
        | PosixSpawnFlags::POSIX_SPAWN_SETPGROUP;
    // `POSIX_SPAWN_CLOEXEC_DEFAULT` has no named `nix` flag; `from_bits_truncate` on the raw libc
    // constant is a safe `bitflags`-generated constructor (confirmed during P6-2; see the spike's
    // module doc for the source-level verification).
    let flags = PosixSpawnFlags::from_bits_truncate(base_flags.bits() | libc::POSIX_SPAWN_CLOEXEC_DEFAULT);
    attr.set_flags(flags).map_err(|e| SpawnError::Attributes("setflags", e))?;

    let command_c = cstring(config.command, "command")?;
    let mut argv_c: Vec<CString> = Vec::with_capacity(config.arguments.len() + 1);
    argv_c.push(command_c.clone());
    for arg in config.arguments {
        argv_c.push(cstring(arg, "argument")?);
    }
    let envp_c: Vec<CString> = config
        .environment
        .iter()
        .map(|(k, v)| cstring(&format!("{k}={v}"), "environment entry"))
        .collect::<Result<_, _>>()?;

    let pid = posix_spawnp(&command_c, &file_actions, &attr, &argv_c, &envp_c).map_err(SpawnError::Spawn)?;

    // Parent-retained ends of the pipe halves handed to the child are closed by the spawned
    // process's own file actions above; the parent still holds the *other* halves and must close
    // its copies of the child-facing halves here, exactly as ProcessLauncher.swift:319-321.
    drop(stdin_read);
    drop(stdout_write);
    drop(stderr_write);

    Ok(SpawnedProcess {
        pid: pid.as_raw(),
        process_group_id: pid.as_raw(),
        stdin_write,
        stdout_read,
        stderr_read,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn spawn_probe(config: &SpawnConfig) -> SpawnedProcess {
        spawn(config).unwrap_or_else(|e| panic!("spawn failed: {e}"))
    }

    #[test]
    fn spawns_and_reports_expected_pgroup() {
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/sh",
            arguments: &["-c".to_string(), "exit 0".to_string()],
            environment: &[],
            working_directory: None,
        });
        assert_eq!(child.pid, child.process_group_id);
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn working_directory_is_honored() {
        let tmp = std::env::temp_dir();
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/pwd",
            arguments: &[],
            environment: &[],
            working_directory: Some(tmp.to_str().expect("utf8 tmp path")),
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read pwd output");
        let reported = buf.trim();
        let expected = std::fs::canonicalize(&tmp).unwrap_or(tmp.clone());
        let reported_canonical = std::fs::canonicalize(reported).unwrap_or_else(|_| reported.into());
        assert_eq!(reported_canonical, expected);
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn empty_environment_does_not_inherit_parent() {
        let child = spawn_probe(&SpawnConfig {
            command: "/usr/bin/env",
            arguments: &[],
            environment: &[],
            working_directory: None,
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read env output");
        assert!(buf.trim().is_empty(), "expected no inherited environment, got {buf:?}");
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn missing_binary_reports_enoent() {
        let err = spawn(&SpawnConfig {
            command: "/no/such/binary/here",
            arguments: &[],
            environment: &[],
            working_directory: None,
        })
        .expect_err("missing binary must fail to spawn");
        assert!(matches!(err, SpawnError::Spawn(nix::Error::ENOENT)), "unexpected error: {err}");
    }

    #[test]
    fn custom_env_key_is_visible_to_child() {
        let child = spawn_probe(&SpawnConfig {
            command: "/usr/bin/env",
            arguments: &[],
            environment: &[("AGENT_CLAUDE_PROBE_KEY".to_string(), "probe-value".to_string())],
            working_directory: None,
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read env output");
        assert_eq!(buf.trim(), "AGENT_CLAUDE_PROBE_KEY=probe-value");
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn deep_argv_is_passed_through_intact() {
        let args: Vec<String> = (0..64).map(|i| format!("arg{i}")).collect();
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/echo",
            arguments: &args,
            environment: &[],
            working_directory: None,
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read echo output");
        assert_eq!(buf.trim(), args.join(" "));
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn argv_with_spaces_and_multibyte_utf8_survives() {
        let arg = "has spaces \u{1F600} and multi-byte \u{00e9}".to_string();
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/echo",
            arguments: &[arg.clone()],
            environment: &[],
            working_directory: None,
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read echo output");
        assert_eq!(buf.trim(), arg);
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }

    #[test]
    fn non_executable_binary_reports_eacces() {
        let tmp = std::env::temp_dir().join(format!("agent-claude-non-exec-{}", std::process::id()));
        std::fs::write(&tmp, b"#!/bin/sh\necho nope\n").expect("write non-executable fixture");
        std::fs::set_permissions(&tmp, std::os::unix::fs::PermissionsExt::from_mode(0o644)).expect("chmod 644");
        let path = tmp.to_str().expect("utf8 path").to_string();
        let err = spawn(&SpawnConfig {
            command: &path,
            arguments: &[],
            environment: &[],
            working_directory: None,
        })
        .expect_err("non-executable binary must fail to spawn");
        let _ = std::fs::remove_file(&tmp);
        assert!(matches!(err, SpawnError::Spawn(nix::Error::EACCES)), "unexpected error: {err}");
    }

    #[test]
    fn shell_grandchild_stays_in_the_spawned_process_group() {
        // The root (`/bin/sh -c`) forks a grandchild (`sleep`) and exits immediately; the
        // grandchild is reparented but stays in the group `posix_spawnattr_setpgroup` placed the
        // root into, so a group-wide signal (killpg) still reaches it -- ProcessLauncher.swift's
        // rationale for pgroup-scoped cleanup.
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/sh",
            arguments: &["-c".to_string(), "sleep 30 >/dev/null 2>&1 & echo $! ; exit 0".to_string()],
            environment: &[],
            working_directory: None,
        });
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read grandchild pid");
        let grandchild_pid: i32 = buf.trim().parse().expect("grandchild pid");
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
        // Root has exited; the grandchild should still be alive and in the same process group.
        let grandchild_pgid = nix::unistd::getpgid(Some(nix::unistd::Pid::from_raw(grandchild_pid)))
            .expect("grandchild must still be alive and queryable");
        assert_eq!(grandchild_pgid.as_raw(), child.process_group_id);
        let _ = nix::sys::signal::killpg(nix::unistd::Pid::from_raw(child.process_group_id), nix::sys::signal::Signal::SIGKILL);
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(grandchild_pid), None);
    }

    #[test]
    fn stdin_write_is_wired_to_child_stdin() {
        let child = spawn_probe(&SpawnConfig {
            command: "/bin/cat",
            arguments: &[],
            environment: &[],
            working_directory: None,
        });
        let mut input = std::fs::File::from(child.stdin_write);
        input.write_all(b"hello\n").expect("write to stdin");
        drop(input);
        let mut out = std::fs::File::from(child.stdout_read);
        let mut buf = String::new();
        out.read_to_string(&mut buf).expect("read cat output");
        assert_eq!(buf, "hello\n");
        let _ = nix::sys::wait::waitpid(nix::unistd::Pid::from_raw(child.pid), None);
    }
}
