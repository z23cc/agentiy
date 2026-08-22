//! Pure-Rust phase-one port of the live C search-scoring entry point.
//!
//! The production contract currently consists of `repo_score_matches_batch` in
//! `Sources/RepoPromptC/src/Utils/search_scoring.c`, called by
//! `RepoSearchBatchScorer.swift`. The Swift wrapper supplies each original UTF-8 string together
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
//! - C-locale folding is ASCII-only wherever the C code itself calls `tolower`: wildcard literals,
//!   wildcard ranges/classes, and Dice bigrams. Exact, prefix, component, and substring tiers compare
//!   the supplied lowercase bytes directly, matching the live pre-lowercased path.
//! - Filename-without-extension work copies at most 1023 bytes; path-component and component-fuzzy
//!   work copies at most 2047 bytes. Direct exact/prefix/substring checks remain unbounded, as in C.
//! - `/` alone separates path components. Empty components are skipped like `strtok_r`; backslashes
//!   are ordinary bytes. A non-slash query may receive the filename-tier score (750) from a path
//!   substring, preserving the C implementation's documented exception.
//! - Wildcards use the bundled wildmatch behavior with pathname, wildstar, and ASCII case-folding:
//!   `?` and a single `*` do not cross `/`; `**/` may cross components; bracket expressions and
//!   escapes are recognized. Wildcard queries never fall through to fuzzy matching.
//! - Fuzzy selection uses byte length for the 64-byte Dice switch, cap calculation, and normalized
//!   denominator. At or below 64 bytes the edit distance compares UTF-8 character byte sequences;
//!   over the 15% cap it falls back to case-folded byte-bigram Dice, exactly like
//!   `repo_similarity_score`.
//! - The Swift wrapper returns an empty vector when candidates or the Swift query are empty. For a
//!   nonempty query whose effective C string begins with NUL, each candidate receives zero.
//!
//! Phase one intentionally adds no FFI or generated bindings. The header's single-score,
//! zero-copy, compiled-wildcard, and multi-threaded variants are outside the live contract and are
//! not ported.

mod score;

pub use score::{Candidate, Query, score_matches_batch};

#[cfg(test)]
mod tests;
