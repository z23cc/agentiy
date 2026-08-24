//! `inventoryResolveRecords` / `inventoryLookupPaths` / `inventoryOpenProjectedShard` domain
//! logic (contract doc §5.3/§6). Pure functions over `&RootState` (resolve/lookup) or `&mut
//! RootState` (the projected-shard generation mint); `scope.rs` supplies the lock acquisition and
//! generation-stamp orchestration around them.
//!
//! **Facts, not a verdict (contract doc §5.3).** Re-deriving all 11 B1 call sites found that no
//! single fixed predicate serves them; this module returns the facts a verdict would be built
//! from (`exists`, `isDiscoverable`, `pathRoundTripsToSelf`, `recordFingerprint`, plus the
//! projected path/name fields), never a boolean "passed" field. Output rows are already the wire
//! shape (`wire::FactRow`/`wire::FactBlock`) so `scope.rs` can hand them straight to
//! `wire::encode_fact_block` without an intermediate domain type.

use std::collections::HashSet;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord, InventoryUuid};

use super::generation::RootGeneration;
use super::handles::InvalidationReason;
use super::identity_maps::IdentityMaps;
use super::ids::{GenerationToken, RootLifetimeId};
use super::path_index::RootPathIndex;
use super::state_machine::RootState;
use super::wire::{FactRow, uuid_to_words};

/// `inventoryLookupPaths`'s business-outcome result (see `scope::InventoryScope::lookup_paths`'s
/// doc comment for why this reads live maps rather than a handle-pinned generation, and why an
/// invalidated handle is still a typed outcome here rather than an error).
#[derive(Clone, Debug, PartialEq)]
pub enum LookupPathsOutcome {
    Facts {
        generation: Option<u64>,
        root_lifetime: RootLifetimeId,
        rows: Vec<FactRow>,
    },
    HandleInvalidated {
        reason: InvalidationReason,
    },
}

/// D-11 (contract doc §7): a byte-identity fingerprint over every field an equality check would
/// compare, so a caller holding a captured record can ask "is the authority's current record
/// byte-identical to the copy I'm holding" without shipping the whole record back a second time.
fn fingerprint_file(record: &InventoryFileRecord) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    record.id.hash(&mut hasher);
    record.root_id.hash(&mut hasher);
    record.name.hash(&mut hasher);
    record.relative_path.hash(&mut hasher);
    record.standardized_relative_path.hash(&mut hasher);
    record.full_path.hash(&mut hasher);
    record.standardized_full_path.hash(&mut hasher);
    record.parent_folder_id.hash(&mut hasher);
    record.modification_date.map(f64::to_bits).hash(&mut hasher);
    hasher.finish()
}

fn fingerprint_folder(record: &InventoryFolderRecord) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    record.id.hash(&mut hasher);
    record.root_id.hash(&mut hasher);
    record.name.hash(&mut hasher);
    record.relative_path.hash(&mut hasher);
    record.standardized_relative_path.hash(&mut hasher);
    record.full_path.hash(&mut hasher);
    record.standardized_full_path.hash(&mut hasher);
    record.parent_folder_id.hash(&mut hasher);
    record.modification_date.map(f64::to_bits).hash(&mut hasher);
    hasher.finish()
}

pub(super) fn absent_row(key_hi: u64, key_lo: u64) -> FactRow {
    FactRow {
        key_hi,
        key_lo,
        exists: false,
        file_id: None,
        folder_id: None,
        root_id: None,
        is_discoverable: false,
        path_round_trips_to_self: false,
        standardized_relative_path: None,
        standardized_full_path: None,
        name: None,
        record_fingerprint: 0,
        parent_folder_id: None,
        modification_date: None,
    }
}

fn file_row(
    key_hi: u64,
    key_lo: u64,
    maps: &IdentityMaps,
    id: InventoryUuid,
    record: &InventoryFileRecord,
) -> FactRow {
    let path_round_trips_to_self = maps
        .file_id_by_relative_path
        .get(&record.standardized_relative_path)
        == Some(&id);
    FactRow {
        key_hi,
        key_lo,
        exists: true,
        file_id: Some(id),
        folder_id: None,
        root_id: Some(record.root_id),
        is_discoverable: maps.is_discoverable_file(&id),
        path_round_trips_to_self,
        standardized_relative_path: Some(record.standardized_relative_path.clone()),
        standardized_full_path: Some(record.standardized_full_path.clone()),
        name: Some(record.name.clone()),
        record_fingerprint: fingerprint_file(record),
        parent_folder_id: record.parent_folder_id,
        modification_date: record.modification_date,
    }
}

