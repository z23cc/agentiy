//! Byte-exact port of
//! `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Inventory/WorkspaceInventoryCatalogBuilders.swift`.
//!
//! DO NOT change comparison semantics, sort order, or the single-logical-mutation patch behavior
//! here — this is preserved verbatim from the Swift source (P3-1 extraction, P3-2 port).

use super::ordering;
use std::collections::{HashMap, HashSet};

/// Raw 16-byte UUID, matching Swift `UUID.uuid: uuid_t` byte layout in RFC 4122 field order.
/// Comparing these arrays lexicographically agrees with comparing canonical lowercase
/// `uuidString` values (pinned by `ordering::tests::uuid_byte_order_matches_canonical_string_order`).
pub type InventoryUuid = [u8; 16];

/// Port of `WorkspaceRootRecord`, restricted to the fields the catalog builders actually read:
/// `id`, `name`, `standardizedFullPath`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InventoryRootRecord {
    pub id: InventoryUuid,
    pub name: String,
    pub standardized_full_path: String,
}

/// Port of `WorkspaceFileRecord` / `WorkspaceFolderRecord`, which share an identical
/// nine-field `Equatable` shape. Every field participates in the Swift-synthesized `==` used by
/// `buildRootCatalogShardPatch`'s `filesByID[$0.id] == $0` / `foldersByID[$0.id] == $0` checks, so
/// all nine are ported (not just the fields the ordering/lookup logic reads) to preserve that
/// equality's parity.
#[derive(Clone, Debug, PartialEq)]
pub struct InventoryFileRecord {
    pub id: InventoryUuid,
    pub root_id: InventoryUuid,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub parent_folder_id: Option<InventoryUuid>,
    /// `Date?.timeIntervalSinceReferenceDate`. Must not be `NaN` (equality/order is undefined
    /// for `NaN` on both sides and the differential test must not generate it).
    pub modification_date: Option<f64>,
}

/// See `InventoryFileRecord` doc comment: identical shape, ported for `WorkspaceFolderRecord`.
#[derive(Clone, Debug, PartialEq)]
pub struct InventoryFolderRecord {
    pub id: InventoryUuid,
    pub root_id: InventoryUuid,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub parent_folder_id: Option<InventoryUuid>,
    pub modification_date: Option<f64>,
}

/// Port of `WorkspaceSearchCatalogEntry`.
#[derive(Clone, Debug, PartialEq)]
pub struct InventorySearchCatalogEntry {
    pub id: InventoryUuid,
    pub root_id: InventoryUuid,
    pub root_path: String,
    pub root_name: String,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub display_path: String,
}

impl InventorySearchCatalogEntry {
    /// Port of `WorkspaceSearchCatalogEntry.init(file:root:displayPath:)` with `displayPath: nil`
    /// (the only form the catalog builders use).
    pub fn new(file: &InventoryFileRecord, root: &InventoryRootRecord) -> Self {
        let display_path = Self::default_display_path(file, root);
        Self {
            id: file.id,
            root_id: file.root_id,
            root_path: root.standardized_full_path.clone(),
            root_name: root.name.clone(),
            name: file.name.clone(),
            relative_path: file.relative_path.clone(),
            standardized_relative_path: file.standardized_relative_path.clone(),
            full_path: file.full_path.clone(),
            standardized_full_path: file.standardized_full_path.clone(),
            display_path,
        }
    }

    fn default_display_path(file: &InventoryFileRecord, root: &InventoryRootRecord) -> String {
        if file.standardized_relative_path.is_empty() {
            return root.name.clone();
        }
        format!("{}/{}", root.name, file.standardized_relative_path)
    }
}

/// Port of `WorkspaceAppliedIndexBatchEvent`, restricted to the fields
/// `buildRootCatalogShardPatch` reads.
#[derive(Clone, Debug, PartialEq)]
pub struct InventoryAppliedIndexBatchEvent {
    pub root_id: InventoryUuid,
    pub upserted_files: Vec<InventoryFileRecord>,
    pub upserted_folders: Vec<InventoryFolderRecord>,
    pub removed_file_ids: Vec<InventoryUuid>,
    pub removed_folder_ids: Vec<InventoryUuid>,
    /// Raw (not yet standardized) paths, matching Swift's `[String]` field — standardization is
    /// applied inside the builder via `standardized_relative_path`, mirroring
    /// `event.removedFilePaths.map(StandardizedPath.relative)`.
    pub removed_file_paths: Vec<String>,
    pub removed_folder_paths: Vec<String>,
    pub modified_file_ids: Vec<InventoryUuid>,
    pub modified_folder_ids: Vec<InventoryUuid>,
}

