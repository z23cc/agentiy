//! Compact wire codec for the P3-2 workspace inventory catalog builders, following the
//! `codemap`/`apply_edits` compact-v1 conventions (word tables + a UTF-8 blob, `(start, end)`
//! string ranges, fail-closed decode). Unlike those two (which compact-encode only the response),
//! this module compact-encodes BOTH request and response: `buildAuthoritativeCatalogComponents`
//! and friends take/emit whole-workspace file/folder tables, which can be as large as any single
//! response those modules produce.
//!
//! One request shape, `operation`-tagged, drives all four Swift builder functions ("a new sync
//! compute entry" per the P3-2 plan) rather than four separate FFI entry points. Fields unused by
//! a given `operation` are left as empty ranges; `InventoryComputeService::compute` validates
//! shape per-operation before touching the builders.

use super::builders::{
    self, InventoryAppliedIndexBatchEvent, InventoryCatalogComponents, InventoryError,
    InventoryFileRecord, InventoryFolderRecord, InventoryRootRecord, InventorySearchCatalogEntry,
    InventoryUuid,
};
use super::contract::{
    ENTRY_STRIDE, INVENTORY_CONTRACT_VERSION_V1, InventoryOperation, InventoryShardPatchOutcomeTag,
    RECORD_STRIDE, ROOT_STRIDE, SHARD_STRIDE, STRING_RANGE_STRIDE, UUID_STRIDE,
};
use std::collections::{HashMap, HashSet};
use std::fmt;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct InventoryTableRange {
    pub start: u64,
    pub count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InventoryComputeError {
    InvalidRequest(String),
    Builder(InventoryError),
    Cancelled,
}

impl fmt::Display for InventoryComputeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => write!(formatter, "invalid inventory request: {value}"),
            Self::Builder(error) => write!(formatter, "inventory builder error: {error}"),
            Self::Cancelled => formatter.write_str("inventory compute cancelled"),
        }
    }
}
impl std::error::Error for InventoryComputeError {}

impl From<InventoryError> for InventoryComputeError {
    fn from(value: InventoryError) -> Self {
        Self::Builder(value)
    }
}

/// Compact wire request. See the module doc comment for the shared-pool-plus-ranges shape.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InventoryComputeRequestV1 {
    pub contract_version: u16,
    pub operation: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    /// Flat pool of string-pool indices, sliced by `event_removed_file_paths` /
    /// `event_removed_folder_paths`.
    pub string_index_words: Vec<u64>,
    /// Flat pool of standalone (non-record-embedded) UUIDs, stride 2, sliced by
    /// `managed_only_file_ids` / `managed_only_folder_ids` / `event_removed_file_ids` /
    /// `event_removed_folder_ids` / `event_modified_file_ids` / `event_modified_folder_ids`.
    pub uuid_words: Vec<u64>,

    pub root_words: Vec<u64>,
    /// Shared row pool for every file-record list this request references (`files_by_id`,
    /// `previous_files`, `event_upserted_files`, and per-shard files for `MergeShards`).
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    /// `MergeShards`-only: per-shard search-catalog entries, index-aligned with the shard's file
    /// range.
    pub entry_words: Vec<u64>,
    /// `MergeShards`-only: shard descriptor rows (`files_start, files_count, entries_start,
    /// entries_count`), each pair of ranges into `file_words`/`entry_words`.
    pub shard_words: Vec<u64>,

    // AuthoritativeCatalog (all fields) / PendingCatalog (`roots.count` must be 1).
    pub roots: InventoryTableRange,
    pub files_by_id: InventoryTableRange,
    pub folders_by_id: InventoryTableRange,
    pub managed_only_file_ids: InventoryTableRange,
    pub managed_only_folder_ids: InventoryTableRange,

    // ShardPatch.
    pub previous_files: InventoryTableRange,
    pub previous_folders: InventoryTableRange,
    pub event_root_id_hi: u64,
    pub event_root_id_lo: u64,
    pub event_upserted_files: InventoryTableRange,
    pub event_upserted_folders: InventoryTableRange,
    pub event_removed_file_ids: InventoryTableRange,
    pub event_removed_folder_ids: InventoryTableRange,
    pub event_removed_file_paths: InventoryTableRange,
    pub event_removed_folder_paths: InventoryTableRange,
    pub event_modified_file_ids: InventoryTableRange,
    pub event_modified_folder_ids: InventoryTableRange,
    pub max_logical_mutation_count: u64,

    // MergeShards.
    pub shards: InventoryTableRange,
}

/// Compact wire response. `operation` echoes the request's operation. Only the fields relevant to
/// that operation are populated; the rest are empty ranges.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InventoryComputeResultV1 {
    pub operation: u16,

    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub uuid_words: Vec<u64>,
    pub file_words: Vec<u64>,
    pub folder_words: Vec<u64>,
    pub entry_words: Vec<u64>,

    // AuthoritativeCatalog / PendingCatalog.
    pub components_files: InventoryTableRange,
    pub components_folders: InventoryTableRange,
    pub components_entries: InventoryTableRange,

    // ShardPatch. `InventoryShardPatchOutcomeTag`; the three fields after it are only meaningful
    // when the tag is `Patched`.
    pub shard_patch_outcome: u16,
    pub shard_patch_files: InventoryTableRange,
    pub shard_patch_folders: InventoryTableRange,
    pub shard_patch_logical_mutation_count: u64,
    pub shard_patch_changed_file_ids: InventoryTableRange,

    // MergeShards.
    pub merged_files: InventoryTableRange,
    pub merged_entries: InventoryTableRange,
}

/// Shared word-pool accessors, implemented by both the request and the response so encode/decode
/// helpers below (`push_string`, `push_file_row`, `decode_string`, ...) work identically whether
/// building request fixtures (Rust tests today; the Swift encoder in P3-2 step 3) or encoding a
/// response.
trait WordPools {
    fn blob(&self) -> &[u8];
    fn blob_mut(&mut self) -> &mut Vec<u8>;
    fn string_ranges(&self) -> &[u64];
    fn string_ranges_mut(&mut self) -> &mut Vec<u64>;
    fn file_words(&self) -> &[u64];
    fn file_words_mut(&mut self) -> &mut Vec<u64>;
    fn folder_words(&self) -> &[u64];
    fn folder_words_mut(&mut self) -> &mut Vec<u64>;
    fn entry_words(&self) -> &[u64];
    fn entry_words_mut(&mut self) -> &mut Vec<u64>;
    fn uuid_words(&self) -> &[u64];
    fn uuid_words_mut(&mut self) -> &mut Vec<u64>;
}

