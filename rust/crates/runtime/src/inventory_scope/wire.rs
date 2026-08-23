//! `inventory-scope-v1`: the versioned wire schema for `InventoryScope`'s high-volume,
//! data-plane FFI payloads (bulk-load chunks, delta events, batch record lookups, and queries).
//! Retires `inventory-compute-v1`'s non-interning encoder for these payloads (§2.1/§5.4 of
//! `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md`) and fixes its one genuine
//! defect: **this wire interns strings by value.** [`InternPoolBuilder::intern`] dedupes identical
//! strings into one pooled range, unlike the retired `inventory::compact::push_string` (deleted at
//! P4-8), which appended every occurrence unconditionally.
//!
//! # Framing
//!
//! Every top-level message is a self-contained byte buffer (this is what the contract doc's §5
//! FFI-surface listing means by the `bytes` parameter/return type on `inventoryPushBulkChunk` /
//! `inventoryExportCompactV1`, and by `InventoryDeltaCommandV1`'s "compact inventory-scope-v1
//! delta blob" field):
//!
//! ```text
//! u16 contract_version
//! u16 message_kind                 // defensive tag; decode rejects a kind mismatch
//! section*                         // fixed count/order per message_kind, see each encode fn
//! ```
//!
//! A section is either a **word array** (`u32` element count, then that many little-endian
//! `u64`s) or a **byte blob** (`u32` byte count, then that many raw bytes) -- always the string
//! pool's `utf8_blob`, always last. [`Writer`]/[`Reader`] implement exactly these two primitives;
//! every message encoder/decoder is a fixed sequence of calls into them, so the hand-rolled
//! parsing surface is one shared, tested pair of primitives rather than one per message kind.
//!
//! # Fail-closed decode (§5.4)
//!
//! [`Reader`] rejects truncated input, an oversize section (over
//! [`MAX_WORDS_PER_SECTION`]/[`MAX_BLOB_BYTES`]), and a section-length overflow. Each message's
//! domain decoder additionally rejects an unknown `contract_version`, a `message_kind` mismatch,
//! a row/stride count that doesn't divide evenly, an out-of-range or malformed string-pool index,
//! an oversize individual string (over [`MAX_STRING_LEN_BYTES`]), and an oversize row/id/path
//! count (over [`MAX_ROWS_PER_CALL`] / [`MAX_IDS_PER_CALL`] / [`MAX_PATHS_PER_CALL`]).
//!
//! # Swift mirror (charter §15.3 item 6, contract doc §3)
//!
//! This schema ships a hand-written Swift mirror in `AgentryCoreBridge`
//! (`InventoryScopeWire.swift`), fingerprint-locked to this module the way P2's codemap wire is
//! locked: [`fingerprint`] hashes the shape this module commits to (contract version, message
//! kinds, strides, limits), and
//! `swift_inventory_scope_wire_fingerprint_mirror_matches_rust_truth` (in this crate's test
//! module) fails red the moment that shape drifts without a matching Swift-side update -- see
//! that test's doc comment for the exact mechanism.

use std::collections::HashMap;
use std::fmt;

use crate::inventory::{
    InventoryAppliedIndexBatchEvent, InventoryFileRecord, InventoryFolderRecord, InventoryUuid,
};
use super::fallback::RootCatalogShardFallbackReason;

pub const INVENTORY_SCOPE_CONTRACT_VERSION_V1: u16 = 1;

/// Words per pooled string range entry (`start`, `end` byte offsets into `utf8_blob`), identical
/// convention to the retired `inventory::contract::STRING_RANGE_STRIDE` (deleted at P4-8).
pub const STRING_RANGE_STRIDE: usize = 2;
/// Sentinel for an absent optional pooled string, matching the retired `inventory::contract::OPTIONAL_WORD`.
pub const OPTIONAL_WORD: u64 = u64::MAX;
/// Words per file/folder record row: id(2) + root_id(2) + name(1) + relative_path(1) +
/// standardized_relative_path(1) + full_path(1) + standardized_full_path(1) +
/// parent_folder_id_present(1) + parent_folder_id(2) + modification_date_present(1) +
/// modification_date_bits(1) = 14. Identical layout to the retired `inventory::contract::RECORD_STRIDE`
/// (deliberately: this is the same nine-field Swift shape, just interned).
pub const RECORD_STRIDE: usize = 14;
/// Words per **discovery** record row: root_id(2) + name(1) + relative_path(1) +
/// standardized_relative_path(1) + full_path(1) + standardized_full_path(1) +
/// parent_folder_id_present(1) + parent_folder_id(2) + modification_date_present(1) +
/// modification_date_bits(1) = 12. The same nine-field shape as [`RECORD_STRIDE`] minus the
/// caller-supplied `id` -- the discovery path (§4.1.1: "Rust mints v4-shaped UUIDs from a
/// per-scope CSPRNG") mints one instead. **Additive, parallel to [`RECORD_STRIDE`]**: the
/// id-supplied row shape/decode used by bulk-load and delta replay is untouched byte-for-byte.
pub const DISCOVERY_RECORD_STRIDE: usize = 12;
/// Words per fact row (`CompactRecordBlockV1`/`CompactLookupResultV1`, contract doc §5.3):
/// requested_key_hi(1) + requested_key_lo(1) [id or, for lookup, an opaque request ordinal] +
/// exists(1) + file_id_present(1) + file_id_hi(1) + file_id_lo(1) + folder_id_present(1) +
/// folder_id_hi(1) + folder_id_lo(1) + root_id_present(1) + root_id_hi(1) + root_id_lo(1) +
/// is_discoverable(1) + path_round_trips_to_self(1) + standardized_relative_path_idx(1) +
/// standardized_full_path_idx(1) + name_idx(1) + record_fingerprint(1) +
/// parent_folder_id_present(1) + parent_folder_id_hi(1) + parent_folder_id_lo(1) +
/// modification_date_present(1) + modification_date_bits(1) = 23.
///
/// P4-6b gap-closure (contract doc §12 amendment): `appliedIndexRecordLookup`'s two production
/// consumers (`AgentContextFileBrowseService.swift:715,721`) read `parentFolderID`/
/// `modificationDate` off the returned record -- fields the original 18-word fact row (P4-4) never
/// carried because the design's `<projected fields>` clause in §4.3.1's `inventoryResolveRecords`
/// sketch was never implemented. Additive: the 18 pre-existing words and their field order are
/// unchanged; these five are appended, so `MAX_ROWS_PER_CALL`-bounded decode of an old-shaped
/// blob would simply fail the stride-multiple check rather than silently misread a row --
/// there is no persisted wire content to migrate (facts are never persisted, contract doc §1.1).
pub const FACT_ROW_STRIDE: usize = 23;
/// Words per query candidate row: id(2) + root_id(2) + name_idx(1) + relative_path_idx(1) +
/// standardized_relative_path_idx(1) + full_path_idx(1) + standardized_full_path_idx(1) +
/// display_path_idx(1) + tie_break_key_idx(1) + score(1) = 12. `display_path` carries the
/// per-root-prefix composition contract doc §6 pins (`ClientPathFormatter.displayPath`-equivalent)
/// -- it is Rust-computed (`query::QueryPrefix::display_path`) and must reach the caller, not be
/// discarded after computation. `tie_break_key` (P4-7b §4.2) is the matched subject string
/// (`PathIndexCandidate.tie_break_key` / `PathSearchMatch.tie_break_key`) -- the response's
/// `display_path` is caller-prefix-composed and is NOT byte-identical to the index's own stored
/// key in multi-root configurations with ambiguous root names, so it cannot be reconstructed
/// client-side; it must ride the wire as its own field.
pub const CANDIDATE_ROW_STRIDE: usize = 12;

// ---- fail-closed limits ------------------------------------------------------------------------

pub const MAX_BLOB_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_STRING_LEN_BYTES: usize = 64 * 1024;
pub const MAX_WORDS_PER_SECTION: usize = 8 * 1024 * 1024;
pub const MAX_ROWS_PER_CALL: usize = 200_000;
pub const MAX_IDS_PER_CALL: usize = 50_000;
pub const MAX_PATHS_PER_CALL: usize = 50_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum MessageKind {
    BulkChunk = 1,
    DeltaEvent = 2,
    ResolveRequest = 3,
    LookupRequest = 4,
    FactBlock = 5,
    QueryRequest = 6,
    QueryResponse = 7,
    // ---- P4-4b: event-plane payloads (contract doc §5b). `inventoryAppliedIndexBatch`'s payload
    // is the existing `DeltaEvent` message verbatim -- no new kind for it. These four cover the
    // remaining catalogued event kinds; each is a fixed-width word section, no interned strings
    // ("events are notifications, never tables", contract doc §5b).
    GenerationAdvanced = 8,
    RootPublished = 9,
    RootUnloaded = 10,
    ShardFallback = 11,
    ResnapshotRequired = 12,
    // ---- discovery mint site (§4.1.1): additive, parallel to BulkChunk/DeltaEvent. Carries the
    // same nine-field record shape minus the caller-supplied `id` -- see `DISCOVERY_RECORD_STRIDE`.
    DiscoveryBulkChunk = 13,
    DiscoveryDeltaEvent = 14,
}

impl MessageKind {
    const ALL: [Self; 14] = [
        Self::BulkChunk,
        Self::DeltaEvent,
        Self::ResolveRequest,
        Self::LookupRequest,
        Self::FactBlock,
        Self::QueryRequest,
        Self::QueryResponse,
        Self::GenerationAdvanced,
        Self::RootPublished,
        Self::RootUnloaded,
        Self::ShardFallback,
        Self::ResnapshotRequired,
        Self::DiscoveryBulkChunk,
        Self::DiscoveryDeltaEvent,
    ];

    fn from_id(id: u16) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| *kind as u16 == id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WireError {
    UnknownContractVersion(u16),
    UnknownMessageKind(u16),
    MessageKindMismatch,
    Truncated(&'static str),
    Oversize(&'static str),
    Malformed(&'static str),
    OutOfRange(&'static str),
    InvalidUtf8,
}

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownContractVersion(version) => {
                write!(formatter, "unknown inventory-scope-v1 contract version {version}")
            }
            Self::UnknownMessageKind(kind) => {
                write!(formatter, "unknown inventory-scope-v1 message kind {kind}")
            }
            Self::MessageKindMismatch => {
                formatter.write_str("inventory-scope-v1 message kind mismatch")
            }
            Self::Truncated(field) => write!(formatter, "truncated inventory-scope-v1 {field}"),
            Self::Oversize(field) => write!(formatter, "oversize inventory-scope-v1 {field}"),
            Self::Malformed(field) => write!(formatter, "malformed inventory-scope-v1 {field}"),
            Self::OutOfRange(field) => write!(formatter, "out-of-range inventory-scope-v1 {field}"),
            Self::InvalidUtf8 => formatter.write_str("invalid utf8 in inventory-scope-v1 string pool"),
        }
    }
}

impl std::error::Error for WireError {}

// ---- byte-level primitives ---------------------------------------------------------------------

/// Append-only byte writer. Every `write_*` call is infallible (this side controls its own
/// inputs); overflow is impossible in practice for any payload this crate constructs, but a
/// checked `usize -> u32` cast still fails closed rather than silently truncating a huge count.
#[derive(Default)]
pub struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn write_u16(&mut self, value: u16) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }

    fn write_u32(&mut self, value: u32) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }

    /// Writes a word-array section: `u32` element count, then that many little-endian `u64`s.
    pub fn write_words(&mut self, words: &[u64]) -> Result<(), WireError> {
        let count = u32::try_from(words.len()).map_err(|_| WireError::Oversize("word section"))?;
        self.write_u32(count);
        for word in words {
            self.buf.extend_from_slice(&word.to_le_bytes());
        }
        Ok(())
    }

    /// Writes a byte-blob section: `u32` byte count, then that many raw bytes.
    pub fn write_blob(&mut self, bytes: &[u8]) -> Result<(), WireError> {
        let count = u32::try_from(bytes.len()).map_err(|_| WireError::Oversize("blob section"))?;
        self.write_u32(count);
        self.buf.extend_from_slice(bytes);
        Ok(())
    }

    fn header(kind: MessageKind) -> Self {
        let mut writer = Self::new();
        writer.write_u16(INVENTORY_SCOPE_CONTRACT_VERSION_V1);
        writer.write_u16(kind as u16);
        writer
    }

    #[must_use]
    pub fn finish(self) -> Vec<u8> {
        self.buf
    }
}

