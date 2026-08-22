//! `RootGeneration`: the immutable, `Arc`-retained per-root published artifact.
//!
//! Per §2's mechanism table: "Published generations (sorted tables, entries projection, path
//! index) | `Arc<RootGeneration>`, immutable once published; a reader clones the `Arc` under the
//! lock and does all paging/query work outside it." Tables are relative-path ordered (single-root
//! shape), matching `inventory::builders::build_authoritative_catalog_components`'s single-root
//! branch and `build_root_catalog_shard_patch`'s insertion order -- both reused verbatim by
//! `state_machine`.

use crate::inventory::{InventoryFileRecord, InventoryFolderRecord, InventorySearchCatalogEntry};

use super::ids::{GenerationToken, RootId, RootLifetimeId};

#[derive(Clone, Debug, PartialEq)]
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
        }
    }
}