macro_rules! impl_word_pools {
    ($ty:ty) => {
        impl WordPools for $ty {
            fn blob(&self) -> &[u8] {
                &self.utf8_blob
            }
            fn blob_mut(&mut self) -> &mut Vec<u8> {
                &mut self.utf8_blob
            }
            fn string_ranges(&self) -> &[u64] {
                &self.string_range_words
            }
            fn string_ranges_mut(&mut self) -> &mut Vec<u64> {
                &mut self.string_range_words
            }
            fn file_words(&self) -> &[u64] {
                &self.file_words
            }
            fn file_words_mut(&mut self) -> &mut Vec<u64> {
                &mut self.file_words
            }
            fn folder_words(&self) -> &[u64] {
                &self.folder_words
            }
            fn folder_words_mut(&mut self) -> &mut Vec<u64> {
                &mut self.folder_words
            }
            fn entry_words(&self) -> &[u64] {
                &self.entry_words
            }
            fn entry_words_mut(&mut self) -> &mut Vec<u64> {
                &mut self.entry_words
            }
            fn uuid_words(&self) -> &[u64] {
                &self.uuid_words
            }
            fn uuid_words_mut(&mut self) -> &mut Vec<u64> {
                &mut self.uuid_words
            }
        }
    };
}
impl_word_pools!(InventoryComputeRequestV1);
impl_word_pools!(InventoryComputeResultV1);

fn word(value: usize) -> Result<u64, InventoryComputeError> {
    u64::try_from(value)
        .map_err(|_| InventoryComputeError::InvalidRequest("compact index overflow".into()))
}
fn usize_word(value: u64) -> Result<usize, InventoryComputeError> {
    usize::try_from(value).map_err(|_| {
        InventoryComputeError::InvalidRequest("compact word exceeds platform index".into())
    })
}
fn checked_range(
    len: usize,
    range: InventoryTableRange,
) -> Result<(usize, usize), InventoryComputeError> {
    let start = usize_word(range.start)?;
    let count = usize_word(range.count)?;
    let end = start
        .checked_add(count)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("compact range overflow".into()))?;
    if end > len {
        return Err(InventoryComputeError::InvalidRequest(
            "compact range out of bounds".into(),
        ));
    }
    Ok((start, end))
}

fn uuid_to_words(id: &InventoryUuid) -> (u64, u64) {
    let hi = u64::from_be_bytes(id[0..8].try_into().expect("8 bytes"));
    let lo = u64::from_be_bytes(id[8..16].try_into().expect("8 bytes"));
    (hi, lo)
}
fn uuid_from_words(hi: u64, lo: u64) -> InventoryUuid {
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&hi.to_be_bytes());
    bytes[8..16].copy_from_slice(&lo.to_be_bytes());
    bytes
}

// ---- encode ----------------------------------------------------------------------------------

fn push_string<T: WordPools>(target: &mut T, value: &str) -> Result<u64, InventoryComputeError> {
    let start = word(target.blob().len())?;
    target.blob_mut().extend_from_slice(value.as_bytes());
    let end = word(target.blob().len())?;
    let index = word(target.string_ranges().len() / STRING_RANGE_STRIDE)?;
    target.string_ranges_mut().extend([start, end]);
    Ok(index)
}

fn push_uuid<T: WordPools>(target: &mut T, id: &InventoryUuid) -> u64 {
    let (hi, lo) = uuid_to_words(id);
    let index = (target.uuid_words().len() / UUID_STRIDE) as u64;
    target.uuid_words_mut().extend([hi, lo]);
    index
}

fn push_uuid_list<T: WordPools>(
    target: &mut T,
    ids: &[InventoryUuid],
) -> Result<InventoryTableRange, InventoryComputeError> {
    let start = word(target.uuid_words().len() / UUID_STRIDE)?;
    for id in ids {
        push_uuid(target, id);
    }
    let end = word(target.uuid_words().len() / UUID_STRIDE)?;
    Ok(InventoryTableRange {
        start,
        count: end - start,
    })
}

fn push_record_row<T: WordPools>(
    target: &mut T,
    is_folder: bool,
    id: &InventoryUuid,
    root_id: &InventoryUuid,
    name: &str,
    relative_path: &str,
    standardized_relative_path: &str,
    full_path: &str,
    standardized_full_path: &str,
    parent_folder_id: Option<InventoryUuid>,
    modification_date: Option<f64>,
) -> Result<(), InventoryComputeError> {
    let (id_hi, id_lo) = uuid_to_words(id);
    let (root_hi, root_lo) = uuid_to_words(root_id);
    let name_idx = push_string(target, name)?;
    let relative_idx = push_string(target, relative_path)?;
    let std_relative_idx = push_string(target, standardized_relative_path)?;
    let full_idx = push_string(target, full_path)?;
    let std_full_idx = push_string(target, standardized_full_path)?;
    let (parent_present, parent_hi, parent_lo) = match parent_folder_id {
        Some(id) => {
            let (hi, lo) = uuid_to_words(&id);
            (1u64, hi, lo)
        }
        None => (0u64, 0u64, 0u64),
    };
    let (mod_present, mod_bits) = match modification_date {
        Some(value) => (1u64, value.to_bits()),
        None => (0u64, 0u64),
    };
    let row = [
        id_hi,
        id_lo,
        root_hi,
        root_lo,
        name_idx,
        relative_idx,
        std_relative_idx,
        full_idx,
        std_full_idx,
        parent_present,
        parent_hi,
        parent_lo,
        mod_present,
        mod_bits,
    ];
    if is_folder {
        target.folder_words_mut().extend(row);
    } else {
        target.file_words_mut().extend(row);
    }
    Ok(())
}