/// Port of `WorkspaceInventoryCatalogComponents`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InventoryCatalogComponents {
    pub files: Vec<InventoryFileRecord>,
    pub folders: Vec<InventoryFolderRecord>,
    pub entries: Vec<InventorySearchCatalogEntry>,
}

/// Port of `WorkspaceInventoryCatalogShardPatch`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InventoryCatalogShardPatch {
    pub files: Vec<InventoryFileRecord>,
    pub folders: Vec<InventoryFolderRecord>,
    pub logical_mutation_count: usize,
    pub path_index_changed_file_ids: HashSet<InventoryUuid>,
}

/// Errors that indicate malformed input the Swift builders cannot represent as a normal `nil`
/// return (Swift traps instead, e.g. `Dictionary(uniqueKeysWithValues:)` on a duplicate key).
/// These are decode-time/precondition failures, not the `buildRootCatalogShardPatch` "not
/// patchable" business outcome (see `InventoryError` vs. the `Option` return of
/// `build_root_catalog_shard_patch`).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InventoryError {
    DuplicateRootId,
    DuplicateFileId,
    DuplicateFolderId,
}

impl std::fmt::Display for InventoryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateRootId => formatter.write_str("duplicate root id"),
            Self::DuplicateFileId => formatter.write_str("duplicate file id"),
            Self::DuplicateFolderId => formatter.write_str("duplicate folder id"),
        }
    }
}
impl std::error::Error for InventoryError {}

/// Port of `StandardizedPath.relative(_:)` (`RepoPromptWorkspaceCore/StandardizedPath.swift`),
/// needed to standardize `WorkspaceAppliedIndexBatchEvent.removedFilePaths`/`removedFolderPaths`,
/// which arrive raw.
pub fn standardized_relative_path(path: &str) -> String {
    let trimmed = path.trim_matches('/');
    if trimmed.is_empty() || trimmed == "." {
        return String::new();
    }
    let mut components: Vec<&str> = Vec::new();
    for component in trimmed.split('/').filter(|part| !part.is_empty()) {
        match component {
            "." => continue,
            ".." => {
                if let Some(&last) = components.last() {
                    if last != ".." {
                        components.pop();
                    } else {
                        components.push(component);
                    }
                } else {
                    components.push(component);
                }
            }
            _ => components.push(component),
        }
    }
    components.join("/")
}

/// Port of `WorkspaceInventoryCatalogBuilders.buildAuthoritativeCatalogComponents`.
pub fn build_authoritative_catalog_components(
    roots: &[InventoryRootRecord],
    files_by_id: &HashMap<InventoryUuid, InventoryFileRecord>,
    folders_by_id: &HashMap<InventoryUuid, InventoryFolderRecord>,
    managed_only_file_ids: &HashSet<InventoryUuid>,
    managed_only_folder_ids: &HashSet<InventoryUuid>,
) -> Result<InventoryCatalogComponents, InventoryError> {
    let mut roots_by_id: HashMap<InventoryUuid, &InventoryRootRecord> =
        HashMap::with_capacity(roots.len());
    for root in roots {
        if roots_by_id.insert(root.id, root).is_some() {
            return Err(InventoryError::DuplicateRootId);
        }
    }
    let allowed_root_ids: HashSet<InventoryUuid> = roots_by_id.keys().copied().collect();

    let mut files: Vec<InventoryFileRecord> = files_by_id
        .values()
        .filter(|file| {
            allowed_root_ids.contains(&file.root_id) && !managed_only_file_ids.contains(&file.id)
        })
        .cloned()
        .collect();
    if roots.len() == 1 {
        files.sort_by(ordering::file_relative_path_order);
    } else {
        files.sort_by(ordering::file_full_path_order);
    }

    let mut folders: Vec<InventoryFolderRecord> = folders_by_id
        .values()
        .filter(|folder| {
            allowed_root_ids.contains(&folder.root_id)
                && !managed_only_folder_ids.contains(&folder.id)
        })
        .cloned()
        .collect();
    folders.sort_by(ordering::folder_order);

    let entries: Vec<InventorySearchCatalogEntry> = files
        .iter()
        .filter_map(|file| {
            roots_by_id
                .get(&file.root_id)
                .map(|root| InventorySearchCatalogEntry::new(file, root))
        })
        .collect();

    Ok(InventoryCatalogComponents {
        files,
        folders,
        entries,
    })
}