fn folder_row(
    key_hi: u64,
    key_lo: u64,
    maps: &IdentityMaps,
    id: InventoryUuid,
    record: &InventoryFolderRecord,
) -> FactRow {
    let path_round_trips_to_self = maps
        .folder_id_by_relative_path
        .get(&record.standardized_relative_path)
        == Some(&id);
    FactRow {
        key_hi,
        key_lo,
        exists: true,
        file_id: None,
        folder_id: Some(id),
        root_id: Some(record.root_id),
        is_discoverable: maps.is_discoverable_folder(&id),
        path_round_trips_to_self,
        standardized_relative_path: Some(record.standardized_relative_path.clone()),
        standardized_full_path: Some(record.standardized_full_path.clone()),
        name: Some(record.name.clone()),
        record_fingerprint: fingerprint_folder(record),
        parent_folder_id: record.parent_folder_id,
        modification_date: record.modification_date,
    }
}

/// `inventoryResolveRecords`: batch, binding-validated point lookup by id -- the promotion of
/// `appliedIndexRecordLookup`. `key_hi`/`key_lo` echo the requested id back (the pooled uuid
/// words) so a caller can zip results to its request order without a second lookup.
#[must_use]
pub fn resolve_by_ids(
    root: &RootState,
    file_ids: &[InventoryUuid],
    folder_ids: &[InventoryUuid],
) -> Vec<FactRow> {
    let mut rows = Vec::with_capacity(file_ids.len() + folder_ids.len());
    for &id in file_ids {
        let (hi, lo) = uuid_to_words(&id);
        let row = root.maps.files_by_id.get(&id).map_or_else(
            || absent_row(hi, lo),
            |record| file_row(hi, lo, &root.maps, id, record),
        );
        rows.push(row);
    }
    for &id in folder_ids {
        let (hi, lo) = uuid_to_words(&id);
        let row = root.maps.folders_by_id.get(&id).map_or_else(
            || absent_row(hi, lo),
            |record| folder_row(hi, lo, &root.maps, id, record),
        );
        rows.push(row);
    }
    rows
}

/// `inventoryLookupPaths`: the identical fact shape, keyed by path instead of id. `key_hi` is
/// always `0` and `key_lo` carries the request's positional ordinal (paths are not uuids, and
/// result order already matches request order 1:1, so the ordinal is purely a convenience echo,
/// not a lookup key any decoder needs).
#[must_use]
pub fn lookup_by_paths(root: &RootState, paths: &[String]) -> Vec<FactRow> {
    paths
        .iter()
        .enumerate()
        .map(|(ordinal, path)| {
            let ordinal = ordinal as u64;
            if let Some(&id) = root.maps.file_id_by_relative_path.get(path) {
                root.maps.files_by_id.get(&id).map_or_else(
                    || absent_row(0, ordinal),
                    |record| file_row(0, ordinal, &root.maps, id, record),
                )
            } else if let Some(&id) = root.maps.folder_id_by_relative_path.get(path) {
                root.maps.folders_by_id.get(&id).map_or_else(
                    || absent_row(0, ordinal),
                    |record| folder_row(0, ordinal, &root.maps, id, record),
                )
            } else {
                absent_row(0, ordinal)
            }
        })
        .collect()
}

/// `inventoryOpenProjectedShard` (B2, contract doc §6): the codemap graph-index catalog shard,
/// built authority-side under a caller-supplied codemap-capable extension set. Filters the
/// currently published generation's discoverable files to the extension-matching subset and
/// builds a fresh, `Arc`-retained `RootGeneration`-shaped artifact over just that subset -- the
/// same discoverability filter and (via `RootPathIndex::full`) the same ordering as a normal
/// generation, but never installed into `RootState.published` (a derived, read-only projection,
/// not a new authoritative generation) and consumed the same way, via `inventorySnapshotPage`.
///
/// `synthetic_generation` must come from `RootState::mint_projected_shard_generation` (minted by
/// the caller under the same lock, since minting requires `&mut RootState`) -- see that method's
/// doc comment for why a projected shard cannot reuse the root's real generation number.
#[must_use]
pub fn build_projected_shard(
    root: &RootState,
    extensions: &HashSet<String>,
    synthetic_generation: u64,
) -> Option<Arc<RootGeneration>> {
    let published = root.published.as_ref()?;
    let files: Vec<InventoryFileRecord> = published
        .files
        .iter()
        .filter(|file| {
            root.maps.is_discoverable_file(&file.id)
                && extension_of(&file.name).is_some_and(|extension| extensions.contains(&extension))
        })
        .cloned()
        .collect();
    let kept_ids: HashSet<InventoryUuid> = files.iter().map(|file| file.id).collect();
    let entries: Vec<_> = published
        .entries
        .iter()
        .filter(|entry| kept_ids.contains(&entry.id))
        .cloned()
        .collect();
    let path_index = Arc::new(RootPathIndex::full(&entries));
    Some(Arc::new(RootGeneration {
        root_id: published.root_id,
        root_lifetime: published.root_lifetime,
        generation: synthetic_generation,
        token: GenerationToken::new(published.root_lifetime, synthetic_generation),
        files,
        folders: Vec::new(),
        entries,
        path_index,
    }))
}