fn push_file_row<T: WordPools>(
    target: &mut T,
    file: &InventoryFileRecord,
) -> Result<(), InventoryComputeError> {
    push_record_row(
        target,
        false,
        &file.id,
        &file.root_id,
        &file.name,
        &file.relative_path,
        &file.standardized_relative_path,
        &file.full_path,
        &file.standardized_full_path,
        file.parent_folder_id,
        file.modification_date,
    )
}

fn push_folder_row<T: WordPools>(
    target: &mut T,
    folder: &InventoryFolderRecord,
) -> Result<(), InventoryComputeError> {
    push_record_row(
        target,
        true,
        &folder.id,
        &folder.root_id,
        &folder.name,
        &folder.relative_path,
        &folder.standardized_relative_path,
        &folder.full_path,
        &folder.standardized_full_path,
        folder.parent_folder_id,
        folder.modification_date,
    )
}

fn push_files<T: WordPools>(
    target: &mut T,
    files: &[InventoryFileRecord],
) -> Result<InventoryTableRange, InventoryComputeError> {
    let start = word(target.file_words().len() / RECORD_STRIDE)?;
    for file in files {
        push_file_row(target, file)?;
    }
    let end = word(target.file_words().len() / RECORD_STRIDE)?;
    Ok(InventoryTableRange {
        start,
        count: end - start,
    })
}

fn push_folders<T: WordPools>(
    target: &mut T,
    folders: &[InventoryFolderRecord],
) -> Result<InventoryTableRange, InventoryComputeError> {
    let start = word(target.folder_words().len() / RECORD_STRIDE)?;
    for folder in folders {
        push_folder_row(target, folder)?;
    }
    let end = word(target.folder_words().len() / RECORD_STRIDE)?;
    Ok(InventoryTableRange {
        start,
        count: end - start,
    })
}

fn push_entry_row<T: WordPools>(
    target: &mut T,
    entry: &InventorySearchCatalogEntry,
) -> Result<(), InventoryComputeError> {
    let (id_hi, id_lo) = uuid_to_words(&entry.id);
    let (root_hi, root_lo) = uuid_to_words(&entry.root_id);
    let root_path = push_string(target, &entry.root_path)?;
    let root_name = push_string(target, &entry.root_name)?;
    let name = push_string(target, &entry.name)?;
    let relative_path = push_string(target, &entry.relative_path)?;
    let standardized_relative_path = push_string(target, &entry.standardized_relative_path)?;
    let full_path = push_string(target, &entry.full_path)?;
    let standardized_full_path = push_string(target, &entry.standardized_full_path)?;
    let display_path = push_string(target, &entry.display_path)?;
    target.entry_words_mut().extend([
        id_hi,
        id_lo,
        root_hi,
        root_lo,
        root_path,
        root_name,
        name,
        relative_path,
        standardized_relative_path,
        full_path,
        standardized_full_path,
        display_path,
    ]);
    Ok(())
}

fn push_entries<T: WordPools>(
    target: &mut T,
    entries: &[InventorySearchCatalogEntry],
) -> Result<InventoryTableRange, InventoryComputeError> {
    let start = word(target.entry_words().len() / ENTRY_STRIDE)?;
    for entry in entries {
        push_entry_row(target, entry)?;
    }
    let end = word(target.entry_words().len() / ENTRY_STRIDE)?;
    Ok(InventoryTableRange {
        start,
        count: end - start,
    })
}

impl InventoryComputeRequestV1 {
    pub fn push_roots(
        &mut self,
        roots: &[InventoryRootRecord],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        let start = word(self.root_words.len() / ROOT_STRIDE)?;
        for root in roots {
            let (hi, lo) = uuid_to_words(&root.id);
            let name = push_string(self, &root.name)?;
            let path = push_string(self, &root.standardized_full_path)?;
            self.root_words.extend([hi, lo, name, path]);
        }
        let end = word(self.root_words.len() / ROOT_STRIDE)?;
        Ok(InventoryTableRange {
            start,
            count: end - start,
        })
    }

    pub fn push_files(
        &mut self,
        files: &[InventoryFileRecord],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        push_files(self, files)
    }

    pub fn push_folders(
        &mut self,
        folders: &[InventoryFolderRecord],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        push_folders(self, folders)
    }

    pub fn push_uuid_ids(
        &mut self,
        ids: &[InventoryUuid],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        push_uuid_list(self, ids)
    }

    pub fn push_string_paths(
        &mut self,
        values: &[String],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        let start = word(self.string_index_words.len())?;
        for value in values {
            let index = push_string(self, value)?;
            self.string_index_words.push(index);
        }
        let end = word(self.string_index_words.len())?;
        Ok(InventoryTableRange {
            start,
            count: end - start,
        })
    }

    pub fn set_event_root_id(&mut self, root_id: &InventoryUuid) {
        let (hi, lo) = uuid_to_words(root_id);
        self.event_root_id_hi = hi;
        self.event_root_id_lo = lo;
    }

    pub fn push_shards(
        &mut self,
        shards: &[(Vec<InventoryFileRecord>, Vec<InventorySearchCatalogEntry>)],
    ) -> Result<InventoryTableRange, InventoryComputeError> {
        let start = word(self.shard_words.len() / SHARD_STRIDE)?;
        for (files, entries) in shards {
            let files_range = self.push_files(files)?;
            let entries_range = push_entries(self, entries)?;
            self.shard_words.extend([
                files_range.start,
                files_range.count,
                entries_range.start,
                entries_range.count,
            ]);
        }
        let end = word(self.shard_words.len() / SHARD_STRIDE)?;
        Ok(InventoryTableRange {
            start,
            count: end - start,
        })
    }
}

// ---- decode ----------------------------------------------------------------------------------

fn decode_string<T: WordPools>(
    source: &T,
    string_index: u64,
) -> Result<String, InventoryComputeError> {
    let index = usize_word(string_index)?;
    let row_start = index
        .checked_mul(STRING_RANGE_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("string index overflow".into()))?;
    let row_end = row_start
        .checked_add(STRING_RANGE_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("string index overflow".into()))?;
    let row = source
        .string_ranges()
        .get(row_start..row_end)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("string index out of range".into()))?;
    let start = usize_word(row[0])?;
    let end = usize_word(row[1])?;
    if end < start || end > source.blob().len() {
        return Err(InventoryComputeError::InvalidRequest(
            "invalid string byte range".into(),
        ));
    }
    std::str::from_utf8(&source.blob()[start..end])
        .map(str::to_owned)
        .map_err(|_| InventoryComputeError::InvalidRequest("invalid utf8 in blob".into()))
}

