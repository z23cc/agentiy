//! Bulk-load staging: `BulkLoadId` abort-vs-commit ordering per
//! `docs/architecture/rust-inventory-scope-v1.md` §5.2.
//!
//! - `begin` opens a staging buffer **invisible** to every read/query/lookup export until commit.
//! - `push_chunk` appends to that private buffer (chunked, never one blocking megacall -- P4-3a
//!   models the chunk as already-typed records; the raw-bytes wire framing is P4-4's job).
//! - `take_for_commit` hands the whole staged root to the caller in one shot, for the caller to
//!   publish as a new generation under **one** critical section -- the 8D atomic root publication
//!   invariant `buildPendingCatalogComponents` exists to serve today, preserved verbatim: this
//!   module does not itself sort/filter/publish, it only owns the staging buffer's lifecycle.
//! - `abort` discards the staging buffer. **A `BulkLoadId` is single-use across its lifecycle**:
//!   once aborted or committed it is terminal (tombstoned, mirroring `OperationRegistry`'s
//!   cancel-before-admission tombstone precedent, `registry.rs`), and any subsequent push, commit,
//!   or abort against the same id is rejected -- there is no "push after abort" path, and no
//!   silent re-open.

use std::collections::HashMap;

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord};

use super::ids::{BulkLoadId, CounterMinter, RootId, RootLifetimeId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BulkLoadError {
    Unknown,
    AlreadyTerminal,
    RootMismatch,
}

#[derive(Debug, Default, PartialEq)]
pub struct BulkLoadStaging {
    pub files: Vec<InventoryFileRecord>,
    pub folders: Vec<InventoryFolderRecord>,
}

enum Entry {
    Staging {
        root_id: RootId,
        root_lifetime: RootLifetimeId,
        staging: BulkLoadStaging,
    },
    Terminal,
}

#[derive(Default)]
pub struct BulkLoadTable {
    minter: CounterMinter,
    entries: HashMap<BulkLoadId, Entry>,
}

impl BulkLoadTable {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn begin(&mut self, root_id: RootId, root_lifetime: RootLifetimeId) -> BulkLoadId {
        let id = BulkLoadId::from_raw(self.minter.next());
        self.entries.insert(
            id,
            Entry::Staging {
                root_id,
                root_lifetime,
                staging: BulkLoadStaging::default(),
            },
        );
        id
    }

    pub fn push_chunk(
        &mut self,
        id: BulkLoadId,
        root_id: RootId,
        files: Vec<InventoryFileRecord>,
        folders: Vec<InventoryFolderRecord>,
    ) -> Result<(), BulkLoadError> {
        match self.entries.get_mut(&id) {
            None => Err(BulkLoadError::Unknown),
            Some(Entry::Terminal) => Err(BulkLoadError::AlreadyTerminal),
            Some(Entry::Staging {
                root_id: staged_root,
                staging,
                ..
            }) => {
                if *staged_root != root_id {
                    return Err(BulkLoadError::RootMismatch);
                }
                staging.files.extend(files);
                staging.folders.extend(folders);
                Ok(())
            }
        }
    }

    /// Terminal transition: takes the staged buffer for the caller to publish, and marks the id
    /// terminal. A subsequent push/commit/abort against this id is rejected.
    pub fn take_for_commit(
        &mut self,
        id: BulkLoadId,
    ) -> Result<(RootId, RootLifetimeId, BulkLoadStaging), BulkLoadError> {
        match self.entries.insert(id, Entry::Terminal) {
            None => {
                self.entries.remove(&id);
                Err(BulkLoadError::Unknown)
            }
            Some(Entry::Terminal) => Err(BulkLoadError::AlreadyTerminal),
            Some(Entry::Staging {
                root_id,
                root_lifetime,
                staging,
            }) => Ok((root_id, root_lifetime, staging)),
        }
    }

    /// Terminal transition: discards the staging buffer. Idempotent-safe in the sense that a
    /// second abort is rejected as `AlreadyTerminal`, not silently accepted -- an abort tombstones
    /// the id the same way a cancel-before-admission tombstones an `OperationId`.
    pub fn abort(&mut self, id: BulkLoadId) -> Result<(), BulkLoadError> {
        match self.entries.insert(id, Entry::Terminal) {
            None => {
                self.entries.remove(&id);
                Err(BulkLoadError::Unknown)
            }
            Some(Entry::Terminal) => Err(BulkLoadError::AlreadyTerminal),
            Some(Entry::Staging { .. }) => Ok(()),
        }
    }

    /// Aborts every still-staging bulk load open against `root_id` -- used by `close_root` so a
    /// root close cannot leave a dangling staging buffer referencing an unloaded root.
    pub fn abort_all_for_root(&mut self, root_id: RootId) {
        let doomed: Vec<BulkLoadId> = self
            .entries
            .iter()
            .filter_map(|(id, entry)| match entry {
                Entry::Staging {
                    root_id: staged_root,
                    ..
                } if *staged_root == root_id => Some(*id),
                _ => None,
            })
            .collect();
        for id in doomed {
            self.entries.insert(id, Entry::Terminal);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(id: [u8; 16], root_id: RootId, rel: &str) -> InventoryFileRecord {
        InventoryFileRecord {
            id,
            root_id,
            name: rel.to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: format!("/root/{rel}"),
            standardized_full_path: format!("/root/{rel}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    #[test]
    fn staged_rows_are_only_visible_via_take_for_commit() {
        let mut table = BulkLoadTable::new();
        let root: RootId = [1; 16];
        let lifetime = RootLifetimeId::from_bytes([9; 16]);
        let id = table.begin(root, lifetime);
        table
            .push_chunk(id, root, vec![file([2; 16], root, "a.swift")], vec![])
            .expect("push");
        let (_, _, staging) = table.take_for_commit(id).expect("commit");
        assert_eq!(staging.files.len(), 1);
    }

    #[test]
    fn push_after_abort_is_rejected_not_silently_accepted() {
        let mut table = BulkLoadTable::new();
        let root: RootId = [1; 16];
        let lifetime = RootLifetimeId::from_bytes([9; 16]);
        let id = table.begin(root, lifetime);
        table.abort(id).expect("abort");
        assert_eq!(
            table.push_chunk(id, root, vec![file([2; 16], root, "a.swift")], vec![]),
            Err(BulkLoadError::AlreadyTerminal)
        );
        assert_eq!(
            table.take_for_commit(id),
            Err(BulkLoadError::AlreadyTerminal)
        );
        assert_eq!(table.abort(id), Err(BulkLoadError::AlreadyTerminal));
    }

    #[test]
    fn double_commit_is_rejected() {
        let mut table = BulkLoadTable::new();
        let root: RootId = [1; 16];
        let lifetime = RootLifetimeId::from_bytes([9; 16]);
        let id = table.begin(root, lifetime);
        table.take_for_commit(id).expect("first commit");
        assert_eq!(
            table.take_for_commit(id),
            Err(BulkLoadError::AlreadyTerminal)
        );
        assert_eq!(table.abort(id), Err(BulkLoadError::AlreadyTerminal));
    }

    #[test]
    fn unknown_id_is_rejected_distinctly() {
        let mut table = BulkLoadTable::new();
        let bogus = BulkLoadId::from_raw(999);
        assert_eq!(table.abort(bogus), Err(BulkLoadError::Unknown));
        assert_eq!(table.take_for_commit(bogus), Err(BulkLoadError::Unknown));
    }

    #[test]
    fn abort_all_for_root_only_touches_that_roots_staging_loads() {
        let mut table = BulkLoadTable::new();
        let root_a: RootId = [1; 16];
        let root_b: RootId = [2; 16];
        let lifetime = RootLifetimeId::from_bytes([9; 16]);
        let load_a = table.begin(root_a, lifetime);
        let load_b = table.begin(root_b, lifetime);
        table.abort_all_for_root(root_a);
        assert_eq!(
            table.take_for_commit(load_a),
            Err(BulkLoadError::AlreadyTerminal)
        );
        assert!(table.take_for_commit(load_b).is_ok());
    }
}
