//! Filesystem contract of the Agent Session Host (design §5.1, §7.2).
//!
//! Mirrors `Sources/RepoPromptDomainRuntime/AgentSessionHost/AgentSessionHostPaths.swift`
//! so a Rust host and a Swift host never collide when they share a root, and so tests that
//! set `AGENTRY_APPLICATION_SUPPORT_ROOT` isolate the Unix socket the same way.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

use agentry_proto::agent_host::PROTOCOL_VERSION;

/// Environment variable that redirects Application Support (same key as Swift).
pub const APPLICATION_SUPPORT_ROOT_ENV: &str = "AGENTRY_APPLICATION_SUPPORT_ROOT";

pub const LEASE_FILE_NAME: &str = "agent-host-v1.lock";
pub const LEASE_OWNER_FILE_NAME: &str = "agent-host-owner-v1.json";
pub const WORKSPACES_DIRECTORY_NAME: &str = "Workspaces";
pub const AGENT_SESSIONS_DIRECTORY_NAME: &str = "AgentSessions";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BuildFlavor {
    Debug,
    Release,
}

impl BuildFlavor {
    #[must_use]
    pub fn current() -> Self {
        if cfg!(debug_assertions) {
            Self::Debug
        } else {
            Self::Release
        }
    }

    #[must_use]
    pub fn socket_infix(self) -> &'static str {
        match self {
            Self::Debug => "D-",
            Self::Release => "",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostPaths {
    pub application_support_root: PathBuf,
    pub build_flavor: BuildFlavor,
    pub protocol_version: u32,
    pub socket_directory: PathBuf,
    pub socket_path: PathBuf,
    pub lock_directory: PathBuf,
    pub lock_file: PathBuf,
    pub owner_metadata_file: PathBuf,
    pub workspaces_root: PathBuf,
}

impl HostPaths {
    #[must_use]
    pub fn resolve(
        application_support_root: Option<PathBuf>,
        build_flavor: BuildFlavor,
        protocol_version: u32,
        user_id: u32,
    ) -> Self {
        let overridden = application_support_root
            .as_ref()
            .map(|path| !path.as_os_str().is_empty())
            .unwrap_or(false);
        let root = application_support_root.unwrap_or_else(default_application_support_root);
        Self::from_root(root, build_flavor, protocol_version, overridden, user_id)
    }

    #[must_use]
    pub fn from_root(
        application_support_root: PathBuf,
        build_flavor: BuildFlavor,
        protocol_version: u32,
        isolated_socket_directory: bool,
        user_id: u32,
    ) -> Self {
        let root = normalize_root(application_support_root);
        let mut socket_directory = PathBuf::from(format!("/tmp/agentry-mcp-{user_id}"));
        if isolated_socket_directory {
            let digest = hex_sha256(root.to_string_lossy().as_bytes());
            socket_directory.push("hosts");
            socket_directory.push(&digest[..12]);
        }
        let socket_name = format!(
            "agentry-agent-host-{}{protocol_version}.sock",
            build_flavor.socket_infix()
        );
        let socket_path = socket_directory.join(socket_name);
        let lock_directory = root.join(".agentry-domain-runtime").join("locks");
        Self {
            socket_directory,
            socket_path,
            lock_file: lock_directory.join(LEASE_FILE_NAME),
            owner_metadata_file: lock_directory.join(LEASE_OWNER_FILE_NAME),
            lock_directory,
            workspaces_root: root.join(WORKSPACES_DIRECTORY_NAME),
            application_support_root: root,
            build_flavor,
            protocol_version,
        }
    }

    /// `AgentSessions/` of one workspace. `workspace_id` is an opaque wire id, never a path.
    pub fn session_directory(&self, workspace_id: &str) -> Result<PathBuf, PathError> {
        if !is_safe_path_component(workspace_id) {
            return Err(PathError::InvalidWorkspaceIdentifier(
                workspace_id.to_string(),
            ));
        }
        Ok(self
            .workspaces_root
            .join(workspace_id)
            .join(AGENT_SESSIONS_DIRECTORY_NAME))
    }

    #[must_use]
    pub fn existing_session_directories(&self) -> Vec<PathBuf> {
        let Ok(entries) = std::fs::read_dir(&self.workspaces_root) else {
            return Vec::new();
        };
        let mut directories = Vec::new();
        for entry in entries.flatten() {
            let sessions = entry.path().join(AGENT_SESSIONS_DIRECTORY_NAME);
            if sessions.is_dir() {
                directories.push(sessions);
            }
        }
        directories.sort();
        directories
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PathError {
    #[error("invalid workspace identifier: {0}")]
    InvalidWorkspaceIdentifier(String),
}

#[must_use]
pub fn is_safe_path_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && value != "."
        && value != ".."
        && !value.contains('/')
        && !value.contains('\0')
        && !value.starts_with('.')
}

#[must_use]
pub fn default_protocol_version() -> u32 {
    PROTOCOL_VERSION
}

fn default_application_support_root() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library/Application Support/Agentry")
}

fn normalize_root(path: PathBuf) -> PathBuf {
    // Match Swift `standardizedFileURL`: expand `~`, do not resolve symlinks.
    // `canonicalize` would turn `/var/folders` into `/private/var/folders` and
    // desync isolated-socket hashes from `AgentSessionHostPaths`.
    expand_tilde(path)
}

fn expand_tilde(path: PathBuf) -> PathBuf {
    let Some(raw) = path.to_str() else {
        return path;
    };
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return Path::new(&home).join(rest);
        }
    }
    path
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isolated_socket_lives_under_hosts_digest() {
        let root = PathBuf::from("/tmp/agentry-host-test-root");
        let paths = HostPaths::from_root(root.clone(), BuildFlavor::Debug, 1, true, 501);
        assert!(
            paths
                .socket_directory
                .starts_with("/tmp/agentry-mcp-501/hosts/")
        );
        assert!(
            paths
                .socket_path
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("agentry-agent-host-D-1.sock")
        );
        assert_eq!(
            paths.lock_file,
            root.join(".agentry-domain-runtime/locks/agent-host-v1.lock")
        );
    }

    #[test]
    fn rejects_unsafe_workspace_ids() {
        assert!(!is_safe_path_component("../x"));
        assert!(!is_safe_path_component(".hidden"));
        assert!(is_safe_path_component("ws-1"));
    }
}