fn decode_uuid_at<T: WordPools>(
    source: &T,
    row_index: usize,
) -> Result<InventoryUuid, InventoryComputeError> {
    let base = row_index
        .checked_mul(UUID_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("uuid index overflow".into()))?;
    let end = base
        .checked_add(UUID_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("uuid index overflow".into()))?;
    let row = source
        .uuid_words()
        .get(base..end)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("uuid index out of range".into()))?;
    Ok(uuid_from_words(row[0], row[1]))
}

fn decode_uuid_list<T: WordPools>(
    source: &T,
    range: InventoryTableRange,
) -> Result<Vec<InventoryUuid>, InventoryComputeError> {
    let (start, end) = checked_range(source.uuid_words().len() / UUID_STRIDE, range)?;
    (start..end)
        .map(|index| decode_uuid_at(source, index))
        .collect()
}

fn decode_uuid_set<T: WordPools>(
    source: &T,
    range: InventoryTableRange,
) -> Result<HashSet<InventoryUuid>, InventoryComputeError> {
    Ok(decode_uuid_list(source, range)?.into_iter().collect())
}

struct DecodedRecordRow {
    id: InventoryUuid,
    root_id: InventoryUuid,
    name: String,
    relative_path: String,
    standardized_relative_path: String,
    full_path: String,
    standardized_full_path: String,
    parent_folder_id: Option<InventoryUuid>,
    modification_date: Option<f64>,
}

fn decode_record_row<T: WordPools>(
    source: &T,
    row: &[u64],
) -> Result<DecodedRecordRow, InventoryComputeError> {
    let id = uuid_from_words(row[0], row[1]);
    let root_id = uuid_from_words(row[2], row[3]);
    let name = decode_string(source, row[4])?;
    let relative_path = decode_string(source, row[5])?;
    let standardized_relative_path = decode_string(source, row[6])?;
    let full_path = decode_string(source, row[7])?;
    let standardized_full_path = decode_string(source, row[8])?;
    let parent_folder_id = match row[9] {
        0 => {
            if row[10] != 0 || row[11] != 0 {
                return Err(InventoryComputeError::InvalidRequest(
                    "absent parent-folder id must have zero payload words".into(),
                ));
            }
            None
        }
        1 => Some(uuid_from_words(row[10], row[11])),
        _ => {
            return Err(InventoryComputeError::InvalidRequest(
                "invalid parent-folder presence flag".into(),
            ));
        }
    };
    let modification_date = match row[12] {
        0 => {
            if row[13] != 0 {
                return Err(InventoryComputeError::InvalidRequest(
                    "absent modification date must have zero payload word".into(),
                ));
            }
            None
        }
        1 => {
            let value = f64::from_bits(row[13]);
            if value.is_nan() {
                return Err(InventoryComputeError::InvalidRequest(
                    "modification date must not be NaN".into(),
                ));
            }
            Some(value)
        }
        _ => {
            return Err(InventoryComputeError::InvalidRequest(
                "invalid modification-date presence flag".into(),
            ));
        }
    };
    Ok(DecodedRecordRow {
        id,
        root_id,
        name,
        relative_path,
        standardized_relative_path,
        full_path,
        standardized_full_path,
        parent_folder_id,
        modification_date,
    })
}

fn decode_file_record_at<T: WordPools>(
    source: &T,
    row_index: usize,
) -> Result<InventoryFileRecord, InventoryComputeError> {
    let base = row_index.checked_mul(RECORD_STRIDE).ok_or_else(|| {
        InventoryComputeError::InvalidRequest("file record index overflow".into())
    })?;
    let end = base.checked_add(RECORD_STRIDE).ok_or_else(|| {
        InventoryComputeError::InvalidRequest("file record index overflow".into())
    })?;
    let row = source
        .file_words()
        .get(base..end)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("file record out of range".into()))?;
    let decoded = decode_record_row(source, row)?;
    Ok(InventoryFileRecord {
        id: decoded.id,
        root_id: decoded.root_id,
        name: decoded.name,
        relative_path: decoded.relative_path,
        standardized_relative_path: decoded.standardized_relative_path,
        full_path: decoded.full_path,
        standardized_full_path: decoded.standardized_full_path,
        parent_folder_id: decoded.parent_folder_id,
        modification_date: decoded.modification_date,
    })
}

fn decode_folder_record_at<T: WordPools>(
    source: &T,
    row_index: usize,
) -> Result<InventoryFolderRecord, InventoryComputeError> {
    let base = row_index.checked_mul(RECORD_STRIDE).ok_or_else(|| {
        InventoryComputeError::InvalidRequest("folder record index overflow".into())
    })?;
    let end = base.checked_add(RECORD_STRIDE).ok_or_else(|| {
        InventoryComputeError::InvalidRequest("folder record index overflow".into())
    })?;
    let row = source.folder_words().get(base..end).ok_or_else(|| {
        InventoryComputeError::InvalidRequest("folder record out of range".into())
    })?;
    let decoded = decode_record_row(source, row)?;
    Ok(InventoryFolderRecord {
        id: decoded.id,
        root_id: decoded.root_id,
        name: decoded.name,
        relative_path: decoded.relative_path,
        standardized_relative_path: decoded.standardized_relative_path,
        full_path: decoded.full_path,
        standardized_full_path: decoded.standardized_full_path,
        parent_folder_id: decoded.parent_folder_id,
        modification_date: decoded.modification_date,
    })
}

fn decode_files<T: WordPools>(
    source: &T,
    range: InventoryTableRange,
) -> Result<Vec<InventoryFileRecord>, InventoryComputeError> {
    let (start, end) = checked_range(source.file_words().len() / RECORD_STRIDE, range)?;
    (start..end)
        .map(|index| decode_file_record_at(source, index))
        .collect()
}

