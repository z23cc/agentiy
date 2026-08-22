//! Wire/contract constants for the P3-3 slice-1 workspace path-matching scoring-kernel port.
//!
//! Mirrors the shape of `inventory::contract`: a version tag plus the word-table strides used by
//! `score.rs` to encode/decode the batch scoring request and response.

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
