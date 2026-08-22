//! Per-root identity maps: the mutable path/id indexes a root owns, plus the discoverability
//! filter and its two O(1) maintained aggregates (§4.3.1.2, D-12).
//!
//! Discoverability predicate (flagged minimal choice: the contract names `isDiscoverableFileID`
//! as an existing Swift predicate (R4) without restating its definition; this module reuses the
//! managed-only exclusion `inventory::builders::build_authoritative_catalog_components` already
//! applies -- "present, and not managed-only" -- since that is the one discoverability rule this
//! step's other reused code already encodes and tests):
//! - `is_discoverable_file(id)`: the id is present in the map and not in the managed-only set.
//! - `is_discoverable_folder(id)`: same, for folders.
//!
//! The two counted aggregates from §4.3.1.2 additionally apply the folder-only root-exclusion:
//! `discoverable_file_count` counts every discoverable file; `discoverable_folder_count` counts
//! every discoverable folder **except** the empty-relative-path root folder, matching
//! `state.folderIDsByRelativePath.count(where: { !relativePath.isEmpty && isDiscoverableFolderID(folderID) })`
//! verbatim. Both are maintained incrementally at every mutation site below, never by a full
//! traversal -- that is the whole point of the aggregate (a traversal-based recount belongs only
//! in the differential test that proves these counters agree with one).

use std::collections::{HashMap, HashSet};

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord, InventoryUuid};

#[derive(Debug, Default)]
pub struct IdentityMaps {
    pub files_by_id: HashMap<InventoryUuid, InventoryFileRecord>,
    pub folders_by_id: HashMap<InventoryUuid, InventoryFolderRecord>,
    pub file_id_by_relative_path: HashMap<String, InventoryUuid>,
    pub folder_id_by_relative_path: HashMap<String, InventoryUuid>,
    pub managed_only_file_ids: HashSet<InventoryUuid>,
    pub managed_only_folder_ids: HashSet<InventoryUuid>,
    discoverable_file_count: usize,
    discoverable_folder_count: usize,
}

impl IdentityMaps {
    #[must_use]
    pub fn is_discoverable_file(&self, id: &InventoryUuid) -> bool {
        self.files_by_id.contains_key(id) && !self.managed_only_file_ids.contains(id)
    }

    #[must_use]
    pub fn is_discoverable_folder(&self, id: &InventoryUuid) -> bool {
        self.folders_by_id.contains_key(id) && !self.managed_only_folder_ids.contains(id)
    }

    #[must_use]
    pub const fn discoverable_file_count(&self) -> usize {
        self.discoverable_file_count
    }

    #[must_use]
    pub const fn discoverable_folder_count(&self) -> usize {
        self.discoverable_folder_count
    }

    fn counted_folder(folder: &InventoryFolderRecord, managed_only: bool) -> bool {
        !folder.standardized_relative_path.is_empty() && !managed_only
    }

    /// Path collision, flagged fix found by the counter-equals-traversal property test during
    /// this step: if a *different* id currently occupies `record`'s target path, that id's
    /// **entire record** is evicted first -- not just its path-index entry. Leaving a
    /// now-path-orphaned record in `files_by_id` would make `is_discoverable_file` (which checks
    /// presence in `files_by_id`) disagree with a traversal over `file_id_by_relative_path`
    /// (which can only ever see one id per path), exactly the drift D-12's differential exists to
    /// catch. Mirrors the P4-2 spike's `apply_single_upsert` collision handling
    /// (`rust/spikes/inventory-scope-spike/src/lib.rs`), generalized from a full-table rebuild to
    /// an incremental identity-map mutation.
    pub fn upsert_file(&mut self, record: InventoryFileRecord) {
        let id = record.id;

        if let Some(&colliding_id) = self
            .file_id_by_relative_path
            .get(&record.standardized_relative_path)
            && colliding_id != id
        {
            self.remove_file(colliding_id);
        }

        let was_discoverable = self.is_discoverable_file(&id);
        if let Some(prior) = self.files_by_id.get(&id)
            && prior.standardized_relative_path != record.standardized_relative_path
        {
            self.file_id_by_relative_path
                .remove(&prior.standardized_relative_path);
        }
        self.file_id_by_relative_path
            .insert(record.standardized_relative_path.clone(), id);
        self.files_by_id.insert(id, record);
        let is_discoverable = self.is_discoverable_file(&id);
        adjust(
            &mut self.discoverable_file_count,
            was_discoverable,
            is_discoverable,
        );
    }