fn decode_folders<T: WordPools>(
    source: &T,
    range: InventoryTableRange,
) -> Result<Vec<InventoryFolderRecord>, InventoryComputeError> {
    let (start, end) = checked_range(source.folder_words().len() / RECORD_STRIDE, range)?;
    (start..end)
        .map(|index| decode_folder_record_at(source, index))
        .collect()
}

fn decode_entry_record_at<T: WordPools>(
    source: &T,
    row_index: usize,
) -> Result<InventorySearchCatalogEntry, InventoryComputeError> {
    let base = row_index
        .checked_mul(ENTRY_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("entry index overflow".into()))?;
    let end = base
        .checked_add(ENTRY_STRIDE)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("entry index overflow".into()))?;
    let row = source
        .entry_words()
        .get(base..end)
        .ok_or_else(|| InventoryComputeError::InvalidRequest("entry out of range".into()))?;
    let id = uuid_from_words(row[0], row[1]);
    let root_id = uuid_from_words(row[2], row[3]);
    let root_path = decode_string(source, row[4])?;
    let root_name = decode_string(source, row[5])?;
    let name = decode_string(source, row[6])?;
    let relative_path = decode_string(source, row[7])?;
    let standardized_relative_path = decode_string(source, row[8])?;
    let full_path = decode_string(source, row[9])?;
    let standardized_full_path = decode_string(source, row[10])?;
    let display_path = decode_string(source, row[11])?;
    Ok(InventorySearchCatalogEntry {
        id,
        root_id,
        root_path,
        root_name,
        name,
        relative_path,
        standardized_relative_path,
        full_path,
        standardized_full_path,
        display_path,
    })
}

fn decode_entries<T: WordPools>(
    source: &T,
    range: InventoryTableRange,
) -> Result<Vec<InventorySearchCatalogEntry>, InventoryComputeError> {
    let (start, end) = checked_range(source.entry_words().len() / ENTRY_STRIDE, range)?;
    (start..end)
        .map(|index| decode_entry_record_at(source, index))
        .collect()
}

fn decode_roots(
    request: &InventoryComputeRequestV1,
    range: InventoryTableRange,
) -> Result<Vec<InventoryRootRecord>, InventoryComputeError> {
    let (start, end) = checked_range(request.root_words.len() / ROOT_STRIDE, range)?;
    (start..end)
        .map(|row_index| {
            let base = row_index.checked_mul(ROOT_STRIDE).ok_or_else(|| {
                InventoryComputeError::InvalidRequest("root index overflow".into())
            })?;
            let end = base.checked_add(ROOT_STRIDE).ok_or_else(|| {
                InventoryComputeError::InvalidRequest("root index overflow".into())
            })?;
            let row = request.root_words.get(base..end).ok_or_else(|| {
                InventoryComputeError::InvalidRequest("root record out of range".into())
            })?;
            Ok(InventoryRootRecord {
                id: uuid_from_words(row[0], row[1]),
                name: decode_string(request, row[2])?,
                standardized_full_path: decode_string(request, row[3])?,
            })
        })
        .collect()
}

fn decode_string_list(
    request: &InventoryComputeRequestV1,
    range: InventoryTableRange,
) -> Result<Vec<String>, InventoryComputeError> {
    let (start, end) = checked_range(request.string_index_words.len(), range)?;
    request.string_index_words[start..end]
        .iter()
        .map(|&index| decode_string(request, index))
        .collect()
}

fn to_file_map(
    files: Vec<InventoryFileRecord>,
) -> Result<HashMap<InventoryUuid, InventoryFileRecord>, InventoryComputeError> {
    let mut map = HashMap::with_capacity(files.len());
    for file in files {
        if map.insert(file.id, file).is_some() {
            return Err(InventoryComputeError::InvalidRequest(
                "duplicate file id in files_by_id".into(),
            ));
        }
    }
    Ok(map)
}

fn to_folder_map(
    folders: Vec<InventoryFolderRecord>,
) -> Result<HashMap<InventoryUuid, InventoryFolderRecord>, InventoryComputeError> {
    let mut map = HashMap::with_capacity(folders.len());
    for folder in folders {
        if map.insert(folder.id, folder).is_some() {
            return Err(InventoryComputeError::InvalidRequest(
                "duplicate folder id in folders_by_id".into(),
            ));
        }
    }
    Ok(map)
}

fn ensure_range_default(
    name: &str,
    range: InventoryTableRange,
) -> Result<(), InventoryComputeError> {
    if range.start != 0 || range.count != 0 {
        return Err(InventoryComputeError::InvalidRequest(format!(
            "field {name} must be empty for this operation"
        )));
    }
    Ok(())
}

fn ensure_ranges_default(
    ranges: &[(&str, InventoryTableRange)],
) -> Result<(), InventoryComputeError> {
    for (name, range) in ranges {
        ensure_range_default(name, *range)?;
    }
    Ok(())
}

fn ensure_event_scalars_default(
    request: &InventoryComputeRequestV1,
) -> Result<(), InventoryComputeError> {
    if request.event_root_id_hi != 0
        || request.event_root_id_lo != 0
        || request.max_logical_mutation_count != 0
    {
        return Err(InventoryComputeError::InvalidRequest(
            "event/patch scalar fields must be zero for this operation".into(),
        ));
    }
    Ok(())
}

