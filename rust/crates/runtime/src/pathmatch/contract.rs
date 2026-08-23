//! Wire/contract constants for the P3-3 slice-1 workspace path-matching scoring-kernel port.
//!
//! Mirrors the shape of the retired `inventory::contract` (deleted at P4-8 with
//! `inventory-compute-v1`): a version tag plus the word-table strides used by `score.rs` to
//! encode/decode the batch scoring request and response.

pub const PATH_MATCH_CONTRACT_VERSION_V1: u16 = 1;

/// Words per pooled string range entry (`start`, `end` byte offsets into `utf8_blob`).
pub const STRING_RANGE_STRIDE: usize = 2;

/// Words per candidate row: root_ordinal(1) + total_component_count(1) + tail_start(1) +
/// tail_count(1) + ordinal(1) = 5. See `score.rs` module doc for field semantics.
pub const CANDIDATE_STRIDE: usize = 5;

/// Fixed-point scale applied to the returned `f64` score before it crosses the wire as an `i64`
/// (`round(score * SCORE_SCALE)`), per the task's preference for an integer-scaled wire value over
/// a raw cross-language `f64`. The response ALSO carries the raw `f64` bit pattern
/// (`matched_scores_bits`) alongside the scaled value so callers/tests can assert bit-identical
/// equality directly; the integer scale is drift insurance, not a replacement for that check.
pub const SCORE_SCALE: f64 = 1_000_000.0;

// ---- P3-3 slice-2a: resolution-pipeline (`resolve.rs` + `indexes.rs`) wire constants ----------

pub const PATH_RESOLVE_CONTRACT_VERSION_V1: u16 = 1;

/// Words per root row: `full_path_idx, name_idx`. See `indexes.rs` module doc.
pub const ROOT_STRIDE: usize = 2;

/// Words per file row: `full_path_idx, relative_path_idx, root_ordinal, name_canonical_idx,
/// ext_idx, last_two_canonical_idx, component_start, component_count`. See `indexes.rs` module doc.
pub const FILE_STRIDE: usize = 8;

/// Words per folder row: `full_path_idx, relative_path_idx, root_ordinal, name_canonical_idx,
/// component_start, component_count`. See `indexes.rs` module doc.
pub const FOLDER_STRIDE: usize = 6;

/// Words per query row: `standardized_path_idx, canonical_component_start, component_count,
/// cleaned_lower_component_start`. See `indexes.rs` module doc.
pub const QUERY_STRIDE: usize = 4;