    pub fn remove_file(&mut self, id: InventoryUuid) -> Option<InventoryFileRecord> {
        let was_discoverable = self.is_discoverable_file(&id);
        let removed = self.files_by_id.remove(&id);
        if let Some(record) = &removed {
            self.file_id_by_relative_path
                .remove(&record.standardized_relative_path);
        }
        adjust(&mut self.discoverable_file_count, was_discoverable, false);
        removed
    }

    pub fn set_file_managed_only(&mut self, id: InventoryUuid, managed_only: bool) {
        let was_discoverable = self.is_discoverable_file(&id);
        if managed_only {
            self.managed_only_file_ids.insert(id);
        } else {
            self.managed_only_file_ids.remove(&id);
        }
        let is_discoverable = self.is_discoverable_file(&id);
        adjust(
            &mut self.discoverable_file_count,
            was_discoverable,
            is_discoverable,
        );
    }

    /// Same path-collision fix as `upsert_file`: a different id occupying the target path is
    /// evicted (record and all) before this id claims it.
    pub fn upsert_folder(&mut self, record: InventoryFolderRecord) {
        let id = record.id;

        if let Some(&colliding_id) = self
            .folder_id_by_relative_path
            .get(&record.standardized_relative_path)
            && colliding_id != id
        {
            self.remove_folder(colliding_id);
        }

        let managed_only = self.managed_only_folder_ids.contains(&id);
        let was_counted = self
            .folders_by_id
            .get(&id)
            .is_some_and(|prior| Self::counted_folder(prior, managed_only));
        if let Some(prior) = self.folders_by_id.get(&id)
            && prior.standardized_relative_path != record.standardized_relative_path
        {
            self.folder_id_by_relative_path
                .remove(&prior.standardized_relative_path);
        }
        self.folder_id_by_relative_path
            .insert(record.standardized_relative_path.clone(), id);
        let is_counted = Self::counted_folder(&record, managed_only);
        self.folders_by_id.insert(id, record);
        adjust(&mut self.discoverable_folder_count, was_counted, is_counted);
    }

    pub fn remove_folder(&mut self, id: InventoryUuid) -> Option<InventoryFolderRecord> {
        let managed_only = self.managed_only_folder_ids.contains(&id);
        let was_counted = self
            .folders_by_id
            .get(&id)
            .is_some_and(|prior| Self::counted_folder(prior, managed_only));
        let removed = self.folders_by_id.remove(&id);
        if let Some(record) = &removed {
            self.folder_id_by_relative_path
                .remove(&record.standardized_relative_path);
        }
        adjust(&mut self.discoverable_folder_count, was_counted, false);
        removed
    }

    pub fn set_folder_managed_only(&mut self, id: InventoryUuid, managed_only: bool) {
        let was_counted = self.folders_by_id.get(&id).is_some_and(|prior| {
            Self::counted_folder(prior, self.managed_only_folder_ids.contains(&id))
        });
        if managed_only {
            self.managed_only_folder_ids.insert(id);
        } else {
            self.managed_only_folder_ids.remove(&id);
        }
        let is_counted = self
            .folders_by_id
            .get(&id)
            .is_some_and(|prior| Self::counted_folder(prior, managed_only));
        adjust(&mut self.discoverable_folder_count, was_counted, is_counted);
    }

    /// Recomputes both aggregates from scratch by full traversal. Used **only** by the
    /// counter-equals-traversal differential test (P4-3a done-when) -- never on a mutation path,
    /// since that would defeat the O(1) maintenance the aggregates exist to provide.
    #[must_use]
    pub fn recount_by_traversal(&self) -> (usize, usize) {
        let files = self
            .file_id_by_relative_path
            .values()
            .filter(|id| self.is_discoverable_file(id))
            .count();
        let folders = self
            .folder_id_by_relative_path
            .iter()
            .filter(|(relative_path, id)| {
                !relative_path.is_empty() && self.is_discoverable_folder(id)
            })
            .count();
        (files, folders)
    }
}