/// Fail-closed guard against the request carrying populated fields the selected `operation`
/// never reads: `compute_*` only decodes the ranges relevant to its own operation, so without
/// this check garbage in every other field would be silently ignored rather than rejected.
fn validate_operation_fields(
    request: &InventoryComputeRequestV1,
    operation: InventoryOperation,
) -> Result<(), InventoryComputeError> {
    match operation {
        InventoryOperation::AuthoritativeCatalog => {
            ensure_ranges_default(&[
                ("previous_files", request.previous_files),
                ("previous_folders", request.previous_folders),
                ("event_upserted_files", request.event_upserted_files),
                ("event_upserted_folders", request.event_upserted_folders),
                ("event_removed_file_ids", request.event_removed_file_ids),
                ("event_removed_folder_ids", request.event_removed_folder_ids),
                ("event_removed_file_paths", request.event_removed_file_paths),
                (
                    "event_removed_folder_paths",
                    request.event_removed_folder_paths,
                ),
                ("event_modified_file_ids", request.event_modified_file_ids),
                (
                    "event_modified_folder_ids",
                    request.event_modified_folder_ids,
                ),
                ("shards", request.shards),
            ])?;
            ensure_event_scalars_default(request)
        }
        InventoryOperation::PendingCatalog => {
            ensure_ranges_default(&[
                ("managed_only_file_ids", request.managed_only_file_ids),
                ("managed_only_folder_ids", request.managed_only_folder_ids),
                ("previous_files", request.previous_files),
                ("previous_folders", request.previous_folders),
                ("event_upserted_files", request.event_upserted_files),
                ("event_upserted_folders", request.event_upserted_folders),
                ("event_removed_file_ids", request.event_removed_file_ids),
                ("event_removed_folder_ids", request.event_removed_folder_ids),
                ("event_removed_file_paths", request.event_removed_file_paths),
                (
                    "event_removed_folder_paths",
                    request.event_removed_folder_paths,
                ),
                ("event_modified_file_ids", request.event_modified_file_ids),
                (
                    "event_modified_folder_ids",
                    request.event_modified_folder_ids,
                ),
                ("shards", request.shards),
            ])?;
            ensure_event_scalars_default(request)
        }
        InventoryOperation::ShardPatch => ensure_ranges_default(&[
            ("roots", request.roots),
            ("managed_only_file_ids", request.managed_only_file_ids),
            ("managed_only_folder_ids", request.managed_only_folder_ids),
            ("shards", request.shards),
        ]),
        InventoryOperation::MergeShards => {
            ensure_ranges_default(&[
                ("roots", request.roots),
                ("files_by_id", request.files_by_id),
                ("folders_by_id", request.folders_by_id),
                ("managed_only_file_ids", request.managed_only_file_ids),
                ("managed_only_folder_ids", request.managed_only_folder_ids),
                ("previous_files", request.previous_files),
                ("previous_folders", request.previous_folders),
                ("event_upserted_files", request.event_upserted_files),
                ("event_upserted_folders", request.event_upserted_folders),
                ("event_removed_file_ids", request.event_removed_file_ids),
                ("event_removed_folder_ids", request.event_removed_folder_ids),
                ("event_removed_file_paths", request.event_removed_file_paths),
                (
                    "event_removed_folder_paths",
                    request.event_removed_folder_paths,
                ),
                ("event_modified_file_ids", request.event_modified_file_ids),
                (
                    "event_modified_folder_ids",
                    request.event_modified_folder_ids,
                ),
            ])?;
            ensure_event_scalars_default(request)
        }
    }
}

fn validate_shape(request: &InventoryComputeRequestV1) -> Result<(), InventoryComputeError> {
    let shape_ok = request.string_range_words.len() % STRING_RANGE_STRIDE == 0
        && request.uuid_words.len() % UUID_STRIDE == 0
        && request.root_words.len() % ROOT_STRIDE == 0
        && request.file_words.len() % RECORD_STRIDE == 0
        && request.folder_words.len() % RECORD_STRIDE == 0
        && request.entry_words.len() % ENTRY_STRIDE == 0
        && request.shard_words.len() % SHARD_STRIDE == 0;
    if !shape_ok {
        return Err(InventoryComputeError::InvalidRequest(
            "compact table shape mismatch".into(),
        ));
    }
    Ok(())
}

fn encode_components(
    output: &mut InventoryComputeResultV1,
    components: &InventoryCatalogComponents,
) -> Result<(), InventoryComputeError> {
    output.components_files = push_files(output, &components.files)?;
    output.components_folders = push_folders(output, &components.folders)?;
    output.components_entries = push_entries(output, &components.entries)?;
    Ok(())
}

fn compute_authoritative(
    request: &InventoryComputeRequestV1,
) -> Result<InventoryComputeResultV1, InventoryComputeError> {
    let roots = decode_roots(request, request.roots)?;
    let files_by_id = to_file_map(decode_files(request, request.files_by_id)?)?;
    let folders_by_id = to_folder_map(decode_folders(request, request.folders_by_id)?)?;
    let managed_only_file_ids = decode_uuid_set(request, request.managed_only_file_ids)?;
    let managed_only_folder_ids = decode_uuid_set(request, request.managed_only_folder_ids)?;
    let components = builders::build_authoritative_catalog_components(
        &roots,
        &files_by_id,
        &folders_by_id,
        &managed_only_file_ids,
        &managed_only_folder_ids,
    )?;
    let mut output = InventoryComputeResultV1 {
        operation: InventoryOperation::AuthoritativeCatalog.id(),
        ..Default::default()
    };
    encode_components(&mut output, &components)?;
    Ok(output)
}

fn compute_pending(
    request: &InventoryComputeRequestV1,
) -> Result<InventoryComputeResultV1, InventoryComputeError> {
    let roots = decode_roots(request, request.roots)?;
    if roots.len() != 1 {
        return Err(InventoryComputeError::InvalidRequest(
            "PendingCatalog requires exactly one root".into(),
        ));
    }
    let files_by_id = to_file_map(decode_files(request, request.files_by_id)?)?;
    let folders_by_id = to_folder_map(decode_folders(request, request.folders_by_id)?)?;
    let components =
        builders::build_pending_catalog_components(&roots[0], &files_by_id, &folders_by_id);
    let mut output = InventoryComputeResultV1 {
        operation: InventoryOperation::PendingCatalog.id(),
        ..Default::default()
    };
    encode_components(&mut output, &components)?;
    Ok(output)
}

