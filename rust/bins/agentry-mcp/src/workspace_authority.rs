//! P8 fence-claim of the existing workspace-authority flock (same lock as
//! `DomainWorkspaceAuthorityLease`). Not a second lock. GUI-shaped holders
//! (`mode == "app"`) are never stolen.

use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use nix::fcntl::{Flock, FlockArg};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::lease::ensure_directory;
use crate::paths::HostPaths;
use crate::time::rfc3339_now;
use crate::util::uuid_v4;

const LOCK_FILE_NAME: &str = "workspace-authority-v1.lock";
const OWNER_FILE_NAME: &str = "workspace-authority-owner-v1.json";
const DIGEST_DOMAIN: &str = "agentry-workspace-authority-lease-v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceAuthorityOwner {
    pub version: i32,
    #[serde(rename = "runtimeID")]
    pub runtime_id: String,
    pub lifecycle_generation: u64,
    #[serde(rename = "processID")]
    pub process_id: i32,
    pub mode: String,
    pub profile_identifier: String,
    pub storage_scope_digest: String,
    pub implementation: String,
    pub lease_epoch: String,
    pub acquired_at: String,
}

impl WorkspaceAuthorityOwner {
    #[must_use]
    pub fn is_gui_shaped(&self) -> bool {
        self.mode == "app"
    }

    #[must_use]
    pub fn rust_standalone(storage_scope_digest: impl Into<String>) -> Self {
        Self {
            version: 1,
            runtime_id: uuid_v4(),
            lifecycle_generation: 1,
            process_id: std::process::id() as i32,
            mode: "standalone".to_string(),
            profile_identifier: "agent-session-host".to_string(),
            storage_scope_digest: storage_scope_digest.into(),
            implementation: "rust".to_string(),
            lease_epoch: uuid_v4(),
            acquired_at: rfc3339_now(),
        }
    }
}

#[derive(Debug)]
pub enum WorkspaceAuthorityObservation {
    Unused,
    Held(Option<WorkspaceAuthorityOwner>),
    Failed(String),
}

impl WorkspaceAuthorityObservation {
    #[must_use]
    pub fn has_live_gui_holder(&self) -> bool {
        matches!(self, Self::Held(Some(owner)) if owner.is_gui_shaped())
    }
}

#[derive(Debug)]
pub enum WorkspaceClaim {
    Acquired(WorkspaceAuthorityLease),
    RefusedGUI {
        observed_owner: WorkspaceAuthorityOwner,
    },
    Contended {
        observed_owner: Option<WorkspaceAuthorityOwner>,
    },
    Failed(String),
}

/// Held exclusive flock on `workspace-authority-v1.lock`. Dropping releases it.
pub struct WorkspaceAuthorityLease {
    pub owner: WorkspaceAuthorityOwner,
    owner_metadata_file: PathBuf,
    lock: Option<Flock<File>>,
}

impl std::fmt::Debug for WorkspaceAuthorityLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WorkspaceAuthorityLease")
            .field("owner", &self.owner)
            .field("held", &self.lock.is_some())
            .finish()
    }
}

impl WorkspaceAuthorityLease {
    #[must_use]
    pub fn observe(paths: &HostPaths) -> WorkspaceAuthorityObservation {
        observe_scope(&workspace_lock_paths(paths))
    }

    #[must_use]
    pub fn fence_claim(paths: &HostPaths) -> WorkspaceClaim {
        let scope = workspace_lock_paths(paths);
        match observe_scope(&scope) {
            WorkspaceAuthorityObservation::Held(Some(owner)) if owner.is_gui_shaped() => {
                return WorkspaceClaim::RefusedGUI {
                    observed_owner: owner,
                };
            }
            WorkspaceAuthorityObservation::Failed(reason) => {
                return WorkspaceClaim::Failed(reason);
            }
            WorkspaceAuthorityObservation::Unused
            | WorkspaceAuthorityObservation::Held(_) => {}
        }
        acquire_scope(&scope)
    }

    pub fn release(&mut self) {
        if self.lock.take().is_some() {
            let _ = fs::remove_file(&self.owner_metadata_file);
        }
    }

    /// Hold the flock as a GUI-shaped (`mode == "app"`) owner until dropped.
    /// Used by host-bind tests; not a production writer.
    #[must_use]
    pub fn hold_gui_shaped_fixture(paths: &HostPaths) -> WorkspaceClaim {
        match Self::fence_claim(paths) {
            WorkspaceClaim::Acquired(mut lease) => {
                lease.owner.mode = "app".to_string();
                lease.owner.implementation = "swift".to_string();
                if let Err(error) = write_owner(&lease.owner_metadata_file, &lease.owner) {
                    return WorkspaceClaim::Failed(format!("gui fixture metadata: {error}"));
                }
                WorkspaceClaim::Acquired(lease)
            }
            other => other,
        }
    }
}

impl Drop for WorkspaceAuthorityLease {
    fn drop(&mut self) {
        self.release();
    }
}

struct WorkspaceLockPaths {
    lock_directory: PathBuf,
    lock_file: PathBuf,
    owner_metadata_file: PathBuf,
    storage_scope_digest: String,
}

fn workspace_lock_paths(paths: &HostPaths) -> WorkspaceLockPaths {
    let workspaces = paths.workspaces_root.clone();
    let lock_directory = workspaces
        .join(".agentry-domain-runtime")
        .join("locks");
    WorkspaceLockPaths {
        lock_file: lock_directory.join(LOCK_FILE_NAME),
        owner_metadata_file: lock_directory.join(OWNER_FILE_NAME),
        lock_directory,
        storage_scope_digest: storage_scope_digest(&workspaces),
    }
}

