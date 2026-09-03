//! Safe POSIX atomic file persistence for Agentry workspaces.
//!
//! ADR-0012: Safe atomic writes via temporary staging in the target parent directory,
//! permission hardening (0600), non-volatile flush (sync_all), atomic rename(2),
//! and parent directory fsync. Implemented in 100% safe Rust.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use sha2::{Digest, Sha256};

use crate::workspace_persistence_journal::WorkspaceWorkingJournalError;

/// Receipt returned upon a successful atomic disk write.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AtomicWriteReceipt {
    pub bytes_written: usize,
    pub content_digest: String,
    pub directory_sync_warning: Option<String>,
}

/// RAII cleanup guard that removes the temporary file if dropped before commit.
struct TempFileCleanupGuard<'a> {
    path: &'a Path,
    committed: bool,
}

impl<'a> Drop for TempFileCleanupGuard<'a> {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_file(self.path);
        }
    }
}

/// Generates a pseudo-random 16-hex-character nonce without external dependencies.
fn generate_nonce() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let thread_id = format!("{:?}", std::thread::current().id());
    let mut hasher = Sha256::new();
    hasher.update(now.to_le_bytes());
    hasher.update(pid.to_le_bytes());
    hasher.update(thread_id.as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_owned()
}

/// Executes a POSIX atomic write to `destination` with non-volatile flush.
pub fn atomic_write(
    destination: &Path,
    data: &[u8],
    max_bytes: usize,
) -> Result<AtomicWriteReceipt, WorkspaceWorkingJournalError> {
    if data.len() > max_bytes {
        return Err(WorkspaceWorkingJournalError::InputTooLarge {
            actual: data.len(),
            maximum: max_bytes,
        });
    }

    let parent = destination
        .parent()
        .ok_or(WorkspaceWorkingJournalError::InvalidIdentity)?;
    if !parent.exists() {
        std::fs::create_dir_all(parent)
            .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(format!("mkdir_failed: {e}")))?;
    }

    let pid = std::process::id();
    let nonce = generate_nonce();
    let tmp_filename = format!(".tmp.{}.{}", pid, nonce);
    let tmp_path = parent.join(tmp_filename);

    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp_path)
        .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(format!("temp_open_failed: {e}")))?;

    let mut cleanup_guard = TempFileCleanupGuard {
        path: &tmp_path,
        committed: false,
    };

    file.write_all(data)
        .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(format!("write_failed: {e}")))?;

    file.sync_all()
        .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(format!("fsync_failed: {e}")))?;

    drop(file);

    std::fs::rename(&tmp_path, destination)
        .map_err(|e| WorkspaceWorkingJournalError::PersistenceIoError(format!("rename_failed: {e}")))?;

    cleanup_guard.committed = true;

    let directory_sync_warning = match File::open(parent) {
        Ok(dir_file) => {
            if let Err(e) = dir_file.sync_all() {
                Some(format!("directory_fsync_warning: {e}"))
            } else {
                None
            }
        }
        Err(e) => Some(format!("directory_open_warning: {e}")),
    };

    let content_digest = format!("{:x}", Sha256::digest(data));
    Ok(AtomicWriteReceipt {
        bytes_written: data.len(),
        content_digest,
        directory_sync_warning,
    })
}