fn compute_shard_patch(
    request: &InventoryComputeRequestV1,
) -> Result<InventoryComputeResultV1, InventoryComputeError> {
    let previous_files = decode_files(request, request.previous_files)?;
    let previous_folders = decode_folders(request, request.previous_folders)?;
    let files_by_id = to_file_map(decode_files(request, request.files_by_id)?)?;
    let folders_by_id = to_folder_map(decode_folders(request, request.folders_by_id)?)?;
    let event = InventoryAppliedIndexBatchEvent {
        root_id: uuid_from_words(request.event_root_id_hi, request.event_root_id_lo),
        upserted_files: decode_files(request, request.event_upserted_files)?,
        upserted_folders: decode_folders(request, request.event_upserted_folders)?,
        removed_file_ids: decode_uuid_list(request, request.event_removed_file_ids)?,
        removed_folder_ids: decode_uuid_list(request, request.event_removed_folder_ids)?,
        removed_file_paths: decode_string_list(request, request.event_removed_file_paths)?,
        removed_folder_paths: decode_string_list(request, request.event_removed_folder_paths)?,
        modified_file_ids: decode_uuid_list(request, request.event_modified_file_ids)?,
        modified_folder_ids: decode_uuid_list(request, request.event_modified_folder_ids)?,
    };
    let max_logical_mutation_count = usize_word(request.max_logical_mutation_count)?;
    let patch = builders::build_root_catalog_shard_patch(
        &event,
        &previous_files,
        &previous_folders,
        &files_by_id,
        &folders_by_id,
        max_logical_mutation_count,
    )?;
    let mut output = InventoryComputeResultV1 {
        operation: InventoryOperation::ShardPatch.id(),
        ..Default::default()
    };
    match patch {
        None => {
            output.shard_patch_outcome = InventoryShardPatchOutcomeTag::NotPatchable as u16;
        }
        Some(patch) => {
            output.shard_patch_outcome = InventoryShardPatchOutcomeTag::Patched as u16;
            output.shard_patch_files = push_files(&mut output, &patch.files)?;
            output.shard_patch_folders = push_folders(&mut output, &patch.folders)?;
            output.shard_patch_logical_mutation_count = word(patch.logical_mutation_count)?;
            let mut changed_ids: Vec<InventoryUuid> =
                patch.path_index_changed_file_ids.into_iter().collect();
            changed_ids.sort();
            output.shard_patch_changed_file_ids = push_uuid_list(&mut output, &changed_ids)?;
        }
    }
    Ok(output)
}

fn compute_merge(
    request: &InventoryComputeRequestV1,
) -> Result<InventoryComputeResultV1, InventoryComputeError> {
    let (start, end) = checked_range(request.shard_words.len() / SHARD_STRIDE, request.shards)?;
    let mut shards = Vec::with_capacity(end - start);
    for row_index in start..end {
        let base = row_index * SHARD_STRIDE;
        let row = request
            .shard_words
            .get(base..base + SHARD_STRIDE)
            .ok_or_else(|| {
                InventoryComputeError::InvalidRequest("shard descriptor out of range".into())
            })?;
        let files_range = InventoryTableRange {
            start: row[0],
            count: row[1],
        };
        let entries_range = InventoryTableRange {
            start: row[2],
            count: row[3],
        };
        let files = decode_files(request, files_range)?;
        let entries = decode_entries(request, entries_range)?;
        if files.len() != entries.len() {
            return Err(InventoryComputeError::InvalidRequest(
                "shard files/entries length mismatch".into(),
            ));
        }
        shards.push((files, entries));
    }
    let (files, entries) = builders::merge_root_catalog_shard_file_entry_lists(&shards);
    let mut output = InventoryComputeResultV1 {
        operation: InventoryOperation::MergeShards.id(),
        ..Default::default()
    };
    output.merged_files = push_files(&mut output, &files)?;
    output.merged_entries = push_entries(&mut output, &entries)?;
    Ok(output)
}

#[derive(Default)]
pub struct InventoryComputeService;

impl InventoryComputeService {
    pub fn compute(
        &self,
        request: &InventoryComputeRequestV1,
    ) -> Result<InventoryComputeResultV1, InventoryComputeError> {
        self.compute_with_cancellation(request, None)
    }

    pub fn compute_with_cancellation(
        &self,
        request: &InventoryComputeRequestV1,
        cancellation: Option<&crate::LeafCancellation>,
    ) -> Result<InventoryComputeResultV1, InventoryComputeError> {
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(InventoryComputeError::Cancelled);
        }
        if request.contract_version != INVENTORY_CONTRACT_VERSION_V1 {
            return Err(InventoryComputeError::InvalidRequest(format!(
                "unknown contract version {}",
                request.contract_version
            )));
        }
        validate_shape(request)?;
        let operation = InventoryOperation::from_id(request.operation).ok_or_else(|| {
            InventoryComputeError::InvalidRequest(format!(
                "unknown operation {}",
                request.operation
            ))
        })?;
        validate_operation_fields(request, operation)?;
        let result = match operation {
            InventoryOperation::AuthoritativeCatalog => compute_authoritative(request),
            InventoryOperation::PendingCatalog => compute_pending(request),
            InventoryOperation::ShardPatch => compute_shard_patch(request),
            InventoryOperation::MergeShards => compute_merge(request),
        }?;
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(InventoryComputeError::Cancelled);
        }
        Ok(result)
    }
}

impl InventoryComputeResultV1 {
    pub fn decode_files(
        &self,
        range: InventoryTableRange,
    ) -> Result<Vec<InventoryFileRecord>, InventoryComputeError> {
        decode_files(self, range)
    }
    pub fn decode_folders(
        &self,
        range: InventoryTableRange,
    ) -> Result<Vec<InventoryFolderRecord>, InventoryComputeError> {
        decode_folders(self, range)
    }
    pub fn decode_entries(
        &self,
        range: InventoryTableRange,
    ) -> Result<Vec<InventorySearchCatalogEntry>, InventoryComputeError> {
        decode_entries(self, range)
    }
    pub fn decode_uuid_list(
        &self,
        range: InventoryTableRange,
    ) -> Result<Vec<InventoryUuid>, InventoryComputeError> {
        decode_uuid_list(self, range)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uuid(byte: u8) -> InventoryUuid {
        let mut bytes = [0u8; 16];
        bytes[15] = byte;
        bytes
    }

    fn file(
        id: InventoryUuid,
        root_id: InventoryUuid,
        rel: &str,
        full: &str,
    ) -> InventoryFileRecord {
        InventoryFileRecord {
            id,
            root_id,
            name: rel.to_owned(),
            relative_path: rel.to_owned(),
            standardized_relative_path: rel.to_owned(),
            full_path: full.to_owned(),
            standardized_full_path: full.to_owned(),
            parent_folder_id: None,
            modification_date: Some(42.5),
        }
    }

    #[test]
    fn authoritative_round_trip_single_root() {
        let root_id = uuid(1);
        let root = InventoryRootRecord {
            id: root_id,
            name: "Root".to_owned(),
            standardized_full_path: "/root".to_owned(),
        };
        let f1 = file(uuid(10), root_id, "b.swift", "/root/b.swift");
        let f2 = file(uuid(11), root_id, "a.swift", "/root/a.swift");

        let mut request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            ..Default::default()
        };
        request.roots = request.push_roots(&[root]).unwrap();
        request.files_by_id = request.push_files(&[f1.clone(), f2.clone()]).unwrap();
        request.folders_by_id = request.push_folders(&[]).unwrap();
        request.managed_only_file_ids = request.push_uuid_ids(&[]).unwrap();
        request.managed_only_folder_ids = request.push_uuid_ids(&[]).unwrap();

        let response = InventoryComputeService.compute(&request).unwrap();
        assert_eq!(
            response.operation,
            InventoryOperation::AuthoritativeCatalog.id()
        );
        let files = response.decode_files(response.components_files).unwrap();
        assert_eq!(
            files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![f2.id, f1.id]
        );
        let entries = response
            .decode_entries(response.components_entries)
            .unwrap();
        assert_eq!(entries[0].display_path, "Root/a.swift");
        assert_eq!(files[0].modification_date, Some(42.5));
    }

