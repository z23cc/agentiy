//! Wire/contract constants for the P3-3 slice-2b phase-2 DIFFERENTIAL-ONLY path-search batch
//! entry. Mirrors the shape of `pathmatch::contract`: a version tag plus the word-table strides
//! used by `wire.rs` to encode/decode the compact batch request/response.
//!
//! IMPORTANT: this wire is differential-only -- see `wire.rs`'s module doc for why (batches an
//! entire corpus plus every query into ONE call, which is NOT the eventual P4 stateful
//! production shape).

pub const PATH_SEARCH_CONTRACT_VERSION_V1: u16 = 1;

/// Words per pooled string range entry (`start`, `end` byte offsets into `utf8_blob`).
pub const STRING_RANGE_STRIDE: usize = 2;

/// Words per query row: `pattern_idx, limit, mode_flag, display_prefix_idx,
/// absolute_prefix_idx`. See `wire.rs` module doc for field semantics and `mode_flag`'s strict
/// 0/1 decode contract.
pub const QUERY_STRIDE: usize = 5;

/// Words per result-range row: `start, count` into `result_ordinals`, index-aligned with queries.
pub const RESULT_RANGE_STRIDE: usize = 2;

/// Words per stats row: `examined_count, matched_count, heap_peak_count,
/// heap_comparison_count, scratch_bytes`, index-aligned with queries. All-zero for find-mode
/// queries -- `path_search_find`/`PathSearchIndex::find` has no diagnostic contract in the C
/// source this ported from.
pub const STATS_STRIDE: usize = 5;
