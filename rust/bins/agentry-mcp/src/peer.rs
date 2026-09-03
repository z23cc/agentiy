//! Executable identity and peer verification (design §5.3).
//!
//! The kernel-reported peer pid (`LOCAL_PEERPID`) is the trusted input. `Hello.executable`
//! is informational and only cross-checked for a claimed bundle identifier.

use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use agentry_proto::agent_host::v1::{ExecutableIdentity, Hello};

/// Process uid. `getuid` has no preconditions.
#[must_use]
pub fn current_uid() -> u32 {
    // SAFETY: getuid is unconditionally safe.
    #[allow(unsafe_code)]
    unsafe {
        libc::getuid()
    }
}

#[must_use]
pub fn current_pid() -> u32 {
    std::process::id()
}

/// Become a session leader so provider children share one process group (design §7.3).
/// `EPERM` means this process already leads a group.
pub fn become_session_leader() {
    #[allow(unsafe_code)]
    unsafe {
        libc::setsid();
    }
}

#[must_use]
pub fn current_executable() -> Option<PathBuf> {
    executable_path(std::process::id() as libc::pid_t)
}

#[must_use]
pub fn current_identity(bundle_identifier: &str) -> ExecutableIdentity {
    let executable = current_executable();
    ExecutableIdentity {
        bundle_identifier: bundle_identifier.to_string(),
        executable_name: executable
            .as_ref()
            .and_then(|path| path.file_name())
            .and_then(|name| name.to_str())
            .unwrap_or("agentry-mcp")
            .to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        build_number: String::new(),
        pid: current_pid(),
        code_signing_team_identifier: String::new(),
    }
}

#[must_use]
pub fn peer_pid(stream: &UnixStream) -> Option<libc::pid_t> {
    let fd = stream.as_raw_fd();
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `fd` is a live UnixStream; `LOCAL_PEERPID` writes a pid_t into `pid`.
    #[allow(unsafe_code)]
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            std::ptr::from_mut(&mut pid).cast(),
            &mut len,
        )
    };
    if rc == 0 && pid > 0 { Some(pid) } else { None }
}

#[must_use]
pub fn executable_path(pid: libc::pid_t) -> Option<PathBuf> {
    let mut buffer = [0u8; 4096];
    // SAFETY: `proc_pidpath` writes at most `buffer.len()` bytes into `buffer`.
    #[allow(unsafe_code)]
    let length = unsafe { proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    let path = String::from_utf8_lossy(&buffer[..length as usize]).into_owned();
    Some(PathBuf::from(path))
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
unsafe extern "C" {
    fn proc_pidpath(pid: libc::pid_t, buffer: *mut libc::c_void, buffersize: u32) -> libc::c_int;
}

#[cfg(not(target_os = "macos"))]
fn proc_pidpath(_pid: libc::pid_t, _buffer: *mut libc::c_void, _buffersize: u32) -> libc::c_int {
    -1
}

#[must_use]
pub fn bundle_root(executable: &Path) -> Option<PathBuf> {
    let mut cursor = executable.to_path_buf();
    while let Some(parent) = cursor.parent() {
        if cursor.extension().and_then(|ext| ext.to_str()) == Some("app") {
            return Some(cursor);
        }
        if parent == cursor {
            break;
        }
        cursor = parent.to_path_buf();
    }
    None
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PeerVerdict {
    Accepted,
    Rejected(String),
}

#[must_use]
pub fn verify_peer(
    stream: &UnixStream,
    hello: &Hello,
    accept_any: bool,
    own_bundle_identifier: &str,
) -> PeerVerdict {
    let Some(pid) = peer_pid(stream) else {
        return PeerVerdict::Rejected("peer pid unavailable".to_string());
    };
    if accept_any {
        return PeerVerdict::Accepted;
    }
    let Some(own) = current_executable() else {
        return PeerVerdict::Rejected("own executable path unavailable".to_string());
    };
    let Some(peer) = executable_path(pid) else {
        return PeerVerdict::Rejected(format!("peer executable path unavailable for pid {pid}"));
    };
    let same_executable = peer == own;
    let same_bundle = match (bundle_root(&own), bundle_root(&peer)) {
        (Some(left), Some(right)) => left == right,
        _ => false,
    };
    if !same_executable && !same_bundle {
        return PeerVerdict::Rejected(format!(
            "peer executable {} is not {}",
            peer.display(),
            own.display()
        ));
    }
    if let Some(claimed) = hello.executable.as_ref() {
        if !claimed.bundle_identifier.is_empty()
            && !own_bundle_identifier.is_empty()
            && claimed.bundle_identifier != own_bundle_identifier
        {
            return PeerVerdict::Rejected(format!(
                "bundle identifier {} is not {own_bundle_identifier}",
                claimed.bundle_identifier
            ));
        }
    }
    PeerVerdict::Accepted
}
