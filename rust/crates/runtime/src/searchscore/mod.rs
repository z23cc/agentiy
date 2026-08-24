//! Pure-Rust implementation of the production search-scoring batch contract.
//!
//! Compatibility is pinned to the former C entry point, `repo_score_matches_batch` in
//! `Sources/RepoPromptC/src/Utils/search_scoring.c`. `RepoSearchBatchScorer.swift` now reaches this
//! module through the versioned UniFFI batch API. The Swift wrapper supplies each original UTF-8 string together
//! with its already-lowercased UTF-8 form, supplies the raw/lowercased query and its slash/wildcard
//! flags, and receives one score per candidate in input order. Equal scores are not reordered.
//! The first matching tier wins: filename/extension exact 1000, path exact 950, filename prefix
//! 900, slash-query path prefix 875, component prefix 850, filename or non-slash path contains
//! 750, slash-query path contains 700, wildcard 650, filename fuzzy 500, component fuzzy 450,
//! otherwise 0.
//!
//! # Pinned C-semantics decisions
//!
//! - Inputs are byte slices because the C engine operates on NUL-terminated UTF-8 bytes. An
//!   embedded NUL ends the effective C string. The caller-provided lowercase bytes are authoritative;
//!   this module does not apply Unicode lowercasing or repair inconsistent pairs.
//! - C-locale folding is ASCII-only wherever the C code itself calls `tolower`. The live scorer's
//!   wildcard call does **not** actually enable case folding because its private `WM_CASEFOLD` value
//!   is `0x08` while the bundled matcher uses `0x10`; wildcard literals/ranges/classes are therefore
//!   case-sensitive. Dice bigrams still use ASCII folding. Exact, prefix, component, and substring
//!   tiers compare the supplied lowercase bytes directly, matching the live pre-lowercased path.
//! - Filename-without-extension work copies at most 1023 bytes; path-component and component-fuzzy
//!   work copies at most 2047 bytes. Direct exact/prefix/substring checks remain unbounded, as in C.
//! - `/` alone separates path components. Empty components are skipped like `strtok_r`; backslashes
//!   are ordinary bytes. A non-slash query may receive the filename-tier score (750) from a path
//!   substring, preserving the C implementation's documented exception.
//! - Wildcards use the bundled matcher with pathname and leading-directory behavior. The scorer's
//!   private `WM_WILDSTAR` value is `0x20`, while the matcher uses `0x40`, so repeated stars collapse
//!   to one ordinary star and cannot cross `/`. Only a leading `**/` crosses components, through the
//!   scorer's explicit suffix loop. Bracket expressions and escapes remain recognized. Wildcard
//!   queries never fall through to fuzzy matching.
//! - Fuzzy selection uses byte length for the 64-byte Dice switch, cap calculation, and normalized
//!   denominator. At or below 64 bytes the edit distance compares UTF-8 character byte sequences;
//!   over the 15% cap it falls back to case-folded byte-bigram Dice, exactly like
//!   `repo_similarity_score`.
//! - The Swift wrapper returns an empty vector when candidates or the Swift query are empty. For a
//!   nonempty query whose effective C string begins with NUL, each candidate receives zero.
//!
//! The versioned production FFI exports this exact ordered batch contract. The header's
//! single-score, zero-copy, compiled-wildcard, and multi-threaded variants are outside the live
//! contract and are not ported.

mod score;

pub use score::{Candidate, Query, score_matches_batch};

pub const SEARCH_SCORE_CONTRACT_VERSION_V1: u16 = 1;

#[cfg(test)]
mod tests;