/// Port of `WorkspaceInventoryCatalogBuilders.buildPendingCatalogComponents`.
///
/// Verbatim behavior preserved: every file/folder in `files_by_id`/`folders_by_id` is mapped
/// against the single `root` argument regardless of its own `root_id` (the Swift source ignores
/// `rootID` entirely here — do not "fix" this by filtering on `root.id`).
pub fn build_pending_catalog_components(
    root: &InventoryRootRecord,
    files_by_id: &HashMap<InventoryUuid, InventoryFileRecord>,
    folders_by_id: &HashMap<InventoryUuid, InventoryFolderRecord>,
) -> InventoryCatalogComponents {
    let mut files: Vec<InventoryFileRecord> = files_by_id.values().cloned().collect();
    files.sort_by(ordering::file_relative_path_order);

    let mut folders: Vec<InventoryFolderRecord> = folders_by_id.values().cloned().collect();
    folders.sort_by(ordering::folder_order);

    let entries: Vec<InventorySearchCatalogEntry> = files
        .iter()
        .map(|file| InventorySearchCatalogEntry::new(file, root))
        .collect();

    InventoryCatalogComponents {
        files,
        folders,
        entries,
    }
}

fn insert_file_sorted(file: InventoryFileRecord, files: &mut Vec<InventoryFileRecord>) {
    let index = files
        .partition_point(|existing| ordering::search_root_catalog_file_precedes(existing, &file));
    files.insert(index, file);
}

fn insert_folder_sorted(folder: InventoryFolderRecord, folders: &mut Vec<InventoryFolderRecord>) {
    let index = folders
        .partition_point(|existing| ordering::search_catalog_folder_precedes(existing, &folder));
    folders.insert(index, folder);
}

