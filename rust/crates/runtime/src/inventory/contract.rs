//! Wire/contract constants for the P3-2 workspace inventory catalog-builder port.
//!
//! Mirrors the shape of `codemap::contract` / `apply_edits::compact`: a version tag plus the
//! word-table strides used by `compact.rs` to encode/decode requests and responses.

pub const INVENTORY_CONTRACT_VERSION_V1: u16 = 1;

/// Sentinel for an absent optional string/uuid pool index, matching `codemap::OPTIONAL_WORD`.
pub const OPTIONAL_WORD: u64 = u64::MAX;

/// Words per pooled UUID entry (two big-endian `u64` halves of the 16 raw bytes).
pub const UUID_STRIDE: usize = 2;

/// Words per pooled string range entry (`start`, `end` byte offsets into `utf8_blob`).
pub const STRING_RANGE_STRIDE: usize = 2;

/// Words per file/folder record row. Both `WorkspaceFileRecord` and `WorkspaceFolderRecord` are
/// ported as the same nine-field shape (see `builders::InventoryFileRecord` /
/// `InventoryFolderRecord` doc comments for the field list), so both tables share one stride:
/// id(2) + root_id(2) + name(1) + relative_path(1) + standardized_relative_path(1) + full_path(1)
/// + standardized_full_path(1) + parent_folder_id_present(1) + parent_folder_id(2) +
/// modification_date_present(1) + modification_date_bits(1) = 14.
pub const RECORD_STRIDE: usize = 14;

/// Words per root record row: id(2) + name(1) + standardized_full_path(1) = 4.
pub const ROOT_STRIDE: usize = 4;

/// Words per search-catalog-entry row: id(2) + root_id(2) + root_path(1) + root_name(1) + name(1)
/// + relative_path(1) + standardized_relative_path(1) + full_path(1) + standardized_full_path(1)
/// + display_path(1) = 12.
pub const ENTRY_STRIDE: usize = 12;

/// Words per merge-shard descriptor row: files_start(1) + files_count(1) + entries_start(1) +
/// entries_count(1) = 4.
pub const SHARD_STRIDE: usize = 4;

/// Operation selector carried by `InventoryComputeRequestV1.operation`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum InventoryOperation {
    /// `buildAuthoritativeCatalogComponents`.
    AuthoritativeCatalog = 0,
    /// `buildPendingCatalogComponents`.
    PendingCatalog = 1,
    /// `buildRootCatalogShardPatch`.
    ShardPatch = 2,
    /// `mergeRootCatalogShardFileEntryLists`.
    MergeShards = 3,
}

impl InventoryOperation {
    pub const ALL: [Self; 4] = [
        Self::AuthoritativeCatalog,
        Self::PendingCatalog,
        Self::ShardPatch,
        Self::MergeShards,
    ];

    pub fn from_id(id: u16) -> Option<Self> {
        Self::ALL.into_iter().find(|op| *op as u16 == id)
    }

    pub const fn id(self) -> u16 {
        self as u16
    }
}

/// Outcome tag for `ShardPatch` responses: `buildRootCatalogShardPatch` returns `nil` as a normal
/// business outcome (fall back to authoritative rebuild), which is distinct from a decode/request
/// error and must be encoded as such rather than conflated with either.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum InventoryShardPatchOutcomeTag {
    Patched = 0,
    NotPatchable = 1,
}

impl InventoryShardPatchOutcomeTag {
    pub fn from_id(id: u16) -> Option<Self> {
        match id {
            0 => Some(Self::Patched),
            1 => Some(Self::NotPatchable),
            _ => None,
        }
    }
}
