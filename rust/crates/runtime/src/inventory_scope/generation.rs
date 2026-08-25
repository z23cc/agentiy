//! `RootGeneration`: the immutable, `Arc`-retained per-root published artifact.
//!
//! Per §2's mechanism table: "Published generations (sorted tables, entries projection, path
//! index) | `Arc<RootGeneration>`, immutable once published; a reader clones the `Arc` under the
//! lock and does all paging/query work outside it." Tables are relative-path ordered (single-root
//! shape), matching `inventory::builders::build_authoritative_catalog_components`'s single-root
//! branch and `build_root_catalog_shard_patch`'s insertion order -- both reused verbatim by
//! `state_machine`.
//!
//! **P4-3b: `path_index` is part of this struct, not a sibling.** Design §3.6 / §4.1.0's
//! co-location invariant -- "no build may ever ship in which the inventory tables are in Rust and
//! the search index that reads them is in Swift" -- is met by construction here: the index lives
//! inside the same `Arc`-retained, immutable-once-published object as `files`/`folders`/`entries`,
//! so there is no way to observe one without the other.

use std::sync::Arc;

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord, InventorySearchCatalogEntry};

use super::ids::{GenerationToken, RootId, RootLifetimeId};
use super::path_index::RootPathIndex;

#[derive(Clone, Debug)]
pub struct RootGeneration {
    pub root_id: RootId,
    pub root_lifetime: RootLifetimeId,
    pub generation: u64,
    pub token: GenerationToken,
    /// Discoverability-filtered, relative-path-ordered file table (§4.3.1.2's discoverability
    /// filter already applied -- these are the records a directory browse serves).
    pub files: Vec<InventoryFileRecord>,
    pub folders: Vec<InventoryFolderRecord>,
    pub entries: Vec<InventorySearchCatalogEntry>,
    /// The per-root path search index over `entries`, built by `state_machine::attempt_patch` /
    /// `rebuild_generation` from this same generation's own `entries` -- never from a
    /// caller-supplied table (P4-3b's structural invariant; see `path_index`'s module doc
    /// comment).
    pub path_index: Arc<RootPathIndex>,
}

impl RootGeneration {
    #[must_use]
    pub fn empty(root_id: RootId, root_lifetime: RootLifetimeId) -> Self {
        Self {
            root_id,
            root_lifetime,
            generation: 0,
            token: GenerationToken::new(root_lifetime, 0),
            files: Vec::new(),
            folders: Vec::new(),
            entries: Vec::new(),
            path_index: Arc::new(RootPathIndex::full(&[])),
        }
    }

    /// D-5's Rust-internal patch-vs-authoritative comparison encoding. This deliberately ignores
    /// `path_index`'s representation: both index variants are deterministic projections of
    /// `entries`, while their full-vs-overlay storage shape is allowed to differ. Every semantic
    /// record/entry field is encoded in fixed order with explicit lengths and raw scalar bits, so
    /// string interning or allocator identity can never affect equality.
    #[must_use]
    pub(crate) fn self_check_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        push_uuid(&mut bytes, &self.root_id);
        push_uuid(&mut bytes, self.root_lifetime.as_bytes());
        push_u64(&mut bytes, self.generation);
        push_u64(&mut bytes, self.files.len() as u64);
        for file in &self.files {
            push_record(
                &mut bytes,
                &file.id,
                &file.root_id,
                &file.name,
                &file.relative_path,
                &file.standardized_relative_path,
                &file.full_path,
                &file.standardized_full_path,
                file.parent_folder_id.as_ref(),
                file.modification_date,
            );
        }
        push_u64(&mut bytes, self.folders.len() as u64);
        for folder in &self.folders {
            push_record(
                &mut bytes,
                &folder.id,
                &folder.root_id,
                &folder.name,
                &folder.relative_path,
                &folder.standardized_relative_path,
                &folder.full_path,
                &folder.standardized_full_path,
                folder.parent_folder_id.as_ref(),
                folder.modification_date,
            );
        }
        push_u64(&mut bytes, self.entries.len() as u64);
        for entry in &self.entries {
            push_uuid(&mut bytes, &entry.id);
            push_uuid(&mut bytes, &entry.root_id);
            push_string(&mut bytes, &entry.root_path);
            push_string(&mut bytes, &entry.root_name);
            push_string(&mut bytes, &entry.name);
            push_string(&mut bytes, &entry.relative_path);
            push_string(&mut bytes, &entry.standardized_relative_path);
            push_string(&mut bytes, &entry.full_path);
            push_string(&mut bytes, &entry.standardized_full_path);
            push_string(&mut bytes, &entry.display_path);
        }
        bytes
    }
}

fn push_record(
    bytes: &mut Vec<u8>,
    id: &[u8; 16],
    root_id: &[u8; 16],
    name: &str,
    relative_path: &str,
    standardized_relative_path: &str,
    full_path: &str,
    standardized_full_path: &str,
    parent_folder_id: Option<&[u8; 16]>,
    modification_date: Option<f64>,
) {
    push_uuid(bytes, id);
    push_uuid(bytes, root_id);
    push_string(bytes, name);
    push_string(bytes, relative_path);
    push_string(bytes, standardized_relative_path);
    push_string(bytes, full_path);
    push_string(bytes, standardized_full_path);
    match parent_folder_id {
        Some(parent_folder_id) => {
            bytes.push(1);
            push_uuid(bytes, parent_folder_id);
        }
        None => bytes.push(0),
    }
    match modification_date {
        Some(modification_date) => {
            bytes.push(1);
            push_u64(bytes, modification_date.to_bits());
        }
        None => bytes.push(0),
    }
}

fn push_uuid(bytes: &mut Vec<u8>, uuid: &[u8; 16]) {
    bytes.extend_from_slice(uuid);
}

fn push_string(bytes: &mut Vec<u8>, value: &str) {
    push_u64(bytes, value.len() as u64);
    bytes.extend_from_slice(value.as_bytes());
}

fn push_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

/// Hand-written rather than `#[derive(PartialEq)]`: `pathsearch::PathSearchIndex` (reused
/// unchanged from the P3-3 port, §4.4.1) has no `PartialEq` of its own, and giving it one purely
/// to satisfy this derive would mean editing a module the design requires to stay unchanged. The
/// index is a pure, deterministic function of `entries` and the previously-published index (see
/// `path_index`'s module doc comment), so it carries no independent state a semantic equality
/// check needs to inspect; `Arc::ptr_eq` is used instead, which is exactly the notion existing
/// callers need (`HandleReadOutcome`'s derived `PartialEq`, used only to distinguish
/// `HandleInvalidated` outcomes in `inventory_scope_contract.rs`'s tests, never to deep-compare two
/// `Open` generations' indexes).
impl PartialEq for RootGeneration {
    fn eq(&self, other: &Self) -> bool {
        self.root_id == other.root_id
            && self.root_lifetime == other.root_lifetime
            && self.generation == other.generation
            && self.token == other.token
            && self.files == other.files
            && self.folders == other.folders
            && self.entries == other.entries
            && Arc::ptr_eq(&self.path_index, &other.path_index)
    }
}