/// Port of `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`.
///
/// Returns `Ok(None)` for every Swift `return nil` business outcome (event cannot be safely
/// applied as a patch — caller must fall back to an authoritative rebuild). Returns `Err` only
/// for malformed input the Swift source cannot represent as `nil` because it would instead trap
/// (a duplicate id inside `previousFiles`/`previousFolders`, which a well-formed shard never has).
///
/// NOTE: only ever applies a single logical mutation (first of `touchedFileIDs`/`touchedFolderIDs`)
/// — existing behavior guarded by `max_logical_mutation_count` (1 at the only Swift call site).
/// Preserved verbatim; callers/tests must keep `max_logical_mutation_count == 1` for the `.first`
/// pick to be deterministic (see ordering/parity notes in the P3-2 report).
#[allow(clippy::too_many_lines)]
pub fn build_root_catalog_shard_patch(
    event: &InventoryAppliedIndexBatchEvent,
    previous_files: &[InventoryFileRecord],
    previous_folders: &[InventoryFolderRecord],
    files_by_id: &HashMap<InventoryUuid, InventoryFileRecord>,
    folders_by_id: &HashMap<InventoryUuid, InventoryFolderRecord>,
    max_logical_mutation_count: usize,
) -> Result<Option<InventoryCatalogShardPatch>, InventoryError> {
    let mut old_files_by_id: HashMap<InventoryUuid, &InventoryFileRecord> =
        HashMap::with_capacity(previous_files.len());
    for file in previous_files {
        if old_files_by_id.insert(file.id, file).is_some() {
            return Err(InventoryError::DuplicateFileId);
        }
    }
    let mut old_file_ids_by_path: HashMap<&str, InventoryUuid> = HashMap::new();
    for file in previous_files {
        old_file_ids_by_path
            .entry(file.standardized_relative_path.as_str())
            .or_insert(file.id);
    }

    let mut old_folders_by_id: HashMap<InventoryUuid, &InventoryFolderRecord> =
        HashMap::with_capacity(previous_folders.len());
    for folder in previous_folders {
        if old_folders_by_id.insert(folder.id, folder).is_some() {
            return Err(InventoryError::DuplicateFolderId);
        }
    }
    let mut old_folder_ids_by_path: HashMap<&str, InventoryUuid> = HashMap::new();
    for folder in previous_folders {
        old_folder_ids_by_path
            .entry(folder.standardized_relative_path.as_str())
            .or_insert(folder.id);
    }

    let mut upserted_files_by_id: HashMap<InventoryUuid, &InventoryFileRecord> = HashMap::new();
    for file in &event.upserted_files {
        upserted_files_by_id.insert(file.id, file);
    }
    let mut upserted_folders_by_id: HashMap<InventoryUuid, &InventoryFolderRecord> = HashMap::new();
    for folder in &event.upserted_folders {
        upserted_folders_by_id.insert(folder.id, folder);
    }
    if upserted_files_by_id.len() != event.upserted_files.len()
        || upserted_folders_by_id.len() != event.upserted_folders.len()
        || !event
            .upserted_files
            .iter()
            .all(|file| file.root_id == event.root_id && files_by_id.get(&file.id) == Some(file))
        || !event.upserted_folders.iter().all(|folder| {
            folder.root_id == event.root_id && folders_by_id.get(&folder.id) == Some(folder)
        })
    {
        return Ok(None);
    }

    let represented_folder_ids: HashSet<InventoryUuid> = old_folders_by_id
        .keys()
        .copied()
        .chain(upserted_folders_by_id.keys().copied())
        .collect();
    for file in upserted_files_by_id.values() {
        let mut parent_folder_id = file.parent_folder_id;
        while let Some(folder_id) = parent_folder_id {
            if !represented_folder_ids.contains(&folder_id) {
                return Ok(None);
            }
            match folders_by_id.get(&folder_id) {
                Some(folder) => parent_folder_id = folder.parent_folder_id,
                None => return Ok(None),
            }
        }
    }

    let removed_file_ids: HashSet<InventoryUuid> = event.removed_file_ids.iter().copied().collect();
    let removed_folder_ids: HashSet<InventoryUuid> =
        event.removed_folder_ids.iter().copied().collect();
    let removed_file_paths: HashSet<String> = event
        .removed_file_paths
        .iter()
        .map(|path| standardized_relative_path(path))
        .collect();
    let removed_folder_paths: HashSet<String> = event
        .removed_folder_paths
        .iter()
        .map(|path| standardized_relative_path(path))
        .collect();
    let modified_file_ids: HashSet<InventoryUuid> =
        event.modified_file_ids.iter().copied().collect();
    let modified_folder_ids: HashSet<InventoryUuid> =
        event.modified_folder_ids.iter().copied().collect();
    if removed_file_ids.len() != event.removed_file_ids.len()
        || removed_folder_ids.len() != event.removed_folder_ids.len()
        || modified_file_ids.len() != event.modified_file_ids.len()
        || modified_folder_ids.len() != event.modified_folder_ids.len()
        || !modified_file_ids
            .iter()
            .all(|id| files_by_id.get(id).map(|file| file.root_id) == Some(event.root_id))
        || !modified_folder_ids
            .iter()
            .all(|id| folders_by_id.get(id).map(|folder| folder.root_id) == Some(event.root_id))
    {
        return Ok(None);
    }

    let mut touched_file_ids: HashSet<InventoryUuid> =
        upserted_files_by_id.keys().copied().collect();
    let mut touched_folder_ids: HashSet<InventoryUuid> =
        upserted_folders_by_id.keys().copied().collect();
    for id in &removed_file_ids {
        if !old_files_by_id.contains_key(id) {
            return Ok(None);
        }
        touched_file_ids.insert(*id);
    }
    for path in &removed_file_paths {
        match old_file_ids_by_path.get(path.as_str()) {
            Some(id) => {
                touched_file_ids.insert(*id);
            }
            None => return Ok(None),
        }
    }
    for id in &modified_file_ids {
        if !old_files_by_id.contains_key(id) {
            return Ok(None);
        }
        touched_file_ids.insert(*id);
    }
    for id in &removed_folder_ids {
        if !old_folders_by_id.contains_key(id) {
            return Ok(None);
        }
        touched_folder_ids.insert(*id);
    }
    for path in &removed_folder_paths {
        match old_folder_ids_by_path.get(path.as_str()) {
            Some(id) => {
                touched_folder_ids.insert(*id);
            }
            None => return Ok(None),
        }
    }
    for id in &modified_folder_ids {
        if !old_folders_by_id.contains_key(id) {
            return Ok(None);
        }
        touched_folder_ids.insert(*id);
    }

    let upserted_file_paths: HashSet<String> = upserted_files_by_id
        .values()
        .map(|file| file.standardized_relative_path.clone())
        .collect();
    let upserted_folder_paths: HashSet<String> = upserted_folders_by_id
        .values()
        .map(|folder| folder.standardized_relative_path.clone())
        .collect();
    let mut path_index_changed_file_ids = touched_file_ids.clone();
    for path in removed_file_paths.union(&upserted_file_paths) {
        if let Some(old_file_id) = old_file_ids_by_path.get(path.as_str()) {
            path_index_changed_file_ids.insert(*old_file_id);
        }
    }
    if !removed_file_ids.is_disjoint(&upserted_files_by_id.keys().copied().collect())
        || !removed_folder_ids.is_disjoint(&upserted_folders_by_id.keys().copied().collect())
        || !removed_file_paths.is_disjoint(&upserted_file_paths)
        || !removed_folder_paths.is_disjoint(&upserted_folder_paths)
        || !modified_file_ids.is_disjoint(&removed_file_ids)
        || !modified_folder_ids.is_disjoint(&removed_folder_ids)
    {
        return Ok(None);
    }

    let logical_mutation_count = touched_file_ids.len() + touched_folder_ids.len();
    if logical_mutation_count > max_logical_mutation_count {
        return Ok(Some(InventoryCatalogShardPatch {
            files: previous_files.to_vec(),
            folders: previous_folders.to_vec(),
            logical_mutation_count,
            path_index_changed_file_ids: HashSet::new(),
        }));
    }

    let mut files = previous_files.to_vec();
    if let Some(&touched_file_id) = touched_file_ids.iter().next() {
        files.retain(|file| {
            file.id != touched_file_id
                && !removed_file_paths.contains(&file.standardized_relative_path)
                && !upserted_file_paths.contains(&file.standardized_relative_path)
        });
        if let Some(upserted) = upserted_files_by_id.get(&touched_file_id) {
            insert_file_sorted((*upserted).clone(), &mut files);
        } else if modified_file_ids.contains(&touched_file_id) {
            if let Some(modified) = files_by_id.get(&touched_file_id) {
                insert_file_sorted(modified.clone(), &mut files);
            }
        }
    }

    let mut folders = previous_folders.to_vec();
    if let Some(&touched_folder_id) = touched_folder_ids.iter().next() {
        folders.retain(|folder| {
            folder.id != touched_folder_id
                && !removed_folder_paths.contains(&folder.standardized_relative_path)
                && !upserted_folder_paths.contains(&folder.standardized_relative_path)
        });
        if let Some(upserted) = upserted_folders_by_id.get(&touched_folder_id) {
            insert_folder_sorted((*upserted).clone(), &mut folders);
        } else if modified_folder_ids.contains(&touched_folder_id) {
            if let Some(modified) = folders_by_id.get(&touched_folder_id) {
                insert_folder_sorted(modified.clone(), &mut folders);
            }
        }
    }

    Ok(Some(InventoryCatalogShardPatch {
        files,
        folders,
        logical_mutation_count,
        path_index_changed_file_ids,
    }))
}

