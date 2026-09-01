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

use crate::inventory::{
    self as builders, InventoryError, InventoryFileRecord, InventoryFolderRecord, InventoryUuid,
};

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

/// A tree projection whose visibility policy is supplied by the caller rather than fixed in Rust
/// (the P4-4 precedent: Swift owns policy definition, Rust owns the data and applies it -- see
/// `InventoryScopeConfig::codemap_capable_extensions`).
///
/// Sourced from `IdentityMaps`, **not** from the published generation, because the published
/// generation is built by `build_authoritative_catalog_components` with managed-only records
/// already filtered out -- they are not there to project. The published generation and the
/// path-search invariant it feeds are therefore completely untouched by this query.
///
/// The policy is expressed as a set of managed-only file ids the caller wants visible anyway;
/// everything else keeps its normal discoverability. Files and folders are filtered independently
/// by the builder, so an included file needs no ancestor-folder fixup.
///
/// The resulting shard carries a real `path_index`: a projected shard is consumed like any other
/// snapshot, via `page`/`query` (see `CoreInventoryScope.openProjectedShard`'s doc comment), so an
/// empty index would silently return zero candidates rather than the rows the caller asked for.
/// A caller-policy projection containing exactly what the caller requested is this query's
/// contract; `managed_only_files_are_never_marked_discoverable_via_resolve` is unaffected because
/// `is_discoverable` is still derived from the maps, never from this shard.
pub fn build_tree_projection_shard(
    root: &RootState,
    included_managed_only_file_ids: &HashSet<InventoryUuid>,
    synthetic_generation: u64,
) -> Result<Arc<RootGeneration>, InventoryError> {
    let mut managed_only_file_ids = root.maps.managed_only_file_ids.clone();
    managed_only_file_ids.retain(|id| !included_managed_only_file_ids.contains(id));
    let mut managed_only_folder_ids = root.maps.managed_only_folder_ids.clone();
    for id in unhidden_ancestor_folder_ids(&root.maps, included_managed_only_file_ids) {
        managed_only_folder_ids.remove(&id);
    }
    let root_record = root.root_record();
    let components = builders::build_authoritative_catalog_components(
        std::slice::from_ref(&root_record),
        &root.maps.files_by_id,
        &root.maps.folders_by_id,
        &managed_only_file_ids,
        &managed_only_folder_ids,
    )?;
    let path_index = Arc::new(RootPathIndex::full(&components.entries));
    Ok(Arc::new(RootGeneration {
        root_id: root_record.id,
        root_lifetime: root.root_lifetime,
        generation: synthetic_generation,
        token: GenerationToken::new(root.root_lifetime, synthetic_generation),
        files: components.files,
        folders: components.folders,
        entries: components.entries,
        path_index,
    }))
}