fn adjust(counter: &mut usize, was: bool, is: bool) {
    match (was, is) {
        (false, true) => *counter += 1,
        (true, false) => *counter -= 1,
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(id: u8, rel: &str) -> InventoryFileRecord {
        let mut uuid = [0u8; 16];
        uuid[15] = id;
        InventoryFileRecord {
            id: uuid,
            root_id: [0; 16],
            name: rel.to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: format!("/root/{rel}"),
            standardized_full_path: format!("/root/{rel}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    fn folder(id: u8, rel: &str) -> InventoryFolderRecord {
        let mut uuid = [0u8; 16];
        uuid[15] = id;
        InventoryFolderRecord {
            id: uuid,
            root_id: [0; 16],
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
    fn file_count_increments_on_upsert_and_decrements_on_remove() {
        let mut maps = IdentityMaps::default();
        maps.upsert_file(file(1, "a.swift"));
        assert_eq!(maps.discoverable_file_count(), 1);
        maps.upsert_file(file(2, "b.swift"));
        assert_eq!(maps.discoverable_file_count(), 2);
        maps.remove_file(file(1, "a.swift").id);
        assert_eq!(maps.discoverable_file_count(), 1);
    }

    #[test]
    fn managed_only_file_is_excluded_from_count_but_stays_addressable() {
        let mut maps = IdentityMaps::default();
        let record = file(1, "a.swift");
        let id = record.id;
        maps.upsert_file(record);
        assert_eq!(maps.discoverable_file_count(), 1);
        maps.set_file_managed_only(id, true);
        assert_eq!(maps.discoverable_file_count(), 0);
        assert!(maps.files_by_id.contains_key(&id)); // still addressable
        maps.set_file_managed_only(id, false);
        assert_eq!(maps.discoverable_file_count(), 1);
    }

    #[test]
    fn empty_relative_path_root_folder_is_excluded_from_folder_count() {
        let mut maps = IdentityMaps::default();
        maps.upsert_folder(folder(1, "")); // root folder
        assert_eq!(maps.discoverable_folder_count(), 0);
        maps.upsert_folder(folder(2, "src"));
        assert_eq!(maps.discoverable_folder_count(), 1);
    }

    #[test]
    fn path_collision_upsert_moves_index_entry_and_count_stays_correct() {
        let mut maps = IdentityMaps::default();
        maps.upsert_file(file(1, "a.swift"));
        assert_eq!(maps.discoverable_file_count(), 1);
        // Re-add the same id under a different path -- the old path index entry must move, not
        // duplicate, and the count must not drift.
        maps.upsert_file(file(1, "renamed.swift"));
        assert_eq!(maps.discoverable_file_count(), 1);
        assert!(!maps.file_id_by_relative_path.contains_key("a.swift"));
        assert!(maps.file_id_by_relative_path.contains_key("renamed.swift"));
    }

    #[test]
    fn remove_then_re_add_same_path_keeps_count_correct() {
        let mut maps = IdentityMaps::default();
        maps.upsert_file(file(1, "a.swift"));
        maps.remove_file(file(1, "a.swift").id);
        assert_eq!(maps.discoverable_file_count(), 0);
        maps.upsert_file(file(2, "a.swift"));
        assert_eq!(maps.discoverable_file_count(), 1);
    }

    #[test]
    fn traversal_recount_agrees_with_maintained_counters_across_a_mutation_sequence() {
        let mut maps = IdentityMaps::default();
        maps.upsert_file(file(1, "a.swift"));
        maps.upsert_file(file(2, "b.swift"));
        maps.set_file_managed_only(file(2, "b.swift").id, true);
        maps.upsert_folder(folder(3, ""));
        maps.upsert_folder(folder(4, "src"));
        maps.upsert_folder(folder(5, "docs"));
        maps.remove_folder(folder(4, "src").id);
        maps.upsert_file(file(1, "renamed.swift"));
        let (files, folders) = maps.recount_by_traversal();
        assert_eq!(files, maps.discoverable_file_count());
        assert_eq!(folders, maps.discoverable_folder_count());
    }
}