    #[test]
    fn shard_patch_not_patchable_outcome_is_distinct_from_decode_error() {
        let root_id = uuid(1);
        let mut request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::ShardPatch.id(),
            ..Default::default()
        };
        request.set_event_root_id(&root_id);
        // Upserted file whose root_id disagrees with the event root -> Swift returns nil.
        let mismatched = file(uuid(5), uuid(99), "a.swift", "/root/a.swift");
        request.event_upserted_files = request.push_files(&[mismatched.clone()]).unwrap();
        request.files_by_id = request.push_files(&[mismatched]).unwrap();
        request.max_logical_mutation_count = 1;

        let response = InventoryComputeService.compute(&request).unwrap();
        assert_eq!(
            response.shard_patch_outcome,
            InventoryShardPatchOutcomeTag::NotPatchable as u16
        );
    }

    #[test]
    fn merge_round_trip_two_shards() {
        let root_id = uuid(1);
        let f_a = file(uuid(1), root_id, "a.swift", "/root/a.swift");
        let f_b = file(uuid(2), root_id, "b.swift", "/root/b.swift");
        let root = InventoryRootRecord {
            id: root_id,
            name: "Root".to_owned(),
            standardized_full_path: "/root".to_owned(),
        };
        let e_a = InventorySearchCatalogEntry::new(&f_a, &root);
        let e_b = InventorySearchCatalogEntry::new(&f_b, &root);

        let mut request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::MergeShards.id(),
            ..Default::default()
        };
        request.shards = request
            .push_shards(&[
                (vec![f_b.clone()], vec![e_b.clone()]),
                (vec![f_a.clone()], vec![e_a.clone()]),
            ])
            .unwrap();

        let response = InventoryComputeService.compute(&request).unwrap();
        let files = response.decode_files(response.merged_files).unwrap();
        assert_eq!(
            files.iter().map(|f| f.id).collect::<Vec<_>>(),
            vec![f_a.id, f_b.id]
        );
    }

    #[test]
    fn decode_rejects_out_of_bounds_range() {
        let request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            roots: InventoryTableRange { start: 0, count: 1 },
            ..Default::default()
        };
        let error = InventoryComputeService.compute(&request).unwrap_err();
        assert!(matches!(error, InventoryComputeError::InvalidRequest(_)));
    }

    #[test]
    fn decode_string_rejects_index_that_would_overflow_range_end() {
        // A single file row whose `name` string-pool index is `u64::MAX - 1`, which overflows
        // when the decoder multiplies by STRING_RANGE_STRIDE and adds the stride to form the
        // lookup range end. Must be rejected as InvalidRequest, not panic.
        let mut words = vec![0u64; RECORD_STRIDE];
        words[4] = u64::MAX - 1;
        let request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            files_by_id: InventoryTableRange { start: 0, count: 1 },
            file_words: words,
            ..Default::default()
        };
        let error = InventoryComputeService.compute(&request).unwrap_err();
        assert!(matches!(error, InventoryComputeError::InvalidRequest(_)));
    }

    #[test]
    fn validate_operation_fields_rejects_populated_unused_field() {
        let mut request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            ..Default::default()
        };
        request.roots = request.push_roots(&[]).unwrap();
        request.files_by_id = request.push_files(&[]).unwrap();
        request.folders_by_id = request.push_folders(&[]).unwrap();
        request.managed_only_file_ids = request.push_uuid_ids(&[]).unwrap();
        request.managed_only_folder_ids = request.push_uuid_ids(&[]).unwrap();
        // AuthoritativeCatalog never reads `shards`; a populated value here must be rejected
        // rather than silently ignored.
        request.shards = InventoryTableRange { start: 0, count: 1 };

        let error = InventoryComputeService.compute(&request).unwrap_err();
        assert!(matches!(error, InventoryComputeError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_noncanonical_absent_parent_folder_payload() {
        // Presence flag says "absent" (row word 9 == 0) but a payload word is non-zero.
        let mut row = vec![0u64; RECORD_STRIDE];
        row[10] = 7;
        let request = InventoryComputeRequestV1 {
            contract_version: INVENTORY_CONTRACT_VERSION_V1,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            string_range_words: vec![0, 0],
            files_by_id: InventoryTableRange { start: 0, count: 1 },
            file_words: row,
            ..Default::default()
        };
        let error = InventoryComputeService.compute(&request).unwrap_err();
        assert!(matches!(error, InventoryComputeError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_unknown_contract_version() {
        let request = InventoryComputeRequestV1 {
            contract_version: 9,
            operation: InventoryOperation::AuthoritativeCatalog.id(),
            ..Default::default()
        };
        let error = InventoryComputeService.compute(&request).unwrap_err();
        assert!(matches!(error, InventoryComputeError::InvalidRequest(_)));
    }
}