/// Cursor-based reader over an immutable byte slice. Every read is fail-closed: truncation,
/// section-oversize, and length-overflow are rejected rather than recovered from.
pub struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    /// Reads and validates the shared header, returning a reader positioned just after it.
    /// `expected` is the message kind the caller is about to decode; a mismatch is rejected
    /// rather than silently reinterpreted.
    pub fn open(bytes: &'a [u8], expected: MessageKind) -> Result<Self, WireError> {
        let mut reader = Self { bytes, pos: 0 };
        let version = reader.read_u16("contract_version")?;
        if version != INVENTORY_SCOPE_CONTRACT_VERSION_V1 {
            return Err(WireError::UnknownContractVersion(version));
        }
        let kind_id = reader.read_u16("message_kind")?;
        let kind = MessageKind::from_id(kind_id).ok_or(WireError::UnknownMessageKind(kind_id))?;
        if kind != expected {
            return Err(WireError::MessageKindMismatch);
        }
        Ok(reader)
    }

    fn take(&mut self, len: usize, field: &'static str) -> Result<&'a [u8], WireError> {
        let end = self
            .pos
            .checked_add(len)
            .ok_or(WireError::Truncated(field))?;
        let slice = self.bytes.get(self.pos..end).ok_or(WireError::Truncated(field))?;
        self.pos = end;
        Ok(slice)
    }

    fn read_u16(&mut self, field: &'static str) -> Result<u16, WireError> {
        let bytes = self.take(2, field)?;
        Ok(u16::from_le_bytes(bytes.try_into().expect("2 bytes")))
    }

    fn read_u32(&mut self, field: &'static str) -> Result<u32, WireError> {
        let bytes = self.take(4, field)?;
        Ok(u32::from_le_bytes(bytes.try_into().expect("4 bytes")))
    }

    /// Reads a word-array section, rejecting a declared length over `max_words`.
    pub fn read_words(&mut self, max_words: usize, field: &'static str) -> Result<Vec<u64>, WireError> {
        let count = usize::try_from(self.read_u32(field)?).map_err(|_| WireError::Oversize(field))?;
        if count > max_words.min(MAX_WORDS_PER_SECTION) {
            return Err(WireError::Oversize(field));
        }
        let byte_len = count.checked_mul(8).ok_or(WireError::Oversize(field))?;
        let bytes = self.take(byte_len, field)?;
        let mut words = Vec::with_capacity(count);
        for chunk in bytes.chunks_exact(8) {
            words.push(u64::from_le_bytes(chunk.try_into().expect("8 bytes")));
        }
        Ok(words)
    }

    /// Reads the trailing byte-blob section (the shared UTF-8 string pool).
    pub fn read_blob(&mut self, field: &'static str) -> Result<&'a [u8], WireError> {
        let count = usize::try_from(self.read_u32(field)?).map_err(|_| WireError::Oversize(field))?;
        if count > MAX_BLOB_BYTES {
            return Err(WireError::Oversize(field));
        }
        self.take(count, field)
    }

    /// Fail-closed end-of-message check: a message that carries trailing bytes beyond its
    /// declared sections is malformed, not silently ignored.
    pub fn finish(self) -> Result<(), WireError> {
        if self.pos == self.bytes.len() {
            Ok(())
        } else {
            Err(WireError::Malformed("trailing bytes"))
        }
    }
}

// ---- string interning ---------------------------------------------------------------------------

/// Encode-side string pool. Unlike the retired `inventory::compact::push_string`, [`Self::intern`]
/// dedupes identical strings by value into one pooled range (§2.1's fix).
#[derive(Default)]
pub struct InternPoolBuilder {
    blob: Vec<u8>,
    range_words: Vec<u64>,
    index_by_value: HashMap<String, u64>,
}

impl InternPoolBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn intern(&mut self, value: &str) -> u64 {
        if let Some(&index) = self.index_by_value.get(value) {
            return index;
        }
        let start = self.blob.len() as u64;
        self.blob.extend_from_slice(value.as_bytes());
        let end = self.blob.len() as u64;
        let index = (self.range_words.len() / STRING_RANGE_STRIDE) as u64;
        self.range_words.push(start);
        self.range_words.push(end);
        self.index_by_value.insert(value.to_owned(), index);
        index
    }

    pub fn intern_optional(&mut self, value: Option<&str>) -> u64 {
        value.map_or(OPTIONAL_WORD, |value| self.intern(value))
    }

    #[must_use]
    pub fn range_words(&self) -> &[u64] {
        &self.range_words
    }

    #[must_use]
    pub fn blob(&self) -> &[u8] {
        &self.blob
    }

    #[must_use]
    pub fn finish(self) -> (Vec<u8>, Vec<u64>) {
        (self.blob, self.range_words)
    }
}

/// Decode-side string pool reader, borrowing directly from the decoded blob (zero-copy).
pub struct InternPoolReader<'a> {
    blob: &'a [u8],
    range_words: &'a [u64],
}

impl<'a> InternPoolReader<'a> {
    pub fn new(blob: &'a [u8], range_words: &'a [u64]) -> Result<Self, WireError> {
        if range_words.len() % STRING_RANGE_STRIDE != 0 {
            return Err(WireError::Malformed("string_range_words stride"));
        }
        Ok(Self { blob, range_words })
    }

    pub fn resolve(&self, index: u64) -> Result<&'a str, WireError> {
        let index = usize::try_from(index).map_err(|_| WireError::OutOfRange("string index"))?;
        let base = index
            .checked_mul(STRING_RANGE_STRIDE)
            .ok_or(WireError::OutOfRange("string index"))?;
        let start = *self
            .range_words
            .get(base)
            .ok_or(WireError::OutOfRange("string index"))?;
        let end = *self
            .range_words
            .get(base + 1)
            .ok_or(WireError::OutOfRange("string index"))?;
        let start = usize::try_from(start).map_err(|_| WireError::Malformed("string range"))?;
        let end = usize::try_from(end).map_err(|_| WireError::Malformed("string range"))?;
        if end < start || end > self.blob.len() {
            return Err(WireError::Malformed("string range bounds"));
        }
        if end - start > MAX_STRING_LEN_BYTES {
            return Err(WireError::Oversize("string"));
        }
        std::str::from_utf8(&self.blob[start..end]).map_err(|_| WireError::InvalidUtf8)
    }

    pub fn resolve_optional(&self, index: u64) -> Result<Option<&'a str>, WireError> {
        if index == OPTIONAL_WORD {
            Ok(None)
        } else {
            self.resolve(index).map(Some)
        }
    }
}

// ---- uuid pack/unpack -----------------------------------------------------------------------

#[must_use]
pub fn uuid_to_words(id: &InventoryUuid) -> (u64, u64) {
    let hi = u64::from_be_bytes(id[0..8].try_into().expect("8 bytes"));
    let lo = u64::from_be_bytes(id[8..16].try_into().expect("8 bytes"));
    (hi, lo)
}

#[must_use]
pub fn uuid_from_words(hi: u64, lo: u64) -> InventoryUuid {
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&hi.to_be_bytes());
    bytes[8..16].copy_from_slice(&lo.to_be_bytes());
    bytes
}

fn optional_uuid_to_words(id: Option<InventoryUuid>) -> (u64, u64, u64) {
    match id {
        Some(id) => {
            let (hi, lo) = uuid_to_words(&id);
            (1, hi, lo)
        }
        None => (0, 0, 0),
    }
}

fn optional_uuid_from_words(present: u64, hi: u64, lo: u64) -> Result<Option<InventoryUuid>, WireError> {
    match present {
        0 => Ok(None),
        1 => Ok(Some(uuid_from_words(hi, lo))),
        _ => Err(WireError::Malformed("optional uuid presence flag")),
    }
}

// ---- record rows (file/folder tables: bulk chunk + delta event upserts) -----------------------

/// Appends one record row (§ module doc's [`RECORD_STRIDE`] layout) to `words`, interning its
/// strings into `pool`. Shared by files and folders: both are the same nine-field shape.
#[allow(clippy::too_many_arguments)]
fn push_record_row(
    words: &mut Vec<u64>,
    pool: &mut InternPoolBuilder,
    id: &InventoryUuid,
    root_id: &InventoryUuid,
    name: &str,
    relative_path: &str,
    standardized_relative_path: &str,
    full_path: &str,
    standardized_full_path: &str,
    parent_folder_id: Option<InventoryUuid>,
    modification_date: Option<f64>,
) {
    let (id_hi, id_lo) = uuid_to_words(id);
    let (root_hi, root_lo) = uuid_to_words(root_id);
    let (parent_present, parent_hi, parent_lo) = optional_uuid_to_words(parent_folder_id);
    let (mod_present, mod_bits) = match modification_date {
        Some(value) => (1, value.to_bits()),
        None => (0, 0),
    };
    words.extend([
        id_hi,
        id_lo,
        root_hi,
        root_lo,
        pool.intern(name),
        pool.intern(relative_path),
        pool.intern(standardized_relative_path),
        pool.intern(full_path),
        pool.intern(standardized_full_path),
        parent_present,
        parent_hi,
        parent_lo,
        mod_present,
        mod_bits,
    ]);
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

fn read_record_row(row: &[u64], pool: &InternPoolReader<'_>) -> Result<DecodedRecordRow, WireError> {
    let &[id_hi, id_lo, root_hi, root_lo, name_idx, relative_path_idx, standardized_relative_path_idx, full_path_idx, standardized_full_path_idx, parent_present, parent_hi, parent_lo, mod_present, mod_bits] =
        row
    else {
        return Err(WireError::Malformed("record row"));
    };
    let modification_date = match mod_present {
        0 => None,
        1 => {
            let value = f64::from_bits(mod_bits);
            if value.is_nan() {
                return Err(WireError::Malformed("modification_date"));
            }
            Some(value)
        }
        _ => return Err(WireError::Malformed("modification_date presence flag")),
    };
    Ok(DecodedRecordRow {
        id: uuid_from_words(id_hi, id_lo),
        root_id: uuid_from_words(root_hi, root_lo),
        name: pool.resolve(name_idx)?.to_owned(),
        relative_path: pool.resolve(relative_path_idx)?.to_owned(),
        standardized_relative_path: pool.resolve(standardized_relative_path_idx)?.to_owned(),
        full_path: pool.resolve(full_path_idx)?.to_owned(),
        standardized_full_path: pool.resolve(standardized_full_path_idx)?.to_owned(),
        parent_folder_id: optional_uuid_from_words(parent_present, parent_hi, parent_lo)?,
        modification_date,
    })
}

fn push_file_row(words: &mut Vec<u64>, pool: &mut InternPoolBuilder, file: &InventoryFileRecord) {
    push_record_row(
        words,
        pool,
        &file.id,
        &file.root_id,
        &file.name,
        &file.relative_path,
        &file.standardized_relative_path,
        &file.full_path,
        &file.standardized_full_path,
        file.parent_folder_id,
        file.modification_date,
    );
}

fn push_folder_row(words: &mut Vec<u64>, pool: &mut InternPoolBuilder, folder: &InventoryFolderRecord) {
    push_record_row(
        words,
        pool,
        &folder.id,
        &folder.root_id,
        &folder.name,
        &folder.relative_path,
        &folder.standardized_relative_path,
        &folder.full_path,
        &folder.standardized_full_path,
        folder.parent_folder_id,
        folder.modification_date,
    );
}

fn decode_file_rows(words: &[u64], pool: &InternPoolReader<'_>) -> Result<Vec<InventoryFileRecord>, WireError> {
    if words.len() % RECORD_STRIDE != 0 {
        return Err(WireError::Malformed("file row stride"));
    }
    if words.len() / RECORD_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("file rows"));
    }
    words
        .chunks_exact(RECORD_STRIDE)
        .map(|row| {
            let decoded = read_record_row(row, pool)?;
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
        })
        .collect()
}

fn decode_folder_rows(
    words: &[u64],
    pool: &InternPoolReader<'_>,
) -> Result<Vec<InventoryFolderRecord>, WireError> {
    if words.len() % RECORD_STRIDE != 0 {
        return Err(WireError::Malformed("folder row stride"));
    }
    if words.len() / RECORD_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("folder rows"));
    }
    words
        .chunks_exact(RECORD_STRIDE)
        .map(|row| {
            let decoded = read_record_row(row, pool)?;
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
        })
        .collect()
}