/// Port of `WorkspaceInventoryCatalogBuilders.mergeRootCatalogShardFileEntryLists`.
///
/// Each `shards[i]` is `(files, entries)` — already sorted by
/// `ordering::file_full_path_order`/`entry_order` and index-aligned (`entries[j]` corresponds to
/// `files[j]`). The Swift source performs a k-way heap merge; since its own tiebreak
/// (`shardIndex`, `elementIndex`) is already a total order once combined with the file
/// comparator's own uuid tiebreak, a single stable sort over `(shard_index, element_index)`
/// produces an identical result without replicating the heap (see P3-2 report).
pub fn merge_root_catalog_shard_file_entry_lists(
    shards: &[(Vec<InventoryFileRecord>, Vec<InventorySearchCatalogEntry>)],
) -> (Vec<InventoryFileRecord>, Vec<InventorySearchCatalogEntry>) {
    let mut cursors: Vec<(usize, usize)> = Vec::new();
    for (shard_index, (files, _entries)) in shards.iter().enumerate() {
        for element_index in 0..files.len() {
            cursors.push((shard_index, element_index));
        }
    }
    cursors.sort_by(|&(shard_a, element_a), &(shard_b, element_b)| {
        let file_a = &shards[shard_a].0[element_a];
        let file_b = &shards[shard_b].0[element_b];
        match ordering::file_full_path_order(file_a, file_b) {
            std::cmp::Ordering::Equal => (shard_a, element_a).cmp(&(shard_b, element_b)),
            other => other,
        }
    });
    let mut files = Vec::with_capacity(cursors.len());
    let mut entries = Vec::with_capacity(cursors.len());
    for (shard_index, element_index) in cursors {
        files.push(shards[shard_index].0[element_index].clone());
        entries.push(shards[shard_index].1[element_index].clone());
    }
    (files, entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(byte: u8) -> InventoryUuid {
        let mut bytes = [0u8; 16];
        bytes[15] = byte;
        bytes
    }

    fn root(id: InventoryUuid, name: &str, path: &str) -> InventoryRootRecord {
        InventoryRootRecord {
            id,
            name: name.to_owned(),
            standardized_full_path: path.to_owned(),
        }
    }

    fn file(
        id: InventoryUuid,
        root_id: InventoryUuid,
        rel: &str,
        full: &str,
        parent: Option<InventoryUuid>,
    ) -> InventoryFileRecord {
        InventoryFileRecord {
            id,
            root_id,
            name: rel.rsplit('/').next().unwrap_or(rel).to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: full.to_owned(),
            standardized_full_path: full.to_owned(),
            parent_folder_id: parent,
            modification_date: None,
        }
    }

    fn folder(
        id: InventoryUuid,
        root_id: InventoryUuid,
        rel: &str,
        full: &str,
        parent: Option<InventoryUuid>,
    ) -> InventoryFolderRecord {
        InventoryFolderRecord {
            id,
            root_id,
            name: rel.rsplit('/').next().unwrap_or(rel).to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: full.to_owned(),
            standardized_full_path: full.to_owned(),
            parent_folder_id: parent,
            modification_date: None,
        }
    }

    #[test]
    fn standardized_relative_path_matches_swift_cases() {
        assert_eq!(standardized_relative_path(""), "");
        assert_eq!(standardized_relative_path("."), "");
        assert_eq!(standardized_relative_path("/"), "");
        assert_eq!(standardized_relative_path("a/b/c"), "a/b/c");
        assert_eq!(standardized_relative_path("/a/b/c/"), "a/b/c");
        assert_eq!(standardized_relative_path("a/./b"), "a/b");
        assert_eq!(standardized_relative_path("a/b/.."), "a");
        assert_eq!(standardized_relative_path("../a/b"), "../a/b");
        assert_eq!(standardized_relative_path("a/../../b"), "../b");
        assert_eq!(standardized_relative_path("a//b"), "a/b");
    }

    #[test]
    fn authoritative_single_root_uses_relative_ordering_and_filters_managed_only() {
        let root_id = uuid(1);
        let roots = vec![root(root_id, "Root", "/root")];
        let mut files = HashMap::new();
        let f1 = file(uuid(10), root_id, "z.swift", "/root/z.swift", None);
        let f2 = file(uuid(11), root_id, "a.swift", "/root/a.swift", None);
        let f3_managed = file(uuid(12), root_id, "m.swift", "/root/m.swift", None);
        files.insert(f1.id, f1.clone());
        files.insert(f2.id, f2.clone());
        files.insert(f3_managed.id, f3_managed.clone());
        let folders = HashMap::new();
        let managed_only_files: HashSet<_> = [f3_managed.id].into_iter().collect();

        let components = build_authoritative_catalog_components(
            &roots,
            &files,
            &folders,
            &managed_only_files,
            &HashSet::new(),
        )
        .expect("no duplicate ids");

        assert_eq!(
            components.files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![f2.id, f1.id]
        );
        assert_eq!(components.entries.len(), 2);
        assert_eq!(components.entries[0].display_path, "Root/a.swift");
    }

    #[test]
    fn authoritative_multi_root_uses_full_path_ordering() {
        let root_a = uuid(1);
        let root_b = uuid(2);
        let roots = vec![root(root_a, "A", "/a"), root(root_b, "B", "/b")];
        let mut files = HashMap::new();
        let fa = file(uuid(10), root_a, "z.swift", "/a/z.swift", None);
        let fb = file(uuid(11), root_b, "a.swift", "/b/a.swift", None);
        files.insert(fa.id, fa.clone());
        files.insert(fb.id, fb.clone());
        let components = build_authoritative_catalog_components(
            &roots,
            &files,
            &HashMap::new(),
            &HashSet::new(),
            &HashSet::new(),
        )
        .unwrap();
        // Full path order: "/a/z.swift" < "/b/a.swift".
        assert_eq!(
            components.files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![fa.id, fb.id]
        );
    }

    #[test]
    fn pending_catalog_ignores_root_id_mismatch() {
        let listed_root = root(uuid(1), "Listed", "/listed");
        let mut files = HashMap::new();
        // File's own root_id does not match `listed_root.id` — Swift still maps it against
        // `root` regardless, and so must the port.
        let f = file(uuid(10), uuid(99), "a.swift", "/other/a.swift", None);
        files.insert(f.id, f.clone());
        let components = build_pending_catalog_components(&listed_root, &files, &HashMap::new());
        assert_eq!(components.entries.len(), 1);
        assert_eq!(components.entries[0].root_path, "/listed");
        assert_eq!(components.entries[0].display_path, "Listed/a.swift");
    }

    #[test]
    fn shard_patch_upserts_single_new_file_at_sorted_position() {
        let root_id = uuid(1);
        let existing = file(uuid(10), root_id, "b.swift", "/root/b.swift", None);
        let previous_files = vec![existing.clone()];
        let new_file = file(uuid(11), root_id, "a.swift", "/root/a.swift", None);
        let mut files_by_id = HashMap::new();
        files_by_id.insert(new_file.id, new_file.clone());
        files_by_id.insert(existing.id, existing.clone());

        let event = InventoryAppliedIndexBatchEvent {
            root_id,
            upserted_files: vec![new_file.clone()],
            upserted_folders: vec![],
            removed_file_ids: vec![],
            removed_folder_ids: vec![],
            removed_file_paths: vec![],
            removed_folder_paths: vec![],
            modified_file_ids: vec![],
            modified_folder_ids: vec![],
        };

        let patch = build_root_catalog_shard_patch(
            &event,
            &previous_files,
            &[],
            &files_by_id,
            &HashMap::new(),
            1,
        )
        .expect("no duplicate ids")
        .expect("patchable");

        assert_eq!(
            patch.files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![new_file.id, existing.id]
        );
        assert_eq!(patch.logical_mutation_count, 1);
        assert!(patch.path_index_changed_file_ids.contains(&new_file.id));
    }

    #[test]
    fn shard_patch_upserts_single_new_folder_at_sorted_position() {
        let root_id = uuid(1);
        let existing = folder(uuid(20), root_id, "b", "/root/b", None);
        let previous_folders = vec![existing.clone()];
        let new_folder = folder(uuid(21), root_id, "a", "/root/a", None);
        let mut folders_by_id = HashMap::new();
        folders_by_id.insert(new_folder.id, new_folder.clone());
        folders_by_id.insert(existing.id, existing.clone());

        let event = InventoryAppliedIndexBatchEvent {
            root_id,
            upserted_files: vec![],
            upserted_folders: vec![new_folder.clone()],
            removed_file_ids: vec![],
            removed_folder_ids: vec![],
            removed_file_paths: vec![],
            removed_folder_paths: vec![],
            modified_file_ids: vec![],
            modified_folder_ids: vec![],
        };

        let patch = build_root_catalog_shard_patch(
            &event,
            &[],
            &previous_folders,
            &HashMap::new(),
            &folders_by_id,
            1,
        )
        .expect("no duplicate ids")
        .expect("patchable");

        assert_eq!(
            patch.folders.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![new_folder.id, existing.id]
        );
        assert_eq!(patch.logical_mutation_count, 1);
    }

    #[test]
    fn shard_patch_returns_none_when_upserted_file_does_not_match_files_by_id() {
        let root_id = uuid(1);
        let stale = file(uuid(11), root_id, "a.swift", "/root/a.swift", None);
        let mut fresh = stale.clone();
        fresh.full_path = "/root/renamed.swift".to_owned();
        let mut files_by_id = HashMap::new();
        // `files_by_id` disagrees with the event's upserted record -> Swift returns nil.
        files_by_id.insert(fresh.id, fresh);

        let event = InventoryAppliedIndexBatchEvent {
            root_id,
            upserted_files: vec![stale],
            upserted_folders: vec![],
            removed_file_ids: vec![],
            removed_folder_ids: vec![],
            removed_file_paths: vec![],
            removed_folder_paths: vec![],
            modified_file_ids: vec![],
            modified_folder_ids: vec![],
        };

        let patch =
            build_root_catalog_shard_patch(&event, &[], &[], &files_by_id, &HashMap::new(), 1)
                .expect("no duplicate ids");
        assert!(patch.is_none());
    }

    #[test]
    fn shard_patch_exceeded_mutation_count_returns_unmutated_with_empty_changed_ids() {
        let root_id = uuid(1);
        let f1 = file(uuid(10), root_id, "a.swift", "/root/a.swift", None);
        let f2 = file(uuid(11), root_id, "b.swift", "/root/b.swift", None);
        let previous_files = vec![f1.clone(), f2.clone()];
        let mut files_by_id = HashMap::new();
        files_by_id.insert(f1.id, f1.clone());
        files_by_id.insert(f2.id, f2.clone());

        let event = InventoryAppliedIndexBatchEvent {
            root_id,
            upserted_files: vec![],
            upserted_folders: vec![],
            removed_file_ids: vec![f1.id],
            removed_folder_ids: vec![],
            removed_file_paths: vec![],
            removed_folder_paths: vec![],
            modified_file_ids: vec![f2.id],
            modified_folder_ids: vec![],
        };
        // logical_mutation_count == 2 (one removed + one modified) > max_logical_mutation_count 1.
        let patch = build_root_catalog_shard_patch(
            &event,
            &previous_files,
            &[],
            &files_by_id,
            &HashMap::new(),
            1,
        )
        .expect("no duplicate ids")
        .expect("still returns Some, unmutated");
        assert_eq!(patch.files, previous_files);
        assert_eq!(patch.logical_mutation_count, 2);
        assert!(patch.path_index_changed_file_ids.is_empty());
    }

    #[test]
    fn merge_shards_orders_across_shards_and_breaks_ties_by_shard_then_index() {
        let root_id = uuid(1);
        let f_a = file(uuid(1), root_id, "a.swift", "/root/a.swift", None);
        let f_b = file(uuid(2), root_id, "b.swift", "/root/b.swift", None);
        let f_c = file(uuid(3), root_id, "c.swift", "/root/c.swift", None);
        let r = root(root_id, "Root", "/root");
        let e_a = InventorySearchCatalogEntry::new(&f_a, &r);
        let e_b = InventorySearchCatalogEntry::new(&f_b, &r);
        let e_c = InventorySearchCatalogEntry::new(&f_c, &r);

        let shard0 = (
            vec![f_a.clone(), f_c.clone()],
            vec![e_a.clone(), e_c.clone()],
        );
        let shard1 = (vec![f_b.clone()], vec![e_b.clone()]);
        let (files, entries) = merge_root_catalog_shard_file_entry_lists(&[shard0, shard1]);
        assert_eq!(
            files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![f_a.id, f_b.id, f_c.id]
        );
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[1].id, f_b.id);
    }
}