fn extension_of(name: &str) -> Option<String> {
    name.rsplit_once('.')
        .map(|(_, extension)| extension.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory_scope::ids::{RootLifetimeId, UuidMinter};
    use crate::inventory_scope::state_machine::RootState;

    fn new_root() -> RootState {
        let minter = UuidMinter::seeded(7);
        let lifetime = RootLifetimeId::mint(&minter);
        RootState::new([1; 16], "root".to_owned(), "/root".to_owned(), lifetime, 8)
    }

    fn file(id: u8, name: &str, relative_path: &str) -> InventoryFileRecord {
        InventoryFileRecord {
            id: [id; 16],
            root_id: [1; 16],
            name: name.to_owned(),
            relative_path: relative_path.to_owned(),
            standardized_relative_path: relative_path.to_owned(),
            full_path: format!("/root/{relative_path}"),
            standardized_full_path: format!("/root/{relative_path}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    #[test]
    fn resolve_by_ids_reports_absent_and_present_facts() {
        let mut root = new_root();
        root.maps.upsert_file(file(1, "App.swift", "src/App.swift"));
        let rows = resolve_by_ids(&root, &[[1; 16], [9; 16]], &[]);
        assert_eq!(rows.len(), 2);
        assert!(rows[0].exists);
        assert_eq!(rows[0].name.as_deref(), Some("App.swift"));
        assert!(!rows[1].exists);
        assert_eq!(rows[1].record_fingerprint, 0);
    }

    #[test]
    fn lookup_by_paths_echoes_ordinal_and_reports_facts_in_request_order() {
        let mut root = new_root();
        root.maps.upsert_file(file(1, "App.swift", "src/App.swift"));
        let rows = lookup_by_paths(
            &root,
            &["missing.swift".to_owned(), "src/App.swift".to_owned()],
        );
        assert_eq!(rows[0].key_lo, 0);
        assert!(!rows[0].exists);
        assert_eq!(rows[1].key_lo, 1);
        assert!(rows[1].exists);
        assert_eq!(rows[1].file_id, Some([1; 16]));
    }

    #[test]
    fn resolve_by_ids_carries_parent_folder_id_and_modification_date() {
        let mut root = new_root();
        let mut record = file(1, "App.swift", "src/App.swift");
        record.parent_folder_id = Some([7; 16]);
        record.modification_date = Some(1_700_000_000.5);
        root.maps.upsert_file(record);
        let rows = resolve_by_ids(&root, &[[1; 16]], &[]);
        assert_eq!(rows[0].parent_folder_id, Some([7; 16]));
        assert_eq!(rows[0].modification_date, Some(1_700_000_000.5));

        let absent = resolve_by_ids(&root, &[[9; 16]], &[]);
        assert_eq!(absent[0].parent_folder_id, None);
        assert_eq!(absent[0].modification_date, None);
    }

    #[test]
    fn managed_only_files_are_never_marked_discoverable_via_resolve() {
        let mut root = new_root();
        root.maps.upsert_file(file(1, "App.swift", "src/App.swift"));
        root.maps.set_file_managed_only([1; 16], true);
        let rows = resolve_by_ids(&root, &[[1; 16]], &[]);
        assert!(rows[0].exists);
        assert!(!rows[0].is_discoverable);
    }

    #[test]
    fn projected_shard_generation_never_collides_with_a_real_publish() {
        let mut root = new_root();
        let synthetic_one = root.mint_projected_shard_generation();
        let synthetic_two = root.mint_projected_shard_generation();
        assert_ne!(synthetic_one, synthetic_two);
        assert!(synthetic_one > u64::MAX - 1_000_000);
        assert!(synthetic_two > u64::MAX - 1_000_000);
    }
}