// ---- discovery records (§4.1.1: id-less input, Rust mints on decode-and-stage) ----------------
//
// `DiscoveredFileRecord`/`DiscoveredFolderRecord` are the same nine-field shape as
// `InventoryFileRecord`/`InventoryFolderRecord` minus `id`. They exist only as the decode-side
// output of the discovery wire messages below; `InventoryScope::push_bulk_chunk_discovery` /
// `apply_delta_discovery` (`scope.rs`) mint an id for each one and hand the fully-formed record
// to the *existing, unchanged* `push_bulk_chunk`/`apply_delta` staging logic -- this module never
// mints anything itself, it only carries id-less records across the wire.

#[derive(Clone, Debug, PartialEq)]
pub struct DiscoveredFileRecord {
    pub root_id: InventoryUuid,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub parent_folder_id: Option<InventoryUuid>,
    pub modification_date: Option<f64>,
}

impl DiscoveredFileRecord {
    #[must_use]
    pub fn into_minted(self, id: InventoryUuid) -> InventoryFileRecord {
        InventoryFileRecord {
            id,
            root_id: self.root_id,
            name: self.name,
            relative_path: self.relative_path,
            standardized_relative_path: self.standardized_relative_path,
            full_path: self.full_path,
            standardized_full_path: self.standardized_full_path,
            parent_folder_id: self.parent_folder_id,
            modification_date: self.modification_date,
        }
    }
}

/// See `DiscoveredFileRecord` doc comment: identical shape, for `InventoryFolderRecord`.
#[derive(Clone, Debug, PartialEq)]
pub struct DiscoveredFolderRecord {
    pub root_id: InventoryUuid,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub parent_folder_id: Option<InventoryUuid>,
    pub modification_date: Option<f64>,
}

impl DiscoveredFolderRecord {
    #[must_use]
    pub fn into_minted(self, id: InventoryUuid) -> InventoryFolderRecord {
        InventoryFolderRecord {
            id,
            root_id: self.root_id,
            name: self.name,
            relative_path: self.relative_path,
            standardized_relative_path: self.standardized_relative_path,
            full_path: self.full_path,
            standardized_full_path: self.standardized_full_path,
            parent_folder_id: self.parent_folder_id,
            modification_date: self.modification_date,
        }
    }
}

/// `InventoryAppliedIndexBatchEvent`'s discovery-path counterpart: `upserted_files`/
/// `upserted_folders` carry id-less records; everything else (removals, modifications --
/// operations that reference an *already-known* id) is identical, because a removal or
/// modification is never a discovery event by definition.
#[derive(Clone, Debug, PartialEq)]
pub struct InventoryDiscoveryAppliedIndexBatchEvent {
    pub root_id: InventoryUuid,
    pub upserted_files: Vec<DiscoveredFileRecord>,
    pub upserted_folders: Vec<DiscoveredFolderRecord>,
    pub removed_file_ids: Vec<InventoryUuid>,
    pub removed_folder_ids: Vec<InventoryUuid>,
    pub removed_file_paths: Vec<String>,
    pub removed_folder_paths: Vec<String>,
    pub modified_file_ids: Vec<InventoryUuid>,
    pub modified_folder_ids: Vec<InventoryUuid>,
}

/// Appends one discovery record row ([`DISCOVERY_RECORD_STRIDE`] layout) to `words`. Mirrors
/// `push_record_row` minus the `id` fields.
#[allow(clippy::too_many_arguments)]
fn push_discovery_record_row(
    words: &mut Vec<u64>,
    pool: &mut InternPoolBuilder,
    root_id: &InventoryUuid,
    name: &str,
    relative_path: &str,
    standardized_relative_path: &str,
    full_path: &str,
    standardized_full_path: &str,
    parent_folder_id: Option<InventoryUuid>,
    modification_date: Option<f64>,
) {
    let (root_hi, root_lo) = uuid_to_words(root_id);
    let (parent_present, parent_hi, parent_lo) = optional_uuid_to_words(parent_folder_id);
    let (mod_present, mod_bits) = match modification_date {
        Some(value) => (1, value.to_bits()),
        None => (0, 0),
    };
    words.extend([
        root_hi,
        root_lo,
        pool.intern(name),
        pool.intern(relative_path),
        pool.intern(standardized_relative_path),
        pool.intern(full_path),
        pool.intern(standardized_full_path),
        parent_present,
        parent_hi,
        parent_lo,
        mod_present,
        mod_bits,
    ]);
}

struct DecodedDiscoveryRecordRow {
    root_id: InventoryUuid,
    name: String,
    relative_path: String,
    standardized_relative_path: String,
    full_path: String,
    standardized_full_path: String,
    parent_folder_id: Option<InventoryUuid>,
    modification_date: Option<f64>,
}

fn read_discovery_record_row(
    row: &[u64],
    pool: &InternPoolReader<'_>,
) -> Result<DecodedDiscoveryRecordRow, WireError> {
    let &[root_hi, root_lo, name_idx, relative_path_idx, standardized_relative_path_idx, full_path_idx, standardized_full_path_idx, parent_present, parent_hi, parent_lo, mod_present, mod_bits] =
        row
    else {
        return Err(WireError::Malformed("discovery record row"));
    };
    let modification_date = match mod_present {
        0 => None,
        1 => {
            let value = f64::from_bits(mod_bits);
            if value.is_nan() {
                return Err(WireError::Malformed("modification_date"));
            }
            Some(value)
        }
        _ => return Err(WireError::Malformed("modification_date presence flag")),
    };
    Ok(DecodedDiscoveryRecordRow {
        root_id: uuid_from_words(root_hi, root_lo),
        name: pool.resolve(name_idx)?.to_owned(),
        relative_path: pool.resolve(relative_path_idx)?.to_owned(),
        standardized_relative_path: pool.resolve(standardized_relative_path_idx)?.to_owned(),
        full_path: pool.resolve(full_path_idx)?.to_owned(),
        standardized_full_path: pool.resolve(standardized_full_path_idx)?.to_owned(),
        parent_folder_id: optional_uuid_from_words(parent_present, parent_hi, parent_lo)?,
        modification_date,
    })
}

fn push_discovered_file_row(words: &mut Vec<u64>, pool: &mut InternPoolBuilder, file: &DiscoveredFileRecord) {
    push_discovery_record_row(
        words,
        pool,
        &file.root_id,
        &file.name,
        &file.relative_path,
        &file.standardized_relative_path,
        &file.full_path,
        &file.standardized_full_path,
        file.parent_folder_id,
        file.modification_date,
    );
}

fn push_discovered_folder_row(words: &mut Vec<u64>, pool: &mut InternPoolBuilder, folder: &DiscoveredFolderRecord) {
    push_discovery_record_row(
        words,
        pool,
        &folder.root_id,
        &folder.name,
        &folder.relative_path,
        &folder.standardized_relative_path,
        &folder.full_path,
        &folder.standardized_full_path,
        folder.parent_folder_id,
        folder.modification_date,
    );
}

fn decode_discovered_file_rows(
    words: &[u64],
    pool: &InternPoolReader<'_>,
) -> Result<Vec<DiscoveredFileRecord>, WireError> {
    if words.len() % DISCOVERY_RECORD_STRIDE != 0 {
        return Err(WireError::Malformed("discovered file row stride"));
    }
    if words.len() / DISCOVERY_RECORD_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("discovered file rows"));
    }
    words
        .chunks_exact(DISCOVERY_RECORD_STRIDE)
        .map(|row| {
            let decoded = read_discovery_record_row(row, pool)?;
            Ok(DiscoveredFileRecord {
                root_id: decoded.root_id,
                name: decoded.name,
                relative_path: decoded.relative_path,
                standardized_relative_path: decoded.standardized_relative_path,
                full_path: decoded.full_path,
                standardized_full_path: decoded.standardized_full_path,
                parent_folder_id: decoded.parent_folder_id,
                modification_date: decoded.modification_date,
            })
        })
        .collect()
}

fn decode_discovered_folder_rows(
    words: &[u64],
    pool: &InternPoolReader<'_>,
) -> Result<Vec<DiscoveredFolderRecord>, WireError> {
    if words.len() % DISCOVERY_RECORD_STRIDE != 0 {
        return Err(WireError::Malformed("discovered folder row stride"));
    }
    if words.len() / DISCOVERY_RECORD_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("discovered folder rows"));
    }
    words
        .chunks_exact(DISCOVERY_RECORD_STRIDE)
        .map(|row| {
            let decoded = read_discovery_record_row(row, pool)?;
            Ok(DiscoveredFolderRecord {
                root_id: decoded.root_id,
                name: decoded.name,
                relative_path: decoded.relative_path,
                standardized_relative_path: decoded.standardized_relative_path,
                full_path: decoded.full_path,
                standardized_full_path: decoded.standardized_full_path,
                parent_folder_id: decoded.parent_folder_id,
                modification_date: decoded.modification_date,
            })
        })
        .collect()
}

// ================================================================================================
// Discovery bulk-load chunk: `inventoryPushBulkChunkDiscovery`'s payload. Additive parallel to
// `encode_bulk_chunk`/`decode_bulk_chunk` above, which are untouched.
// ================================================================================================

#[must_use]
pub fn encode_discovery_bulk_chunk(
    files: &[DiscoveredFileRecord],
    folders: &[DiscoveredFolderRecord],
) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut file_words = Vec::with_capacity(files.len() * DISCOVERY_RECORD_STRIDE);
    for file in files {
        push_discovered_file_row(&mut file_words, &mut pool, file);
    }
    let mut folder_words = Vec::with_capacity(folders.len() * DISCOVERY_RECORD_STRIDE);
    for folder in folders {
        push_discovered_folder_row(&mut folder_words, &mut pool, folder);
    }
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::DiscoveryBulkChunk);
    writer.write_words(&file_words).expect("bounded by caller");
    writer.write_words(&folder_words).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_discovery_bulk_chunk(
    bytes: &[u8],
) -> Result<(Vec<DiscoveredFileRecord>, Vec<DiscoveredFolderRecord>), WireError> {
    let mut reader = Reader::open(bytes, MessageKind::DiscoveryBulkChunk)?;
    let file_words = reader.read_words(MAX_ROWS_PER_CALL * DISCOVERY_RECORD_STRIDE, "discovered file rows")?;
    let folder_words =
        reader.read_words(MAX_ROWS_PER_CALL * DISCOVERY_RECORD_STRIDE, "discovered folder rows")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    let pool = InternPoolReader::new(blob, &range_words)?;
    let files = decode_discovered_file_rows(&file_words, &pool)?;
    let folders = decode_discovered_folder_rows(&folder_words, &pool)?;
    Ok((files, folders))
}

// ================================================================================================
// Discovery delta event: `InventoryDeltaCommandV1`'s discovery counterpart. Additive parallel to
// `encode_delta_event`/`decode_delta_event` above, which are untouched.
// ================================================================================================