fn storage_scope_digest(canonical_workspace_path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(DIGEST_DOMAIN.as_bytes());
    hasher.update([0u8]);
    hasher.update(canonical_workspace_path.to_string_lossy().as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn observe_scope(scope: &WorkspaceLockPaths) -> WorkspaceAuthorityObservation {
    let file = match OpenOptions::new().read(true).open(&scope.lock_file) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return WorkspaceAuthorityObservation::Unused;
        }
        Err(error) => {
            return WorkspaceAuthorityObservation::Failed(format!("observe open: {error}"));
        }
    };
    match Flock::lock(file, FlockArg::LockExclusiveNonblock) {
        Ok(lock) => {
            drop(lock);
            WorkspaceAuthorityObservation::Unused
        }
        Err((_, nix::errno::Errno::EWOULDBLOCK)) => {
            WorkspaceAuthorityObservation::Held(read_owner(&scope.owner_metadata_file))
        }
        Err((_, error)) => WorkspaceAuthorityObservation::Failed(format!("observe flock: {error}")),
    }
}

fn acquire_scope(scope: &WorkspaceLockPaths) -> WorkspaceClaim {
    if let Err(error) = ensure_directory(&scope.lock_directory, 0o700) {
        return WorkspaceClaim::Failed(format!("create lock directory: {error}"));
    }
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .mode(0o600)
        .open(&scope.lock_file)
    {
        Ok(file) => file,
        Err(error) => return WorkspaceClaim::Failed(format!("open lock file: {error}")),
    };
    match Flock::lock(file, FlockArg::LockExclusiveNonblock) {
        Ok(lock) => {
            let owner = WorkspaceAuthorityOwner::rust_standalone(scope.storage_scope_digest.clone());
            let lease = WorkspaceAuthorityLease {
                owner: owner.clone(),
                owner_metadata_file: scope.owner_metadata_file.clone(),
                lock: Some(lock),
            };
            if let Err(error) = write_owner(&scope.owner_metadata_file, &owner) {
                return WorkspaceClaim::Failed(format!("owner metadata: {error}"));
            }
            WorkspaceClaim::Acquired(lease)
        }
        Err((_, nix::errno::Errno::EWOULDBLOCK)) => {
            let observed = read_owner(&scope.owner_metadata_file);
            if let Some(owner) = observed.clone().filter(WorkspaceAuthorityOwner::is_gui_shaped) {
                WorkspaceClaim::RefusedGUI {
                    observed_owner: owner,
                }
            } else {
                WorkspaceClaim::Contended {
                    observed_owner: observed,
                }
            }
        }
        Err((_, error)) => WorkspaceClaim::Failed(format!("flock: {error}")),
    }
}

fn read_owner(path: &Path) -> Option<WorkspaceAuthorityOwner> {
    let mut file = File::open(path).ok()?;
    let mut body = String::new();
    file.read_to_string(&mut body).ok()?;
    serde_json::from_str(&body).ok()
}

fn write_owner(path: &Path, owner: &WorkspaceAuthorityOwner) -> std::io::Result<()> {
    let body = serde_json::to_vec_pretty(owner)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&temporary, body)?;
    fs::rename(temporary, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::{BuildFlavor, HostPaths};

    fn scratch_paths() -> HostPaths {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "agentry-workspace-lease-{}-{}",
            std::process::id(),
            nanos
        ));
        let _ = fs::create_dir_all(root.join("Workspaces"));
        HostPaths::from_root(
            root,
            BuildFlavor::Debug,
            1,
            true,
            crate::peer::current_uid(),
        )
    }

    #[test]
    fn claims_when_unused_and_releases() {
        let paths = scratch_paths();
        let observation = WorkspaceAuthorityLease::observe(&paths);
        assert!(matches!(
            observation,
            WorkspaceAuthorityObservation::Unused
        ));
        let mut lease = match WorkspaceAuthorityLease::fence_claim(&paths) {
            WorkspaceClaim::Acquired(lease) => lease,
            other => panic!("expected acquired, got {other:?}"),
        };
        assert!(!lease.owner.is_gui_shaped());
        match WorkspaceAuthorityLease::fence_claim(&paths) {
            WorkspaceClaim::Contended { .. } => {}
            other => panic!("second claim must contend, got {other:?}"),
        }
        lease.release();
        assert!(matches!(
            WorkspaceAuthorityLease::observe(&paths),
            WorkspaceAuthorityObservation::Unused
        ));
        let _ = fs::remove_dir_all(&paths.application_support_root);
    }

    #[test]
    fn refuses_gui_shaped_holder() {
        let paths = scratch_paths();
        let scope = workspace_lock_paths(&paths);
        ensure_directory(&scope.lock_directory, 0o700).expect("lock dir");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(&scope.lock_file)
            .expect("lock file");
        let lock = Flock::lock(file, FlockArg::LockExclusiveNonblock).expect("gui flock");
        let mut gui = WorkspaceAuthorityOwner::rust_standalone(scope.storage_scope_digest);
        gui.mode = "app".to_string();
        gui.implementation = "swift".to_string();
        write_owner(&scope.owner_metadata_file, &gui).expect("gui owner");

        match WorkspaceAuthorityLease::fence_claim(&paths) {
            WorkspaceClaim::RefusedGUI { observed_owner } => {
                assert!(observed_owner.is_gui_shaped());
            }
            other => panic!("expected refused GUI, got {other:?}"),
        }
        drop(lock);
        let _ = fs::remove_dir_all(&paths.application_support_root);
    }
}
