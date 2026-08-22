//! Pure-Rust port of the C path search engine
//! (`Sources/RepoPromptC/src/Utils/path_search.c`, header
//! `Sources/RepoPromptC/include/path_search.h`), whose contract is documented and consumed by
//! the Swift wrapper `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift`.
//!
//! # Phase scope (P3-3 slice 2b phase 2)
//!
//! Phase 1 (60df20a5) was cargo-only: a self-contained behavioral port with no FFI wiring. This
//! phase adds a DIFFERENTIAL-ONLY batch FFI entry (`wire.rs`'s `PathSearchFindService`, wired
//! behind `rust/crates/ffi`'s `path_search_find_v1`) that exists solely to drive a byte-exact
//! Rust-vs-Swift(-vs-C) differential test. It deliberately does NOT replace the C implementation
//! on the Swift side, does NOT delete `path_search.c`, and is NOT the eventual production shape
//! -- see `wire.rs`'s module doc for why (production cutover needs the P4 stateful scope-registry
//! handle primitive, not a stateless whole-corpus-per-call FFI entry).
//!
//! # Byte-exact parity goal
//!
//! The C engine matches paths using POSIX `regcomp`/`regexec` (`REG_EXTENDED | REG_ICASE`) over
//! a glob-to-regex translation, plus `strcasestr` for space-separated AND-term search, both under
//! whatever locale the process happens to be running in (typically "C"/"POSIX" — i.e. **ASCII-only
//! case folding**, not Unicode-aware). This port does **not** shell out to a general regex engine;
//! instead it interprets the same glob-decomposition directly against a small token language and
//! matches it with an O(n·m) dynamic-programming matcher operating on raw bytes. This sidesteps:
//!
//! - Any regex-crate translation-fidelity risk (the C-generated ERE strings use only literal
//!   escapes, `[^/]*`, `[^/]`, `.*`, `^`, `$` — no alternation, no backreferences, no capturing
//!   groups — so the *recognized language* is what matters, not a specific engine's internal
//!   matching strategy; POSIX leftmost-longest and NFA/backtracking matchers necessarily agree on
//!   match/no-match for such patterns since match *existence* is a language-membership question).
//! - Catastrophic backtracking / ReDoS risk from naive recursive glob matching on chains of
//!   `[^/]*`-style stars (the DP table is linear in each dimension).
//!
//! See `glob` for the full decomposition/matching semantics and the C-semantics decision table in
//! the module doc there, and `engine` for the two engine entry points
//! (`PathSearchIndex::find`, `PathSearchIndex::projected_find`).

mod contract;
mod engine;
mod glob;
mod index;
mod wire;

pub use contract::{
    PATH_SEARCH_CONTRACT_VERSION_V1, QUERY_STRIDE, RESULT_RANGE_STRIDE, STATS_STRIDE,
    STRING_RANGE_STRIDE,
};
pub use engine::{PathSearchCancellation, PathSearchWorkStats, ProjectedSearchOutcome};
pub use glob::{Mode, PatternParts, Token, decompose};
pub use index::{PathSearchIndex, PathSearchMatch, ProjectedPathSearchMatch};
pub use wire::{
    PathSearchFindError, PathSearchFindRequestV1, PathSearchFindResponseV1, PathSearchFindService,
};

#[cfg(test)]
mod tests;