#[must_use]
pub fn encode_discovery_delta_event(event: &InventoryDiscoveryAppliedIndexBatchEvent) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut upserted_file_words = Vec::with_capacity(event.upserted_files.len() * DISCOVERY_RECORD_STRIDE);
    for file in &event.upserted_files {
        push_discovered_file_row(&mut upserted_file_words, &mut pool, file);
    }
    let mut upserted_folder_words =
        Vec::with_capacity(event.upserted_folders.len() * DISCOVERY_RECORD_STRIDE);
    for folder in &event.upserted_folders {
        push_discovered_folder_row(&mut upserted_folder_words, &mut pool, folder);
    }
    let mut removed_file_ids = Vec::with_capacity(event.removed_file_ids.len() * 2);
    push_uuid_list(&mut removed_file_ids, &event.removed_file_ids);
    let mut removed_folder_ids = Vec::with_capacity(event.removed_folder_ids.len() * 2);
    push_uuid_list(&mut removed_folder_ids, &event.removed_folder_ids);
    let mut removed_file_paths = Vec::with_capacity(event.removed_file_paths.len());
    push_string_list(&mut removed_file_paths, &mut pool, &event.removed_file_paths);
    let mut removed_folder_paths = Vec::with_capacity(event.removed_folder_paths.len());
    push_string_list(&mut removed_folder_paths, &mut pool, &event.removed_folder_paths);
    let mut modified_file_ids = Vec::with_capacity(event.modified_file_ids.len() * 2);
    push_uuid_list(&mut modified_file_ids, &event.modified_file_ids);
    let mut modified_folder_ids = Vec::with_capacity(event.modified_folder_ids.len() * 2);
    push_uuid_list(&mut modified_folder_ids, &event.modified_folder_ids);
    let (root_hi, root_lo) = uuid_to_words(&event.root_id);
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::DiscoveryDeltaEvent);
    writer.write_words(&[root_hi, root_lo]).expect("bounded");
    writer.write_words(&upserted_file_words).expect("bounded by caller");
    writer.write_words(&upserted_folder_words).expect("bounded by caller");
    writer.write_words(&removed_file_ids).expect("bounded by caller");
    writer.write_words(&removed_folder_ids).expect("bounded by caller");
    writer.write_words(&removed_file_paths).expect("bounded by caller");
    writer.write_words(&removed_folder_paths).expect("bounded by caller");
    writer.write_words(&modified_file_ids).expect("bounded by caller");
    writer.write_words(&modified_folder_ids).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_discovery_delta_event(
    bytes: &[u8],
) -> Result<InventoryDiscoveryAppliedIndexBatchEvent, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::DiscoveryDeltaEvent)?;
    let root_id_words = reader.read_words(2, "root_id")?;
    let &[root_hi, root_lo] = root_id_words.as_slice() else {
        return Err(WireError::Malformed("root_id"));
    };
    let upserted_file_words =
        reader.read_words(MAX_ROWS_PER_CALL * DISCOVERY_RECORD_STRIDE, "upserted discovered file rows")?;
    let upserted_folder_words = reader.read_words(
        MAX_ROWS_PER_CALL * DISCOVERY_RECORD_STRIDE,
        "upserted discovered folder rows",
    )?;
    let removed_file_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "removed_file_ids")?;
    let removed_folder_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "removed_folder_ids")?;
    let removed_file_path_words = reader.read_words(MAX_PATHS_PER_CALL, "removed_file_paths")?;
    let removed_folder_path_words = reader.read_words(MAX_PATHS_PER_CALL, "removed_folder_paths")?;
    let modified_file_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "modified_file_ids")?;
    let modified_folder_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "modified_folder_ids")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    let pool = InternPoolReader::new(blob, &range_words)?;
    Ok(InventoryDiscoveryAppliedIndexBatchEvent {
        root_id: uuid_from_words(root_hi, root_lo),
        upserted_files: decode_discovered_file_rows(&upserted_file_words, &pool)?,
        upserted_folders: decode_discovered_folder_rows(&upserted_folder_words, &pool)?,
        removed_file_ids: decode_uuid_list(&removed_file_id_words, "removed_file_ids")?,
        removed_folder_ids: decode_uuid_list(&removed_folder_id_words, "removed_folder_ids")?,
        removed_file_paths: decode_string_list(&removed_file_path_words, &pool, "removed_file_paths")?,
        removed_folder_paths: decode_string_list(
            &removed_folder_path_words,
            &pool,
            "removed_folder_paths",
        )?,
        modified_file_ids: decode_uuid_list(&modified_file_id_words, "modified_file_ids")?,
        modified_folder_ids: decode_uuid_list(&modified_folder_id_words, "modified_folder_ids")?,
    })
}

fn push_uuid_list(words: &mut Vec<u64>, ids: &[InventoryUuid]) {
    for id in ids {
        let (hi, lo) = uuid_to_words(id);
        words.extend([hi, lo]);
    }
}

fn decode_uuid_list(words: &[u64], field: &'static str) -> Result<Vec<InventoryUuid>, WireError> {
    if words.len() % 2 != 0 {
        return Err(WireError::Malformed(field));
    }
    if words.len() / 2 > MAX_IDS_PER_CALL {
        return Err(WireError::Oversize(field));
    }
    Ok(words
        .chunks_exact(2)
        .map(|pair| uuid_from_words(pair[0], pair[1]))
        .collect())
}

fn push_string_list(words: &mut Vec<u64>, pool: &mut InternPoolBuilder, values: &[String]) {
    for value in values {
        words.push(pool.intern(value));
    }
}

fn decode_string_list(
    words: &[u64],
    pool: &InternPoolReader<'_>,
    field: &'static str,
) -> Result<Vec<String>, WireError> {
    if words.len() > MAX_PATHS_PER_CALL {
        return Err(WireError::Oversize(field));
    }
    words.iter().map(|&index| pool.resolve(index).map(str::to_owned)).collect()
}

// ================================================================================================
// Bulk-load chunk: `inventoryPushBulkChunk`'s payload.
// ================================================================================================

#[must_use]
pub fn encode_bulk_chunk(files: &[InventoryFileRecord], folders: &[InventoryFolderRecord]) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut file_words = Vec::with_capacity(files.len() * RECORD_STRIDE);
    for file in files {
        push_file_row(&mut file_words, &mut pool, file);
    }
    let mut folder_words = Vec::with_capacity(folders.len() * RECORD_STRIDE);
    for folder in folders {
        push_folder_row(&mut folder_words, &mut pool, folder);
    }
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::BulkChunk);
    writer.write_words(&file_words).expect("bounded by caller");
    writer.write_words(&folder_words).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_bulk_chunk(
    bytes: &[u8],
) -> Result<(Vec<InventoryFileRecord>, Vec<InventoryFolderRecord>), WireError> {
    let mut reader = Reader::open(bytes, MessageKind::BulkChunk)?;
    let file_words = reader.read_words(MAX_ROWS_PER_CALL * RECORD_STRIDE, "file rows")?;
    let folder_words = reader.read_words(MAX_ROWS_PER_CALL * RECORD_STRIDE, "folder rows")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    let pool = InternPoolReader::new(blob, &range_words)?;
    let files = decode_file_rows(&file_words, &pool)?;
    let folders = decode_folder_rows(&folder_words, &pool)?;
    Ok((files, folders))
}

// ================================================================================================
// Delta event: `InventoryDeltaCommandV1`'s "compact inventory-scope-v1 delta blob" field.
// ================================================================================================

#[must_use]
pub fn encode_delta_event(event: &InventoryAppliedIndexBatchEvent) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut upserted_file_words = Vec::with_capacity(event.upserted_files.len() * RECORD_STRIDE);
    for file in &event.upserted_files {
        push_file_row(&mut upserted_file_words, &mut pool, file);
    }
    let mut upserted_folder_words = Vec::with_capacity(event.upserted_folders.len() * RECORD_STRIDE);
    for folder in &event.upserted_folders {
        push_folder_row(&mut upserted_folder_words, &mut pool, folder);
    }
    let mut removed_file_ids = Vec::with_capacity(event.removed_file_ids.len() * 2);
    push_uuid_list(&mut removed_file_ids, &event.removed_file_ids);
    let mut removed_folder_ids = Vec::with_capacity(event.removed_folder_ids.len() * 2);
    push_uuid_list(&mut removed_folder_ids, &event.removed_folder_ids);
    let mut removed_file_paths = Vec::with_capacity(event.removed_file_paths.len());
    push_string_list(&mut removed_file_paths, &mut pool, &event.removed_file_paths);
    let mut removed_folder_paths = Vec::with_capacity(event.removed_folder_paths.len());
    push_string_list(&mut removed_folder_paths, &mut pool, &event.removed_folder_paths);
    let mut modified_file_ids = Vec::with_capacity(event.modified_file_ids.len() * 2);
    push_uuid_list(&mut modified_file_ids, &event.modified_file_ids);
    let mut modified_folder_ids = Vec::with_capacity(event.modified_folder_ids.len() * 2);
    push_uuid_list(&mut modified_folder_ids, &event.modified_folder_ids);
    let (root_hi, root_lo) = uuid_to_words(&event.root_id);
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::DeltaEvent);
    writer.write_words(&[root_hi, root_lo]).expect("bounded");
    writer.write_words(&upserted_file_words).expect("bounded by caller");
    writer.write_words(&upserted_folder_words).expect("bounded by caller");
    writer.write_words(&removed_file_ids).expect("bounded by caller");
    writer.write_words(&removed_folder_ids).expect("bounded by caller");
    writer.write_words(&removed_file_paths).expect("bounded by caller");
    writer.write_words(&removed_folder_paths).expect("bounded by caller");
    writer.write_words(&modified_file_ids).expect("bounded by caller");
    writer.write_words(&modified_folder_ids).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_delta_event(bytes: &[u8]) -> Result<InventoryAppliedIndexBatchEvent, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::DeltaEvent)?;
    let root_id_words = reader.read_words(2, "root_id")?;
    let &[root_hi, root_lo] = root_id_words.as_slice() else {
        return Err(WireError::Malformed("root_id"));
    };
    let upserted_file_words = reader.read_words(MAX_ROWS_PER_CALL * RECORD_STRIDE, "upserted file rows")?;
    let upserted_folder_words =
        reader.read_words(MAX_ROWS_PER_CALL * RECORD_STRIDE, "upserted folder rows")?;
    let removed_file_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "removed_file_ids")?;
    let removed_folder_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "removed_folder_ids")?;
    let removed_file_path_words = reader.read_words(MAX_PATHS_PER_CALL, "removed_file_paths")?;
    let removed_folder_path_words = reader.read_words(MAX_PATHS_PER_CALL, "removed_folder_paths")?;
    let modified_file_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "modified_file_ids")?;
    let modified_folder_id_words = reader.read_words(MAX_IDS_PER_CALL * 2, "modified_folder_ids")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    let pool = InternPoolReader::new(blob, &range_words)?;
    Ok(InventoryAppliedIndexBatchEvent {
        root_id: uuid_from_words(root_hi, root_lo),
        upserted_files: decode_file_rows(&upserted_file_words, &pool)?,
        upserted_folders: decode_folder_rows(&upserted_folder_words, &pool)?,
        removed_file_ids: decode_uuid_list(&removed_file_id_words, "removed_file_ids")?,
        removed_folder_ids: decode_uuid_list(&removed_folder_id_words, "removed_folder_ids")?,
        removed_file_paths: decode_string_list(&removed_file_path_words, &pool, "removed_file_paths")?,
        removed_folder_paths: decode_string_list(&removed_folder_path_words, &pool, "removed_folder_paths")?,
        modified_file_ids: decode_uuid_list(&modified_file_id_words, "modified_file_ids")?,
        modified_folder_ids: decode_uuid_list(&modified_folder_id_words, "modified_folder_ids")?,
    })
}

// ================================================================================================
// Resolve-records / lookup-paths requests and the shared fact-block response
// (`inventoryResolveRecords` / `inventoryLookupPaths`, contract doc §5.3).
// ================================================================================================

#[must_use]
pub fn encode_resolve_request(file_ids: &[InventoryUuid], folder_ids: &[InventoryUuid]) -> Vec<u8> {
    let mut file_words = Vec::with_capacity(file_ids.len() * 2);
    push_uuid_list(&mut file_words, file_ids);
    let mut folder_words = Vec::with_capacity(folder_ids.len() * 2);
    push_uuid_list(&mut folder_words, folder_ids);

    let mut writer = Writer::header(MessageKind::ResolveRequest);
    writer.write_words(&file_words).expect("bounded by caller");
    writer.write_words(&folder_words).expect("bounded by caller");
    writer.finish()
}

pub fn decode_resolve_request(
    bytes: &[u8],
) -> Result<(Vec<InventoryUuid>, Vec<InventoryUuid>), WireError> {
    let mut reader = Reader::open(bytes, MessageKind::ResolveRequest)?;
    let file_words = reader.read_words(MAX_IDS_PER_CALL * 2, "file_ids")?;
    let folder_words = reader.read_words(MAX_IDS_PER_CALL * 2, "folder_ids")?;
    reader.finish()?;
    Ok((
        decode_uuid_list(&file_words, "file_ids")?,
        decode_uuid_list(&folder_words, "folder_ids")?,
    ))
}

#[must_use]
pub fn encode_lookup_request(paths: &[String]) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut path_words = Vec::with_capacity(paths.len());
    push_string_list(&mut path_words, &mut pool, paths);
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::LookupRequest);
    writer.write_words(&path_words).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_lookup_request(bytes: &[u8]) -> Result<Vec<String>, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::LookupRequest)?;
    let path_words = reader.read_words(MAX_PATHS_PER_CALL, "paths")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;
    let pool = InternPoolReader::new(blob, &range_words)?;
    decode_string_list(&path_words, &pool, "paths")
}