/// The managed-only folders that must come along when the caller's chosen files are projected:
/// walk each included file's `parent_folder_id` chain and collect every managed-only ancestor.
/// Without this a projected file's parent folder would be missing and the tree could not render it
/// -- this is what `WorkspaceFileContextStore.managedOnlyAncestorFolderIDs` used to compute in
/// Swift. It is derivation over records the runtime already owns, not policy: the caller still
/// decides which *files* are visible, and nothing outside their ancestry is unhidden.
///
/// The `visited` set also terminates a cyclic parent chain, which the record maps do not forbid.
fn unhidden_ancestor_folder_ids(
    maps: &IdentityMaps,
    included_file_ids: &HashSet<InventoryUuid>,
) -> HashSet<InventoryUuid> {
    let mut unhidden = HashSet::new();
    for file_id in included_file_ids {
        let Some(file) = maps.files_by_id.get(file_id) else {
            continue;
        };
        let mut next = file.parent_folder_id;
        while let Some(folder_id) = next {
            if !unhidden.insert(folder_id) {
                break;
            }
            next = maps
                .folders_by_id
                .get(&folder_id)
                .and_then(|folder| folder.parent_folder_id);
        }
    }
    unhidden
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

    fn folder(id: u8, name: &str, relative_path: &str) -> InventoryFolderRecord {
        InventoryFolderRecord {
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

    /// The discriminating case for the caller-policy projection: an explicitly included
    /// managed-only file that lives under a managed-only *folder*. The builder filters files and
    /// folders independently, so the file must project without any ancestor-folder fixup, while
    /// the still-managed-only sibling stays hidden.
    #[test]
    fn tree_projection_includes_requested_managed_only_file_under_a_managed_only_folder() {
        let mut root = new_root();
        root.maps.upsert_folder(folder(2, "build", "build"));
        root.maps.set_folder_managed_only([2; 16], true);
        root.maps.upsert_folder(folder(5, "cache", "cache"));
        root.maps.set_folder_managed_only([5; 16], true);
        // The folder that would expose an over-broad closure: managed-only, and it *has* a
        // managed-only file, just not one the caller asked for. It must stay out, or Swift's
        // "every managed-only folder the projection returned" derivation would over-admit.
        let mut unrelated = file(6, "Stale.swift", "cache/Stale.swift");
        unrelated.parent_folder_id = Some([5; 16]);
        root.maps.upsert_file(unrelated);
        root.maps.set_file_managed_only([6; 16], true);
        let mut wanted = file(3, "Out.swift", "build/Out.swift");
        wanted.parent_folder_id = Some([2; 16]);
        root.maps.upsert_file(wanted);
        root.maps.set_file_managed_only([3; 16], true);
        let mut hidden = file(4, "Other.swift", "build/Other.swift");
        hidden.parent_folder_id = Some([2; 16]);
        root.maps.upsert_file(hidden);
        root.maps.set_file_managed_only([4; 16], true);

        let included: HashSet<InventoryUuid> = [[3; 16]].into_iter().collect();
        let shard = build_tree_projection_shard(&root, &included, 42).expect("projection builds");

        let ids: Vec<_> = shard.files.iter().map(|file| file.id).collect();
        assert_eq!(ids, vec![[3; 16]], "only the requested file projects");
        assert!(
            shard.entries.iter().any(|entry| entry.id == [3; 16]),
            "the requested file must reach the search entries, not just the file list"
        );
        assert_eq!(shard.generation, 42);
        assert_eq!(
            shard.folders.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![[2; 16]],
            "the included file's managed-only ancestor folder must come with it, or the tree has \
             a file whose parent folder does not exist -- and no unrelated managed-only folder \
             may ride along"
        );
    }

    /// The empty policy is the identity case: it must match what the root would publish, so the
    /// query cannot become a second, divergent definition of discoverability.
    #[test]
    fn tree_projection_with_an_empty_policy_hides_every_managed_only_file() {
        let mut root = new_root();
        root.maps.upsert_file(file(3, "App.swift", "src/App.swift"));
        root.maps
            .upsert_file(file(4, "Out.swift", "build/Out.swift"));
        root.maps.set_file_managed_only([4; 16], true);

        let shard =
            build_tree_projection_shard(&root, &HashSet::new(), 1).expect("projection builds");

        let ids: Vec<_> = shard.files.iter().map(|file| file.id).collect();
        assert_eq!(ids, vec![[3; 16]]);
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

#[cfg(test)]
mod perf_probe {
    //! The cost of `build_tree_projection_shard`, which `open_tree_projection_shard` pays inside
    //! `with_state`. Recorded as a runnable probe rather than a prose claim, because the tradeoff
    //! is real but was deliberately left unoptimized:
    //!
    //! ```text
    //! cargo test -p agentry-runtime --lib probe_tree_projection_cost -- --ignored --nocapture
    //! debug, 2026-09-01: n=1000 -> 2.7ms; n=10000 -> 25.4ms; n=50000 -> 147.9ms
    //! ```
    //!
    //! Why it is acceptable: the projection is opened only when the caller's policy is non-empty,
    //! i.e. only when the user has a gitignored file explicitly selected. Every other tree read
    //! stays on the published generation, which is an already-built `Arc` and costs nothing to
    //! open. If this does become a stall, `RootState::snapshot_for_rebuild` is the existing
    //! outside-the-lock pattern to copy -- note it trades the sort for a full map clone, so
    //! measure both before assuming it wins.

    use super::*;
    use crate::inventory_scope::ids::{RootLifetimeId, UuidMinter};
    use crate::inventory_scope::state_machine::RootState;

    #[test]
    #[ignore = "measurement, not an assertion; run explicitly with --ignored --nocapture"]
    fn probe_tree_projection_cost() {
        for n in [1_000usize, 10_000, 50_000] {
            let minter = UuidMinter::seeded(7);
            let lifetime = RootLifetimeId::mint(&minter);
            let mut root =
                RootState::new([1; 16], "root".to_owned(), "/root".to_owned(), lifetime, 8);
            for i in 0..n {
                let mut id = [0u8; 16];
                id[0..8].copy_from_slice(&(i as u64).to_be_bytes());
                root.maps.upsert_file(InventoryFileRecord {
                    id,
                    root_id: [1; 16],
                    name: format!("File{i}.swift"),
                    relative_path: format!("src/dir{}/File{i}.swift", i % 100),
                    standardized_relative_path: format!("src/dir{}/File{i}.swift", i % 100),
                    full_path: format!("/root/src/dir{}/File{i}.swift", i % 100),
                    standardized_full_path: format!("/root/src/dir{}/File{i}.swift", i % 100),
                    parent_folder_id: None,
                    modification_date: None,
                });
            }
            let mut wanted = [0u8; 16];
            wanted[0..8].copy_from_slice(&7u64.to_be_bytes());
            root.maps.set_file_managed_only(wanted, true);
            let included: HashSet<InventoryUuid> = [wanted].into_iter().collect();

            let start = std::time::Instant::now();
            let shard = build_tree_projection_shard(&root, &included, 1).expect("builds");
            let elapsed = start.elapsed();
            println!(
                "n={n}: {:?} ({} files projected)",
                elapsed,
                shard.files.len()
            );
        }
    }
}
