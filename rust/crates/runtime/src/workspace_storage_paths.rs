//! Workspace canonical storage path resolution and containment checking.
//!
//! ADR-0012: Defines physical locations for workspace documents, catalog, journals,
//! revisions, deletion tombstones, and authority lock artifacts.

use std::path::{Path, PathBuf};
use crate::workspace_persistence_journal::WorkspaceWorkingJournalError;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkspaceStoragePaths {
    /// Canonical workspace root directory (where Workspace-* directories live)
    pub workspace_root: PathBuf,
    /// Canonical domain runtime directory (where catalogs, journals, revisions, and locks live)
    pub runtime_root: PathBuf,
}

impl WorkspaceStoragePaths {
    /// Constructs canonical layout per ADR-0012 §1.1 / §2.1:
    /// runtime_root = <workspace_root>/.agentry-domain-runtime/
    pub fn canonical(workspace_root: PathBuf) -> Self {
        let workspace_root = workspace_root.canonicalize().unwrap_or(workspace_root);
        let runtime_root = workspace_root.join(".agentry-domain-runtime");
        Self {
            workspace_root,
            runtime_root,
        }
    }

    /// Constructs custom layout with explicit roots.
    pub fn with_roots(workspace_root: PathBuf, runtime_root: PathBuf) -> Self {
        Self {
            workspace_root,
            runtime_root,
        }
    }

    pub fn catalog_path(&self) -> PathBuf {
        self.runtime_root.join("workspace-catalog.json")
    }

    pub fn journal_dir(&self) -> PathBuf {
        self.runtime_root.join("working-journals")
    }

    pub fn journal_path(&self, workspace_id: &str) -> PathBuf {
        self.journal_dir().join(format!("{workspace_id}.json"))
    }

    pub fn pending_journal_path(&self, workspace_id: &str) -> PathBuf {
        self.journal_dir().join(format!("{workspace_id}.journal.pending"))
    }

    pub fn revision_dir(&self) -> PathBuf {
        self.runtime_root.join("revisions")
    }

    pub fn revision_path(&self, workspace_id: &str) -> PathBuf {
        self.revision_dir().join(format!("{workspace_id}.json"))
    }

    pub fn deletion_dir(&self) -> PathBuf {
        self.runtime_root.join("deletion-tombstones")
    }

    pub fn deletion_path(&self, workspace_id: &str) -> PathBuf {
        self.deletion_dir().join(format!("{workspace_id}.json"))
    }

    pub fn lock_dir(&self) -> PathBuf {
        self.runtime_root.join("locks")
    }

    pub fn lease_lock_path(&self) -> PathBuf {
        self.lock_dir().join("workspace-authority-v1.lock")
    }

    pub fn lease_owner_path(&self) -> PathBuf {
        self.lock_dir().join("workspace-authority-owner-v1.json")
    }

    /// Validates strict containment check (ADR-0012 §2.1 Rule 4).
    /// Workspaces whose document path is outside workspace_root cannot be written.
    pub fn contains_document_path(&self, document_path: &Path) -> bool {
        let root = match self.workspace_root.canonicalize() {
            Ok(r) => r,
            Err(_) => self.workspace_root.clone(),
        };

        if let Ok(canonical_doc) = document_path.canonicalize() {
            return canonical_doc.starts_with(&root);
        }

        // If document_path does not exist yet, try to canonicalize its existing parent
        if let Some(parent) = document_path.parent() {
            if let Ok(canon_parent) = parent.canonicalize() {
                if let Some(file_name) = document_path.file_name() {
                    let canon_doc = canon_parent.join(file_name);
                    return canon_doc.starts_with(&root);
                }
            }
        }

        let mut normalized = PathBuf::new();
        for component in document_path.components() {
            match component {
                std::path::Component::Prefix(p) => normalized.push(p.as_os_str()),
                std::path::Component::RootDir => normalized.push("/"),
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    if !normalized.pop() {
                        return false;
                    }
                }
                std::path::Component::Normal(c) => normalized.push(c),
            }
        }

        if let Ok(canon_norm) = normalized.canonicalize() {
            canon_norm.starts_with(&root)
        } else {
            let direct = normalized.starts_with(&root) || normalized.starts_with(&self.workspace_root);
            if direct {
                return true;
            }
            // On macOS /var -> /private/var symlink aliasing
            let with_private = Path::new("/private").join(normalized.strip_prefix("/").unwrap_or(&normalized));
            if with_private.starts_with(&root) {
                return true;
            }
            if let Ok(stripped_root) = root.strip_prefix("/private") {
                if normalized.starts_with(stripped_root) {
                    return true;
                }
            }
            false
        }
    }
}

/// Parses a file:// URL to an absolute PathBuf with percent-decoding.
pub fn parse_file_url_to_path(file_url: &str) -> Result<PathBuf, WorkspaceWorkingJournalError> {
    if !file_url.starts_with("file://") || file_url.as_bytes().contains(&0) {
        return Err(WorkspaceWorkingJournalError::InvalidFileUrl);
    }
    let raw_path = &file_url["file://".len()..];
    let decoded = percent_decode_path(raw_path)
        .map_err(|_| WorkspaceWorkingJournalError::InvalidFileUrl)?;
    Ok(PathBuf::from(decoded))
}

/// Generates the canonical directory name matching Swift `DomainWorkspaceStoragePath.directoryName`:
/// `Workspace-{safeName}-{workspace_id}`.
pub fn default_workspace_directory_name(name: &str, workspace_id: &str) -> String {
    let safe_name = name.replace('/', "_").trim().to_string();
    format!("Workspace-{}-{}", safe_name, workspace_id)
}

fn percent_decode_path(input: &str) -> Result<String, ()> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(());
            }
            let h1 = (bytes[i + 1] as char).to_digit(16).ok_or(())? as u8;
            let h2 = (bytes[i + 2] as char).to_digit(16).ok_or(())? as u8;
            out.push((h1 << 4) | h2);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| ())
}