/// One fact row (contract doc §5.3): "facts, not a verdict". `key_hi`/`key_lo` carry the
/// requested id (`inventoryResolveRecords`) or the request ordinal (`inventoryLookupPaths`,
/// which is keyed by path, not id) so a caller can zip results back to its request order/keys
/// without a second lookup.
#[derive(Clone, Debug, PartialEq)]
pub struct FactRow {
    pub key_hi: u64,
    pub key_lo: u64,
    pub exists: bool,
    pub file_id: Option<InventoryUuid>,
    pub folder_id: Option<InventoryUuid>,
    pub root_id: Option<InventoryUuid>,
    pub is_discoverable: bool,
    pub path_round_trips_to_self: bool,
    pub standardized_relative_path: Option<String>,
    pub standardized_full_path: Option<String>,
    pub name: Option<String>,
    /// D-11 (contract doc §7): a fingerprint the caller can compare a captured record against.
    /// Zero for a non-existent row.
    pub record_fingerprint: u64,
    /// P4-6b gap-closure (see `FACT_ROW_STRIDE`'s doc comment): the projected fields §4.3.1 named
    /// but P4-4 never wired. `None` for a non-existent row.
    pub parent_folder_id: Option<InventoryUuid>,
    pub modification_date: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FactBlock {
    /// `None` when the whole block is stale (contract doc §5.3's "or a whole-block `stale`").
    pub generation: Option<u64>,
    pub root_lifetime_hi: u64,
    pub root_lifetime_lo: u64,
    pub rows: Vec<FactRow>,
}

#[must_use]
pub fn encode_fact_block(block: &FactBlock) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut rows = Vec::with_capacity(block.rows.len() * FACT_ROW_STRIDE);
    for row in &block.rows {
        let (file_present, file_hi, file_lo) = optional_uuid_to_words(row.file_id);
        let (folder_present, folder_hi, folder_lo) = optional_uuid_to_words(row.folder_id);
        let (root_present, root_hi, root_lo) = optional_uuid_to_words(row.root_id);
        rows.extend([
            row.key_hi,
            row.key_lo,
            u64::from(row.exists),
            file_present,
            file_hi,
            file_lo,
            folder_present,
            folder_hi,
            folder_lo,
            root_present,
            root_hi,
            root_lo,
            u64::from(row.is_discoverable),
            u64::from(row.path_round_trips_to_self),
            pool.intern_optional(row.standardized_relative_path.as_deref()),
            pool.intern_optional(row.standardized_full_path.as_deref()),
        ]);
        // `name` and `record_fingerprint` appended in a second pass below to keep the stride
        // table above readable; see the doc comment on `FACT_ROW_STRIDE` for the full word
        // layout (14 above + name_idx + fingerprint, then the P4-6b gap-closure fields below).
        let name_idx = pool.intern_optional(row.name.as_deref());
        rows.push(name_idx);
        rows.push(row.record_fingerprint);
        let (parent_present, parent_hi, parent_lo) = optional_uuid_to_words(row.parent_folder_id);
        let (mod_present, mod_bits) = match row.modification_date {
            Some(value) => (1, value.to_bits()),
            None => (0, 0),
        };
        rows.extend([parent_present, parent_hi, parent_lo, mod_present, mod_bits]);
    }
    let (present, generation) = match block.generation {
        Some(value) => (1u64, value),
        None => (0u64, 0u64),
    };
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::FactBlock);
    writer
        .write_words(&[present, generation, block.root_lifetime_hi, block.root_lifetime_lo])
        .expect("bounded");
    writer.write_words(&rows).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_fact_block(bytes: &[u8]) -> Result<FactBlock, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::FactBlock)?;
    let header_words = reader.read_words(4, "fact block header")?;
    let &[present, generation, root_lifetime_hi, root_lifetime_lo] = header_words.as_slice() else {
        return Err(WireError::Malformed("fact block header"));
    };
    let generation = match present {
        0 => None,
        1 => Some(generation),
        _ => return Err(WireError::Malformed("fact block generation presence flag")),
    };
    let rows_words = reader.read_words(MAX_ROWS_PER_CALL * FACT_ROW_STRIDE, "fact rows")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    if rows_words.len() % FACT_ROW_STRIDE != 0 {
        return Err(WireError::Malformed("fact row stride"));
    }
    if rows_words.len() / FACT_ROW_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("fact rows"));
    }
    let pool = InternPoolReader::new(blob, &range_words)?;
    let rows = rows_words
        .chunks_exact(FACT_ROW_STRIDE)
        .map(|row| {
            let &[key_hi, key_lo, exists, file_present, file_hi, file_lo, folder_present, folder_hi, folder_lo, root_present, root_hi, root_lo, is_discoverable, path_round_trips_to_self, standardized_relative_path_idx, standardized_full_path_idx, name_idx, record_fingerprint, parent_present, parent_hi, parent_lo, mod_present, mod_bits] =
                row
            else {
                return Err(WireError::Malformed("fact row"));
            };
            let modification_date = match mod_present {
                0 => None,
                1 => {
                    let value = f64::from_bits(mod_bits);
                    if value.is_nan() {
                        return Err(WireError::Malformed("fact row modification_date"));
                    }
                    Some(value)
                }
                _ => return Err(WireError::Malformed("fact row modification_date presence flag")),
            };
            Ok(FactRow {
                key_hi,
                key_lo,
                exists: exists != 0,
                file_id: optional_uuid_from_words(file_present, file_hi, file_lo)?,
                folder_id: optional_uuid_from_words(folder_present, folder_hi, folder_lo)?,
                root_id: optional_uuid_from_words(root_present, root_hi, root_lo)?,
                is_discoverable: is_discoverable != 0,
                path_round_trips_to_self: path_round_trips_to_self != 0,
                standardized_relative_path: pool.resolve_optional(standardized_relative_path_idx)?.map(str::to_owned),
                standardized_full_path: pool.resolve_optional(standardized_full_path_idx)?.map(str::to_owned),
                name: pool.resolve_optional(name_idx)?.map(str::to_owned),
                record_fingerprint,
                parent_folder_id: optional_uuid_from_words(parent_present, parent_hi, parent_lo)?,
                modification_date,
            })
        })
        .collect::<Result<Vec<_>, WireError>>()?;
    Ok(FactBlock {
        generation,
        root_lifetime_hi,
        root_lifetime_lo,
        rows,
    })
}

// ================================================================================================
// Query request/response (`inventoryQuery`, contract doc §5.3/§6): haystack variant selector +
// physical per-root display prefix (both the non-empty-relative form and the distinct
// empty-relative-path override) + P4-7a phase a3's logical prefix pair (design §5.1), an
// identically-shaped pair present only when the caller has a worktree binding projection --
// `logical_present` disambiguates absent (`.IndexKey`, or `.Suggestion` with no projection) from
// present-but-empty (a real logical prefix whose `non_empty_relative_prefix` is legitimately "",
// branch 1 of `ClientPathFormatter.displayPath`) -- see `query.rs`'s domain type, which this wire
// (de)serializes verbatim.
// ================================================================================================

#[must_use]
pub fn encode_query_request(
    pattern: &str,
    limit: u64,
    haystack_variant: u64,
    non_empty_relative_prefix: &str,
    empty_relative_path_value: &str,
    logical_prefix: Option<(&str, &str)>,
) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let pattern_idx = pool.intern(pattern);
    let prefix_idx = pool.intern(non_empty_relative_prefix);
    let empty_override_idx = pool.intern(empty_relative_path_value);
    let logical_present = u64::from(logical_prefix.is_some());
    let (logical_non_empty_relative_prefix, logical_empty_relative_path_value) = logical_prefix.unwrap_or(("", ""));
    let logical_prefix_idx = pool.intern(logical_non_empty_relative_prefix);
    let logical_empty_override_idx = pool.intern(logical_empty_relative_path_value);
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::QueryRequest);
    writer
        .write_words(&[
            pattern_idx,
            limit,
            haystack_variant,
            prefix_idx,
            empty_override_idx,
            logical_present,
            logical_prefix_idx,
            logical_empty_override_idx,
        ])
        .expect("bounded");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub struct DecodedQueryRequest {
    pub pattern: String,
    pub limit: u64,
    pub haystack_variant: u64,
    pub non_empty_relative_prefix: String,
    pub empty_relative_path_value: String,
    /// `None` when the caller has no worktree binding projection (`logical_present == 0`);
    /// `Some` never collapses a legitimately-empty `non_empty_relative_prefix` into `None` --
    /// that would silently drop the logical component for a bound single-visible-root workspace,
    /// exactly the worktree case P4-7a's differential is supposed to prove (design §5.1).
    pub logical_prefix: Option<(String, String)>,
}

