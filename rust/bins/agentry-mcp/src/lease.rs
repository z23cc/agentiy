//! Per-user exclusive `flock` on `agent-host-v1.lock` (design §5.1).
//!
//! Owner metadata beside the lock is diagnostic only. The kernel releases the
//! flock on `SIGKILL`, so a stale owner file never blocks a successor. Stale
//! socket unlink is legal only after [`HostLease::acquire`] returns `Acquired`.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;

use nix::fcntl::{Flock, FlockArg};
use serde::{Deserialize, Serialize};

use crate::paths::HostPaths;
use crate::time::rfc3339_now;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaseOwner {
    pub version: u32,
    #[serde(rename = "hostInstanceID")]
    pub host_instance_id: String,
    #[serde(rename = "processID")]
    pub process_id: i32,
    #[serde(rename = "buildFingerprint")]
    pub build_fingerprint: String,
    pub implementation: String,
    #[serde(rename = "socketPath")]
    pub socket_path: String,
    #[serde(rename = "acquiredAt")]
    pub acquired_at: String,
}

impl LeaseOwner {
    #[must_use]
    pub fn rust(
        host_instance_id: impl Into<String>,
        build_fingerprint: impl Into<String>,
        socket_path: impl Into<String>,
    ) -> Self {
        Self {
            version: 1,
            host_instance_id: host_instance_id.into(),
            process_id: std::process::id() as i32,
            build_fingerprint: build_fingerprint.into(),
            implementation: "rust".to_string(),
            socket_path: socket_path.into(),
            acquired_at: rfc3339_now(),
        }
    }
}

#[derive(Debug)]
pub enum LeaseAcquisition {
    Acquired(HostLease),
    Contended { observed_owner: Option<LeaseOwner> },
    Failed(String),
}

/// Held exclusive flock. Dropping releases the lock and removes the owner file.
#[derive(Debug)]
pub struct HostLease {
    pub paths: HostPaths,
    pub owner: LeaseOwner,
    lock: Option<Flock<File>>,
}

impl HostLease {
    #[must_use]
    pub fn acquire(paths: HostPaths, owner: LeaseOwner) -> LeaseAcquisition {
        if let Err(error) = ensure_directory(&paths.lock_directory, 0o700) {
            return LeaseAcquisition::Failed(format!("create lock directory: {error}"));
        }
        let file = match OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .open(&paths.lock_file)
        {
            Ok(file) => file,
            Err(error) => return LeaseAcquisition::Failed(format!("open lock file: {error}")),
        };
        match Flock::lock(file, FlockArg::LockExclusiveNonblock) {
            Ok(lock) => {
                let lease = HostLease {
                    paths,
                    owner,
                    lock: Some(lock),
                };
                lease.write_owner_metadata();
                LeaseAcquisition::Acquired(lease)
            }
            Err((_, nix::errno::Errno::EWOULDBLOCK)) => LeaseAcquisition::Contended {
                observed_owner: read_owner(&paths),
            },
            Err((_, error)) => LeaseAcquisition::Failed(format!("flock: {error}")),
        }
    }

    pub fn release(&mut self) {
        if self.lock.take().is_some() {
            let _ = fs::remove_file(&self.paths.owner_metadata_file);
        }
    }

    fn write_owner_metadata(&self) {
        let Ok(body) = serde_json::to_vec_pretty(&self.owner) else {
            return;
        };
        let temporary = self
            .paths
            .owner_metadata_file
            .with_extension(format!("tmp-{}", std::process::id()));
        if fs::write(&temporary, body).is_ok() {
            let _ = fs::rename(&temporary, &self.paths.owner_metadata_file);
        } else {
            let _ = fs::remove_file(&temporary);
        }
    }
}

impl Drop for HostLease {
    fn drop(&mut self) {
        self.release();
    }
}

#[must_use]
pub fn read_owner(paths: &HostPaths) -> Option<LeaseOwner> {
    let mut file = File::open(&paths.owner_metadata_file).ok()?;
    let mut body = String::new();
    file.read_to_string(&mut body).ok()?;
    serde_json::from_str(&body).ok()
}

pub fn ensure_directory(path: &Path, mode: u32) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    Ok(())
}

pub fn write_all_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut file = File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::{BuildFlavor, HostPaths};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn scratch_paths() -> HostPaths {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("agentry-lease-{nanos}"));
        HostPaths::from_root(
            root,
            BuildFlavor::Debug,
            1,
            true,
            crate::peer::current_uid(),
        )
    }

    #[test]
    fn second_acquire_is_contended() {
        let paths = scratch_paths();
        let owner = LeaseOwner::rust("host-a", "fp", paths.socket_path.display().to_string());
        let first = match HostLease::acquire(paths.clone(), owner.clone()) {
            LeaseAcquisition::Acquired(lease) => lease,
            other => panic!("expected acquired, got {other:?}"),
        };
        match HostLease::acquire(paths, owner) {
            LeaseAcquisition::Contended { .. } => {}
            other => panic!("expected contended, got {other:?}"),
        }
        drop(first);
    }
}