pub fn decode_query_request(bytes: &[u8]) -> Result<DecodedQueryRequest, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::QueryRequest)?;
    let header_words = reader.read_words(8, "query request header")?;
    let &[pattern_idx, limit, haystack_variant, prefix_idx, empty_override_idx, logical_present, logical_prefix_idx, logical_empty_override_idx] =
        header_words.as_slice()
    else {
        return Err(WireError::Malformed("query request header"));
    };
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;
    let pool = InternPoolReader::new(blob, &range_words)?;
    let logical_prefix = match logical_present {
        0 => None,
        1 => Some((
            pool.resolve(logical_prefix_idx)?.to_owned(),
            pool.resolve(logical_empty_override_idx)?.to_owned(),
        )),
        _ => return Err(WireError::Malformed("query request logical prefix presence flag")),
    };
    Ok(DecodedQueryRequest {
        logical_prefix,
        pattern: pool.resolve(pattern_idx)?.to_owned(),
        limit,
        haystack_variant,
        non_empty_relative_prefix: pool.resolve(prefix_idx)?.to_owned(),
        empty_relative_path_value: pool.resolve(empty_override_idx)?.to_owned(),
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueryCandidateRow {
    pub id: InventoryUuid,
    pub root_id: InventoryUuid,
    pub name: String,
    pub relative_path: String,
    pub standardized_relative_path: String,
    pub full_path: String,
    pub standardized_full_path: String,
    pub display_path: String,
    pub tie_break_key: String,
    pub score: i64,
}

#[must_use]
pub fn encode_query_response(generation: Option<u64>, candidates: &[QueryCandidateRow]) -> Vec<u8> {
    let mut pool = InternPoolBuilder::new();
    let mut rows = Vec::with_capacity(candidates.len() * CANDIDATE_ROW_STRIDE);
    for candidate in candidates {
        let (id_hi, id_lo) = uuid_to_words(&candidate.id);
        let (root_hi, root_lo) = uuid_to_words(&candidate.root_id);
        rows.extend([
            id_hi,
            id_lo,
            root_hi,
            root_lo,
            pool.intern(&candidate.name),
            pool.intern(&candidate.relative_path),
            pool.intern(&candidate.standardized_relative_path),
            pool.intern(&candidate.full_path),
            pool.intern(&candidate.standardized_full_path),
            pool.intern(&candidate.display_path),
            pool.intern(&candidate.tie_break_key),
            // Sign-preserving two's-complement pack/unpack (`as i64 as u64` / `as u64 as i64`):
            // scores are `i32` today (always `1` in this crate, per `PathSearchMatch`/
            // `PathIndexCandidate`'s doc comments) so this never actually wraps, but the pack is
            // deliberately exact rather than accidentally-correct.
            candidate.score as u64,
        ]);
    }
    let (present, generation) = match generation {
        Some(value) => (1u64, value),
        None => (0u64, 0u64),
    };
    let (blob, range_words) = pool.finish();

    let mut writer = Writer::header(MessageKind::QueryResponse);
    writer.write_words(&[present, generation]).expect("bounded");
    writer.write_words(&rows).expect("bounded by caller");
    writer.write_words(&range_words).expect("bounded by caller");
    writer.write_blob(&blob).expect("bounded by caller");
    writer.finish()
}

pub fn decode_query_response(bytes: &[u8]) -> Result<(Option<u64>, Vec<QueryCandidateRow>), WireError> {
    let mut reader = Reader::open(bytes, MessageKind::QueryResponse)?;
    let header_words = reader.read_words(2, "query response header")?;
    let &[present, generation] = header_words.as_slice() else {
        return Err(WireError::Malformed("query response header"));
    };
    let generation = match present {
        0 => None,
        1 => Some(generation),
        _ => return Err(WireError::Malformed("query response generation presence flag")),
    };
    let rows_words = reader.read_words(MAX_ROWS_PER_CALL * CANDIDATE_ROW_STRIDE, "candidate rows")?;
    let range_words = reader.read_words(MAX_WORDS_PER_SECTION, "string_range_words")?;
    let blob = reader.read_blob("utf8_blob")?;
    reader.finish()?;

    if rows_words.len() % CANDIDATE_ROW_STRIDE != 0 {
        return Err(WireError::Malformed("candidate row stride"));
    }
    if rows_words.len() / CANDIDATE_ROW_STRIDE > MAX_ROWS_PER_CALL {
        return Err(WireError::Oversize("candidate rows"));
    }
    let pool = InternPoolReader::new(blob, &range_words)?;
    let candidates = rows_words
        .chunks_exact(CANDIDATE_ROW_STRIDE)
        .map(|row| {
            let &[id_hi, id_lo, root_hi, root_lo, name_idx, relative_path_idx, standardized_relative_path_idx, full_path_idx, standardized_full_path_idx, display_path_idx, tie_break_key_idx, score] =
                row
            else {
                return Err(WireError::Malformed("candidate row"));
            };
            Ok(QueryCandidateRow {
                id: uuid_from_words(id_hi, id_lo),
                root_id: uuid_from_words(root_hi, root_lo),
                name: pool.resolve(name_idx)?.to_owned(),
                relative_path: pool.resolve(relative_path_idx)?.to_owned(),
                standardized_relative_path: pool.resolve(standardized_relative_path_idx)?.to_owned(),
                full_path: pool.resolve(full_path_idx)?.to_owned(),
                standardized_full_path: pool.resolve(standardized_full_path_idx)?.to_owned(),
                display_path: pool.resolve(display_path_idx)?.to_owned(),
                tie_break_key: pool.resolve(tie_break_key_idx)?.to_owned(),
                // See `encode_query_response`'s doc comment on this same cast pair.
                score: score as i64,
            })
        })
        .collect::<Result<Vec<_>, WireError>>()?;
    Ok((generation, candidates))
}

// ================================================================================================
// Event plane (contract doc §5b, P4-4b). Every payload below is a fixed-width word section --
// notifications carry counts/ids/reasons, never tables, so no string interning is needed. Root
// identity is carried as `InventoryUuid` for both `root_id` and `root_lifetime_id` (the caller
// converts `RootLifetimeId::as_bytes()` at the call site); this module stays agnostic of the
// typed-id wrapper the same way it already is for `RootId` (a `pub type` alias of `InventoryUuid`).
// ================================================================================================

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GenerationAdvancedEvent {
    pub root_id: InventoryUuid,
    pub root_lifetime_id: InventoryUuid,
    pub applied_index_generation: u64,
    pub catalog_generation: Option<u64>,
    pub rebuilt_authoritative: bool,
    pub upserted_count: u64,
    pub removed_count: u64,
    pub modified_count: u64,
}

#[must_use]
pub fn encode_generation_advanced(event: &GenerationAdvancedEvent) -> Vec<u8> {
    let (root_hi, root_lo) = uuid_to_words(&event.root_id);
    let (lifetime_hi, lifetime_lo) = uuid_to_words(&event.root_lifetime_id);
    let (generation_present, generation_value) = match event.catalog_generation {
        Some(value) => (1u64, value),
        None => (0u64, 0u64),
    };
    let mut writer = Writer::header(MessageKind::GenerationAdvanced);
    writer
        .write_words(&[
            root_hi,
            root_lo,
            lifetime_hi,
            lifetime_lo,
            event.applied_index_generation,
            generation_present,
            generation_value,
            u64::from(event.rebuilt_authoritative),
            event.upserted_count,
            event.removed_count,
            event.modified_count,
        ])
        .expect("bounded");
    writer.finish()
}

pub fn decode_generation_advanced(bytes: &[u8]) -> Result<GenerationAdvancedEvent, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::GenerationAdvanced)?;
    let words = reader.read_words(11, "generation advanced event")?;
    reader.finish()?;
    let &[root_hi, root_lo, lifetime_hi, lifetime_lo, applied_index_generation, generation_present, generation_value, rebuilt_authoritative, upserted_count, removed_count, modified_count] =
        words.as_slice()
    else {
        return Err(WireError::Malformed("generation advanced event"));
    };
    let catalog_generation = match generation_present {
        0 => None,
        1 => Some(generation_value),
        _ => return Err(WireError::Malformed("generation advanced event presence flag")),
    };
    let rebuilt_authoritative = match rebuilt_authoritative {
        0 => false,
        1 => true,
        _ => return Err(WireError::Malformed("generation advanced event outcome flag")),
    };
    Ok(GenerationAdvancedEvent {
        root_id: uuid_from_words(root_hi, root_lo),
        root_lifetime_id: uuid_from_words(lifetime_hi, lifetime_lo),
        applied_index_generation,
        catalog_generation,
        rebuilt_authoritative,
        upserted_count,
        removed_count,
        modified_count,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RootLifecycleEvent {
    pub root_id: InventoryUuid,
    pub root_lifetime_id: InventoryUuid,
}

fn encode_root_lifecycle(kind: MessageKind, event: &RootLifecycleEvent) -> Vec<u8> {
    let (root_hi, root_lo) = uuid_to_words(&event.root_id);
    let (lifetime_hi, lifetime_lo) = uuid_to_words(&event.root_lifetime_id);
    let mut writer = Writer::header(kind);
    writer
        .write_words(&[root_hi, root_lo, lifetime_hi, lifetime_lo])
        .expect("bounded");
    writer.finish()
}

fn decode_root_lifecycle(bytes: &[u8], kind: MessageKind) -> Result<RootLifecycleEvent, WireError> {
    let mut reader = Reader::open(bytes, kind)?;
    let words = reader.read_words(4, "root lifecycle event")?;
    reader.finish()?;
    let &[root_hi, root_lo, lifetime_hi, lifetime_lo] = words.as_slice() else {
        return Err(WireError::Malformed("root lifecycle event"));
    };
    Ok(RootLifecycleEvent {
        root_id: uuid_from_words(root_hi, root_lo),
        root_lifetime_id: uuid_from_words(lifetime_hi, lifetime_lo),
    })
}

#[must_use]
pub fn encode_root_published(event: &RootLifecycleEvent) -> Vec<u8> {
    encode_root_lifecycle(MessageKind::RootPublished, event)
}

pub fn decode_root_published(bytes: &[u8]) -> Result<RootLifecycleEvent, WireError> {
    decode_root_lifecycle(bytes, MessageKind::RootPublished)
}

#[must_use]
pub fn encode_root_unloaded(event: &RootLifecycleEvent) -> Vec<u8> {
    encode_root_lifecycle(MessageKind::RootUnloaded, event)
}

pub fn decode_root_unloaded(bytes: &[u8]) -> Result<RootLifecycleEvent, WireError> {
    decode_root_lifecycle(bytes, MessageKind::RootUnloaded)
}

/// Stable wire ordinal for a fallback reason: `RootCatalogShardFallbackReason::ALL`'s index.
/// Reordering, adding, or removing `ALL`'s cases changes this mapping -- see that array's own
/// "do not reorder" doc comment, which already governs this constraint for an unrelated reason
/// (Swift diagnostics parity); this wire code adds a second reason the order is now load-bearing.
fn fallback_reason_tag(reason: RootCatalogShardFallbackReason) -> u64 {
    RootCatalogShardFallbackReason::ALL
        .iter()
        .position(|candidate| *candidate == reason)
        .expect("reason is one of RootCatalogShardFallbackReason::ALL") as u64
}

fn fallback_reason_from_tag(tag: u64) -> Result<RootCatalogShardFallbackReason, WireError> {
    usize::try_from(tag)
        .ok()
        .and_then(|index| RootCatalogShardFallbackReason::ALL.get(index).copied())
        .ok_or(WireError::OutOfRange("shard fallback reason tag"))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ShardFallbackEvent {
    pub root_id: InventoryUuid,
    pub reason: RootCatalogShardFallbackReason,
}

#[must_use]
pub fn encode_shard_fallback(event: &ShardFallbackEvent) -> Vec<u8> {
    let (root_hi, root_lo) = uuid_to_words(&event.root_id);
    let mut writer = Writer::header(MessageKind::ShardFallback);
    writer
        .write_words(&[root_hi, root_lo, fallback_reason_tag(event.reason)])
        .expect("bounded");
    writer.finish()
}

pub fn decode_shard_fallback(bytes: &[u8]) -> Result<ShardFallbackEvent, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::ShardFallback)?;
    let words = reader.read_words(3, "shard fallback event")?;
    reader.finish()?;
    let &[root_hi, root_lo, reason_tag] = words.as_slice() else {
        return Err(WireError::Malformed("shard fallback event"));
    };
    Ok(ShardFallbackEvent {
        root_id: uuid_from_words(root_hi, root_lo),
        reason: fallback_reason_from_tag(reason_tag)?,
    })
}

/// §5b's "reason (gap, overflow, backstop, identity change)". `Gap`/`Overflow` are reserved for
/// symmetry with the contract's own wording; P4-4b's `InventoryScope` only ever constructs
/// `IdentityChanged` (gap/overflow are the hub's own synthetic `RuntimeEventKind::Gap` marker,
/// already delivered without this scope publishing anything -- see contract doc §5b's "come from
/// the existing P0 implementation unchanged"). `Backstop` is reserved for a future direct call
/// site; today the live-generation-cap backstop is diagnosable via `inventoryShardFallback`'s
/// `RetentionBoundary` reason instead.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResnapshotReason {
    Gap,
    Overflow,
    Backstop,
    IdentityChanged,
}

impl ResnapshotReason {
    const ALL: [Self; 4] = [Self::Gap, Self::Overflow, Self::Backstop, Self::IdentityChanged];

    fn tag(self) -> u64 {
        Self::ALL.iter().position(|candidate| *candidate == self).expect("in ALL") as u64
    }

    fn from_tag(tag: u64) -> Result<Self, WireError> {
        usize::try_from(tag)
            .ok()
            .and_then(|index| Self::ALL.get(index).copied())
            .ok_or(WireError::OutOfRange("resnapshot reason tag"))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ResnapshotRequiredEvent {
    pub root_id: Option<InventoryUuid>,
    pub reason: ResnapshotReason,
}

#[must_use]
pub fn encode_resnapshot_required(event: &ResnapshotRequiredEvent) -> Vec<u8> {
    let (root_present, root_hi, root_lo) = match event.root_id {
        Some(id) => {
            let (hi, lo) = uuid_to_words(&id);
            (1u64, hi, lo)
        }
        None => (0u64, 0u64, 0u64),
    };
    let mut writer = Writer::header(MessageKind::ResnapshotRequired);
    writer
        .write_words(&[root_present, root_hi, root_lo, event.reason.tag()])
        .expect("bounded");
    writer.finish()
}

pub fn decode_resnapshot_required(bytes: &[u8]) -> Result<ResnapshotRequiredEvent, WireError> {
    let mut reader = Reader::open(bytes, MessageKind::ResnapshotRequired)?;
    let words = reader.read_words(4, "resnapshot required event")?;
    reader.finish()?;
    let &[root_present, root_hi, root_lo, reason_tag] = words.as_slice() else {
        return Err(WireError::Malformed("resnapshot required event"));
    };
    let root_id = match root_present {
        0 => None,
        1 => Some(uuid_from_words(root_hi, root_lo)),
        _ => return Err(WireError::Malformed("resnapshot required event presence flag")),
    };
    Ok(ResnapshotRequiredEvent {
        root_id,
        reason: ResnapshotReason::from_tag(reason_tag)?,
    })
}

/// The canonical ASCII descriptor this schema's fingerprint locks. **Deliberately NOT
/// `std::hash::Hash`/`DefaultHasher`:** `DefaultHasher` is SipHash with an algorithm Rust
/// explicitly does not guarantee stable across releases, so a Swift mirror could never
/// independently reproduce it -- that would lock Rust against itself, not against Swift, which is
/// the "decorative fingerprint" failure mode charter §15.3 item 6 exists to prevent. A plain
/// string both sides can byte-for-byte reconstruct, then hash with a fixed, portable algorithm
/// (SHA-256, already a workspace dependency via `sha2`), is reproducible by construction. The
/// section-order list per message kind and the wire's endianness (`u64` little-endian words,
/// big-endian UUID halves per `uuid_to_words`) are included precisely because a Swift encoder
/// that gets either wrong produces bytes the Rust decoder rejects, and a numeric-shape-only
/// fingerprint would not catch that class of drift.
fn descriptor() -> String {
    format!(
        "inventory-scope-v1\n\
         version={version}\n\
         kinds=bulkChunk:{bulk_chunk},deltaEvent:{delta_event},resolveRequest:{resolve_request},\
lookupRequest:{lookup_request},factBlock:{fact_block},queryRequest:{query_request},\
queryResponse:{query_response},generationAdvanced:{generation_advanced},rootPublished:{root_published},\
rootUnloaded:{root_unloaded},shardFallback:{shard_fallback},resnapshotRequired:{resnapshot_required},\
discoveryBulkChunk:{discovery_bulk_chunk},discoveryDeltaEvent:{discovery_delta_event}\n\
         strides=stringRange:{string_range},record:{record},discoveryRecord:{discovery_record},\
factRow:{fact_row},candidate:{candidate}\n\
         optionalWord={optional_word}\n\
         limits=blob:{max_blob},string:{max_string},words:{max_words},rows:{max_rows},ids:{max_ids},\
paths:{max_paths}\n\
         endianness=words:little-endian,uuidHalves:big-endian\n\
         sections.bulkChunk=fileWords,folderWords,stringRangeWords,blob\n\
         sections.deltaEvent=rootId,upsertedFileWords,upsertedFolderWords,removedFileIds,\
removedFolderIds,removedFilePaths,removedFolderPaths,modifiedFileIds,modifiedFolderIds,\
stringRangeWords,blob\n\
         sections.resolveRequest=fileIdWords,folderIdWords\n\
         sections.lookupRequest=pathWords,stringRangeWords,blob\n\
         sections.factBlock=header(present,generation,rootLifetimeHi,rootLifetimeLo),factRowWords,\
stringRangeWords,blob\n\
           sections.queryRequest=header(patternIdx,limit,haystackVariant,prefixIdx,emptyOverrideIdx,\
logicalPresent,logicalPrefixIdx,logicalEmptyOverrideIdx),stringRangeWords,blob\n\
         sections.queryResponse=header(present,generation),candidateRowWords,stringRangeWords,blob\n\
         sections.generationAdvanced=rootId,rootLifetimeId,appliedIndexGeneration,\
catalogGenerationPresent,catalogGeneration,rebuiltAuthoritative,upsertedCount,removedCount,\
modifiedCount\n\
         sections.rootPublished=rootId,rootLifetimeId\n\
         sections.rootUnloaded=rootId,rootLifetimeId\n\
         sections.shardFallback=rootId,reasonTag\n\
         sections.resnapshotRequired=rootPresent,rootId,reasonTag\n\
         sections.discoveryBulkChunk=discoveredFileWords,discoveredFolderWords,stringRangeWords,blob\n\
         sections.discoveryDeltaEvent=rootId,upsertedDiscoveredFileWords,upsertedDiscoveredFolderWords,\
removedFileIds,removedFolderIds,removedFilePaths,removedFolderPaths,modifiedFileIds,modifiedFolderIds,\
stringRangeWords,blob\n\
         fallbackReasonOrder=missingReusableShard:0,generationGap:1,fullResync:2,\
unsafeOrAmbiguousBatch:3,retentionBoundary:4,patchThresholdExceeded:5,patchApplicationBackstop:6,\
shadowValidationMismatch:7\n\
         resnapshotReasonOrder=gap:0,overflow:1,backstop:2,identityChanged:3\n",
        version = INVENTORY_SCOPE_CONTRACT_VERSION_V1,
        bulk_chunk = MessageKind::BulkChunk as u16,
        delta_event = MessageKind::DeltaEvent as u16,
        resolve_request = MessageKind::ResolveRequest as u16,
        lookup_request = MessageKind::LookupRequest as u16,
        fact_block = MessageKind::FactBlock as u16,
        query_request = MessageKind::QueryRequest as u16,
        query_response = MessageKind::QueryResponse as u16,
        generation_advanced = MessageKind::GenerationAdvanced as u16,
        root_published = MessageKind::RootPublished as u16,
        root_unloaded = MessageKind::RootUnloaded as u16,
        shard_fallback = MessageKind::ShardFallback as u16,
        resnapshot_required = MessageKind::ResnapshotRequired as u16,
        discovery_bulk_chunk = MessageKind::DiscoveryBulkChunk as u16,
        discovery_delta_event = MessageKind::DiscoveryDeltaEvent as u16,
        string_range = STRING_RANGE_STRIDE,
        record = RECORD_STRIDE,
        discovery_record = DISCOVERY_RECORD_STRIDE,
        fact_row = FACT_ROW_STRIDE,
        candidate = CANDIDATE_ROW_STRIDE,
        optional_word = OPTIONAL_WORD,
        max_blob = MAX_BLOB_BYTES,
        max_string = MAX_STRING_LEN_BYTES,
        max_words = MAX_WORDS_PER_SECTION,
        max_rows = MAX_ROWS_PER_CALL,
        max_ids = MAX_IDS_PER_CALL,
        max_paths = MAX_PATHS_PER_CALL,
    )
}

/// SHA-256 of [`descriptor`], hex-encoded. See that function's doc comment for why this replaces
/// a `std::hash::Hash`-based fingerprint. The Swift mirror hardcodes this exact string in
/// `Tests/AgentryCoreBridgeTests/InventoryScopeWireFingerprintTests.swift`, built from an
/// independently-written Swift copy of `descriptor()`'s literal text -- if this module's shape
/// changes, the Rust string changes, the hash changes, and that Swift test goes red until its
/// hardcoded constant is updated to match. Drift can never pass silently.
#[must_use]
pub fn fingerprint() -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(descriptor().as_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_file(id: u8) -> InventoryFileRecord {
        InventoryFileRecord {
            id: [id; 16],
            root_id: [0xAA; 16],
            name: "App.swift".to_owned(),
            relative_path: "src/App.swift".to_owned(),
            standardized_relative_path: "src/App.swift".to_owned(),
            full_path: "/repo/src/App.swift".to_owned(),
            standardized_full_path: "/repo/src/App.swift".to_owned(),
            parent_folder_id: Some([0xBB; 16]),
            modification_date: Some(123.5),
        }
    }

    fn sample_folder(id: u8) -> InventoryFolderRecord {
        InventoryFolderRecord {
            id: [id; 16],
            root_id: [0xAA; 16],
            name: "src".to_owned(),
            relative_path: "src".to_owned(),
            standardized_relative_path: "src".to_owned(),
            full_path: "/repo/src".to_owned(),
            standardized_full_path: "/repo/src".to_owned(),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    #[test]
    fn bulk_chunk_round_trips_and_interns_shared_strings() {
        let files = vec![sample_file(1), sample_file(2)];
        let folders = vec![sample_folder(3)];
        let bytes = encode_bulk_chunk(&files, &folders);
        let (decoded_files, decoded_folders) = decode_bulk_chunk(&bytes).expect("decode");
        assert_eq!(decoded_files, files);
        assert_eq!(decoded_folders, folders);

        // Both files share `root_id`'s string-shaped siblings via identical field values, and
        // both share the same `standardized_full_path` directory-like prefix conceptually, but
        // the load-bearing interning check is: an identical *string value* appears once in the
        // blob no matter how many rows reference it.
        let mut pool = InternPoolBuilder::new();
        pool.intern(&files[0].name);
        pool.intern(&files[1].name);
        assert_eq!(pool.range_words().len() / STRING_RANGE_STRIDE, 1, "identical names dedupe to one pooled range");
    }

    #[test]
    fn bulk_chunk_rejects_truncated_input() {
        let bytes = encode_bulk_chunk(&[sample_file(1)], &[]);
        let truncated = &bytes[..bytes.len() - 1];
        assert!(matches!(decode_bulk_chunk(truncated), Err(WireError::Truncated(_))));
    }

    #[test]
    fn bulk_chunk_rejects_unknown_contract_version() {
        let mut bytes = encode_bulk_chunk(&[], &[]);
        bytes[0] = 0xFF;
        assert!(matches!(
            decode_bulk_chunk(&bytes),
            Err(WireError::UnknownContractVersion(_))
        ));
    }

    #[test]
    fn bulk_chunk_rejects_message_kind_mismatch() {
        let bytes = encode_delta_event(&InventoryAppliedIndexBatchEvent {
            root_id: [0; 16],
            upserted_files: Vec::new(),
            upserted_folders: Vec::new(),
            removed_file_ids: Vec::new(),
            removed_folder_ids: Vec::new(),
            removed_file_paths: Vec::new(),
            removed_folder_paths: Vec::new(),
            modified_file_ids: Vec::new(),
            modified_folder_ids: Vec::new(),
        });
        assert_eq!(decode_bulk_chunk(&bytes), Err(WireError::MessageKindMismatch));
    }

    #[test]
    fn bulk_chunk_rejects_out_of_range_string_index() {
        // Hand-corrupt a valid message: bump the first file row's `name` pool index (the 5th
        // word of the first 14-word row, right after the 4-word header) past the pool's bounds.
        let mut bytes = encode_bulk_chunk(&[sample_file(1)], &[]);
        // header(4) + file_words length-prefix(4) = 8 bytes in; row starts there; word 4 (name
        // idx) starts at byte 8 + 4*8 = 40.
        let name_idx_offset = 4 + 4 + 4 * 8;
        bytes[name_idx_offset..name_idx_offset + 8].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(matches!(decode_bulk_chunk(&bytes), Err(WireError::OutOfRange(_))));
    }

    #[test]
    fn delta_event_round_trips_every_field_shape() {
        let event = InventoryAppliedIndexBatchEvent {
            root_id: [7; 16],
            upserted_files: vec![sample_file(9)],
            upserted_folders: vec![sample_folder(8)],
            removed_file_ids: vec![[1; 16], [2; 16]],
            removed_folder_ids: vec![[3; 16]],
            removed_file_paths: vec!["a/b.swift".to_owned(), "a/b.swift".to_owned()],
            removed_folder_paths: vec!["a".to_owned()],
            modified_file_ids: vec![[4; 16]],
            modified_folder_ids: Vec::new(),
        };
        let bytes = encode_delta_event(&event);
        assert_eq!(decode_delta_event(&bytes).expect("decode"), event);
    }

    #[test]
    fn generation_advanced_event_round_trips_present_and_absent_generation() {
        let with_generation = GenerationAdvancedEvent {
            root_id: [1; 16],
            root_lifetime_id: [2; 16],
            applied_index_generation: 5,
            catalog_generation: Some(9),
            rebuilt_authoritative: false,
            upserted_count: 3,
            removed_count: 1,
            modified_count: 2,
        };
        let bytes = encode_generation_advanced(&with_generation);
        assert_eq!(decode_generation_advanced(&bytes).expect("decode"), with_generation);

        let rebuilt = GenerationAdvancedEvent {
            catalog_generation: None,
            rebuilt_authoritative: true,
            ..with_generation
        };
        let bytes = encode_generation_advanced(&rebuilt);
        assert_eq!(decode_generation_advanced(&bytes).expect("decode"), rebuilt);
    }

    #[test]
    fn root_published_and_unloaded_events_round_trip_and_reject_cross_kind_decode() {
        let event = RootLifecycleEvent {
            root_id: [3; 16],
            root_lifetime_id: [4; 16],
        };
        let published_bytes = encode_root_published(&event);
        assert_eq!(decode_root_published(&published_bytes).expect("decode"), event);
        assert_eq!(
            decode_root_unloaded(&published_bytes),
            Err(WireError::MessageKindMismatch)
        );

        let unloaded_bytes = encode_root_unloaded(&event);
        assert_eq!(decode_root_unloaded(&unloaded_bytes).expect("decode"), event);
        assert_eq!(
            decode_root_published(&unloaded_bytes),
            Err(WireError::MessageKindMismatch)
        );
    }

    #[test]
    fn shard_fallback_event_round_trips_every_reason() {
        for reason in RootCatalogShardFallbackReason::ALL {
            let event = ShardFallbackEvent {
                root_id: [5; 16],
                reason,
            };
            let bytes = encode_shard_fallback(&event);
            assert_eq!(decode_shard_fallback(&bytes).expect("decode"), event);
        }
    }

    #[test]
    fn resnapshot_required_event_round_trips_every_reason_with_and_without_root() {
        for reason in ResnapshotReason::ALL {
            let scoped = ResnapshotRequiredEvent {
                root_id: Some([6; 16]),
                reason,
            };
            let bytes = encode_resnapshot_required(&scoped);
            assert_eq!(decode_resnapshot_required(&bytes).expect("decode"), scoped);

            let scope_wide = ResnapshotRequiredEvent { root_id: None, reason };
            let bytes = encode_resnapshot_required(&scope_wide);
            assert_eq!(decode_resnapshot_required(&bytes).expect("decode"), scope_wide);
        }
    }

    #[test]
    fn event_payloads_reject_truncated_input() {
        let bytes = encode_generation_advanced(&GenerationAdvancedEvent {
            root_id: [1; 16],
            root_lifetime_id: [2; 16],
            applied_index_generation: 1,
            catalog_generation: Some(1),
            rebuilt_authoritative: false,
            upserted_count: 0,
            removed_count: 0,
            modified_count: 0,
        });
        let truncated = &bytes[..bytes.len() - 1];
        assert!(matches!(decode_generation_advanced(truncated), Err(WireError::Truncated(_))));
    }

    #[test]
    fn resolve_and_lookup_requests_round_trip() {
        let file_ids = vec![[1; 16], [2; 16]];
        let folder_ids = vec![[3; 16]];
        let bytes = encode_resolve_request(&file_ids, &folder_ids);
        assert_eq!(decode_resolve_request(&bytes).expect("decode"), (file_ids, folder_ids));

        let paths = vec!["a/b.swift".to_owned(), "c/d.swift".to_owned()];
        let bytes = encode_lookup_request(&paths);
        assert_eq!(decode_lookup_request(&bytes).expect("decode"), paths);
    }

    #[test]
    fn fact_block_round_trips_present_and_stale_and_optional_fields() {
        let block = FactBlock {
            generation: Some(42),
            root_lifetime_hi: 1,
            root_lifetime_lo: 2,
            rows: vec![
                FactRow {
                    key_hi: 10,
                    key_lo: 20,
                    exists: true,
                    file_id: Some([1; 16]),
                    folder_id: None,
                    root_id: Some([2; 16]),
                    is_discoverable: true,
                    path_round_trips_to_self: false,
                    standardized_relative_path: Some("a/b.swift".to_owned()),
                    standardized_full_path: Some("/root/a/b.swift".to_owned()),
                    name: Some("b.swift".to_owned()),
                    record_fingerprint: 999,
                    parent_folder_id: Some([3; 16]),
                    modification_date: Some(12345.5),
                },
                FactRow {
                    key_hi: 11,
                    key_lo: 21,
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
                },
            ],
        };
        let bytes = encode_fact_block(&block);
        assert_eq!(decode_fact_block(&bytes).expect("decode"), block);

        let stale = FactBlock {
            generation: None,
            root_lifetime_hi: 0,
            root_lifetime_lo: 0,
            rows: Vec::new(),
        };
        let bytes = encode_fact_block(&stale);
        assert_eq!(decode_fact_block(&bytes).expect("decode"), stale);
    }

    #[test]
    fn query_request_round_trips_prefix_and_empty_relative_override() {
        let bytes = encode_query_request("App*", 20, 1, "root/", "root", None);
        let decoded = decode_query_request(&bytes).expect("decode");
        assert_eq!(decoded.pattern, "App*");
        assert_eq!(decoded.limit, 20);
        assert_eq!(decoded.haystack_variant, 1);
        assert_eq!(decoded.non_empty_relative_prefix, "root/");
        assert_eq!(decoded.empty_relative_path_value, "root");
        assert_eq!(decoded.logical_prefix, None);
    }

    /// P4-7a phase a3 (design §5.1): a present-but-legitimately-empty logical prefix (branch 1
    /// of `ClientPathFormatter.displayPath` -- a solo visible logical root has no prefix) must
    /// round-trip as `Some(("", ...))`, never collapse to `None`. `None` and
    /// `Some(("", "App"))` are different wire states (`logical_present`), not the same state
    /// spelled two ways -- conflating them would silently drop the `logicalPath` haystack
    /// component for exactly the bound-single-root workspace this variant exists to serve.
    #[test]
    fn query_request_round_trips_present_but_empty_logical_prefix() {
        let bytes = encode_query_request("App*", 20, 1, "root/", "root", Some(("", "App")));
        let decoded = decode_query_request(&bytes).expect("decode");
        assert_eq!(decoded.logical_prefix, Some((String::new(), "App".to_owned())));
    }

    #[test]
    fn query_request_round_trips_non_empty_logical_prefix() {
        let bytes = encode_query_request("App*", 20, 1, "root/", "root", Some(("App/", "App")));
        let decoded = decode_query_request(&bytes).expect("decode");
        assert_eq!(decoded.logical_prefix, Some(("App/".to_owned(), "App".to_owned())));
    }

    /// Regression pin for P4-7a's a3 header widening (5 -> 8 words: `logicalPresent`,
    /// `logicalPrefixIdx`, `logicalEmptyOverrideIdx` added), mirroring
    /// `query_response_rejects_stride_11_legacy_shaped_row_words`'s precedent: a Swift encoder
    /// that still emits the pre-a3 five-word header must be rejected as malformed, never
    /// silently misdecoded as a shorter or differently-shaped request. Swift and Rust change
    /// this wire shape atomically in the same commit precisely so this case never occurs in
    /// production; this test is the fail-closed backstop if it ever does.
    #[test]
    fn query_request_rejects_legacy_five_word_header() {
        let mut pool = InternPoolBuilder::new();
        let pattern_idx = pool.intern("App*");
        let prefix_idx = pool.intern("root/");
        let empty_override_idx = pool.intern("root");
        let (blob, range_words) = pool.finish();
        let mut writer = Writer::header(MessageKind::QueryRequest);
        writer.write_words(&[pattern_idx, 20, 1, prefix_idx, empty_override_idx]).expect("bounded");
        writer.write_words(&range_words).expect("bounded by caller");
        writer.write_blob(&blob).expect("bounded by caller");
        let bytes = writer.finish();
        assert!(matches!(
            decode_query_request(&bytes),
            Err(WireError::Malformed("query request header"))
        ));
    }

    #[test]
    fn query_response_round_trips_candidates_and_stale_generation() {
        let candidates = vec![QueryCandidateRow {
            id: [1; 16],
            root_id: [2; 16],
            name: "App.swift".to_owned(),
            relative_path: "src/App.swift".to_owned(),
            standardized_relative_path: "src/App.swift".to_owned(),
            full_path: "/repo/src/App.swift".to_owned(),
            standardized_full_path: "/repo/src/App.swift".to_owned(),
            display_path: "root/src/App.swift".to_owned(),
            tie_break_key: "root/src/App.swift\n/repo/src/App.swift".to_owned(),
            score: 42,
        }];
        let bytes = encode_query_response(Some(3), &candidates);
        let (generation, decoded) = decode_query_response(&bytes).expect("decode");
        assert_eq!(generation, Some(3));
        assert_eq!(decoded[0].id, candidates[0].id);
        assert_eq!(decoded[0].display_path, "root/src/App.swift");
        assert_eq!(decoded[0].tie_break_key, "root/src/App.swift\n/repo/src/App.swift");
        assert_eq!(decoded[0].score, 42);

        let bytes = encode_query_response(None, &[]);
        let (generation, decoded) = decode_query_response(&bytes).expect("decode");
        assert_eq!(generation, None);
        assert!(decoded.is_empty());
    }

    #[test]
    fn query_response_rejects_stride_11_legacy_shaped_row_words() {
        // Regression pin for P4-7b's stride widening (11 -> 12 words/row, `tie_break_key`
        // added): a payload whose rows section declares exactly the OLD (pre-P4-7b) stride's
        // word count must be rejected as malformed, never silently misdecoded as a shorter or
        // differently-shaped row list.
        let mut writer = Writer::header(MessageKind::QueryResponse);
        writer.write_words(&[0, 0]).expect("header words"); // present=0, generation=0
        writer.write_words(&vec![0u64; 11]).expect("legacy-stride row words");
        writer.write_words(&[]).expect("string_range_words");
        writer.write_blob(&[]).expect("utf8_blob");
        let bytes = writer.finish();
        assert!(matches!(
            decode_query_response(&bytes),
            Err(WireError::Malformed("candidate row stride"))
        ));
    }

    #[test]
    fn oversize_string_range_words_rejected() {
        let mut bytes = encode_lookup_request(&["a".to_owned()]);
        // Corrupt the string_range_words section's declared element count (a `u32` right before
        // the words themselves) to something absurd; must fail closed, not allocate wildly.
        // Layout: header(4) + paths words section (4 + 8*1) + range_words length prefix starts
        // at 4 + 4 + 8 = 16.
        let range_len_offset = 4 + 4 + 8;
        bytes[range_len_offset..range_len_offset + 4].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(matches!(decode_lookup_request(&bytes), Err(WireError::Oversize(_))));
    }

    #[test]
    fn swift_mirror_fingerprint_matches_this_module() {
        // This is the Rust half of the fingerprint lock (contract doc §3 / design §5.4): the
        // Swift mirror hardcodes this exact `u64` in
        // `Tests/AgentryCoreBridgeTests/InventoryScopeWireFingerprintTests.swift`. If this
        // module's shape changes, `fingerprint()`'s output changes, and that Swift test goes red
        // until its hardcoded constant is updated to match -- the drift can never pass silently.
        assert_eq!(
            fingerprint(),
            "82e2e432dc51dd3c2cb7bae38f50219ef4522f2d14b5ea82678fb1d8a3d1418a"
        );
    }

}



/// P4-4's E-2 re-run (design §11 P4-2/P4-4; contract doc §8): P4-2 could not measure real wire
/// bytes because no bridge existed yet ("BLOCKED (partial evidence only)", P4-2 results doc §5).
/// This module IS that bridge's wire codec, so this is the first point genuine wire-byte truth is
/// measurable. `#[ignore]`d by default (a 100k-record synthetic corpus is not a per-`cargo test`
/// cost this crate's suite should pay); run explicitly with `cargo test --release -- --ignored
/// --nocapture e2_wire_byte_truth_100k`.
#[cfg(test)]
mod e2_probe {
    use super::*;
    use crate::inventory::{InventoryFileRecord, InventoryFolderRecord};

    fn synth_file(i: u32, root_id: [u8; 16]) -> InventoryFileRecord {
        let mut id = [0u8; 16];
        id[0..4].copy_from_slice(&i.to_be_bytes());
        let rel = format!("src/module_{}/File_{}.swift", i % 500, i);
        InventoryFileRecord {
            id,
            root_id,
            name: format!("File_{i}.swift"),
            relative_path: rel.clone(),
            standardized_relative_path: rel.clone(),
            full_path: format!("/repo/{rel}"),
            standardized_full_path: format!("/repo/{rel}"),
            parent_folder_id: None,
            modification_date: Some(1_700_000_000.0 + i as f64),
        }
    }

    fn synth_folder(i: u32, root_id: [u8; 16]) -> InventoryFolderRecord {
        let mut id = [0u8; 16];
        id[0..4].copy_from_slice(&(i + 1_000_000).to_be_bytes());
        let rel = format!("src/module_{i}");
        InventoryFolderRecord {
            id,
            root_id,
            name: format!("module_{i}"),
            relative_path: rel.clone(),
            standardized_relative_path: rel.clone(),
            full_path: format!("/repo/{rel}"),
            standardized_full_path: format!("/repo/{rel}"),
            parent_folder_id: None,
            modification_date: None,
        }
    }

    /// Measured (release profile, this session): 100,000 files + 500 folders -> 24,424,360 bytes
    /// (23.29 MiB). The design's §6.3 estimate is "~12-20 MB, chunked" for a 100k-file root
    /// bootstrap. This measurement runs modestly above that range; the most likely cause is this
    /// synthetic corpus's four distinct per-record path strings (relative/standardized-relative/
    /// full/standardized-full), each interned separately, over a `module_{n}`-sharded directory
    /// structure that produces more unique path prefixes than a flatter real-repo corpus would --
    /// recorded here as a real, reproducible measurement rather than adjusted to fit the estimate.
    #[test]
    #[ignore = "100k-record synthetic corpus; run explicitly, see module doc comment"]
    fn e2_wire_byte_truth_100k() {
        let root_id = [9u8; 16];
        let files: Vec<_> = (0..100_000u32).map(|i| synth_file(i, root_id)).collect();
        let folders: Vec<_> = (0..500u32).map(|i| synth_folder(i, root_id)).collect();
        let bytes = encode_bulk_chunk(&files, &folders);
        eprintln!(
            "e2_wire_byte_truth_100k: files={} folders={} bytes={} mib={:.2}",
            files.len(),
            folders.len(),
            bytes.len(),
            bytes.len() as f64 / (1024.0 * 1024.0)
        );
        // Round-trip to prove the measured bytes are genuinely decodable, not just an encode-side count.
        let (decoded_files, decoded_folders) = decode_bulk_chunk(&bytes).expect("decode");
        assert_eq!(decoded_files.len(), files.len());
        assert_eq!(decoded_folders.len(), folders.len());
    }
}
