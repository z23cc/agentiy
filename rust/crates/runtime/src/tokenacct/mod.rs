//! Pure-Rust port of the Swift workspace token-accounting compute kernel
//! (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/`): the byte-count token
//! estimator (`TokenCalculationService.estimateTokens`), the byte-level line counter
//! (`WorkspaceTextLineCounter.countLines`), the component-breakdown heuristic
//! (`TokenCalculationService.calculateComponentBreakdown`), and the per-entry token/render-mode
//! aggregation (`TokenCalculationService.calculateEntryTokens` /
//! `evaluatePromptEntries`, plus the `TokenInfo` formatted-string/percentage derivation).
//!
//! # Phase scope (P3-4)
//!
//! This is a cargo-only pure-Rust port PLUS a DIFFERENTIAL-ONLY batch FFI entry
//! (`wire.rs`'s `TokenAccountingService`, wired behind `rust/crates/ffi`'s `token_accounting_v1`,
//! following the `pathsearch::wire` conventions -- see that module's doc for the shared
//! rationale). It exists solely to drive a byte-exact Rust-vs-Swift differential test
//! (`TokenAccountingRustSwiftDifferentialTests`). It deliberately does NOT replace
//! `TokenCalculationService` on the Swift side and is NOT a production caller switch.
//!
//! # Byte-exact parity goal and Unicode decisions
//!
//! `estimate_tokens`/`count_lines`/`extract_folder_path` operate purely on UTF-8 bytes (ASCII
//! delimiters `\n` (10), `\r` (13), `/` (0x2F) never occur as a continuation byte inside a
//! multi-byte UTF-8 sequence, so scanning/splitting raw bytes is safe and needs no Unicode
//! text-segmentation library). These three are therefore full, self-contained Rust ports with no
//! escape hatch.
//!
//! Two Swift-side computations use grapheme-cluster-aware `String.count` (Unicode text
//! segmentation, i.e. an ICU-shaped dependency Rust has no bit-exact equivalent for without
//! vendoring Swift's exact UAX#29 tables):
//!
//! - `entry.loadedContent?.count` (the full-mode `charCountContribution` fallback in
//!   `calculateEntryTokens`).
//! - `assembly.totalCharacters` (`WorkspaceSliceAssembly.totalCharacters`, i.e. `combinedText
//!   .count`, from `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceAssembly.swift`
//!   -- itself out of this port's source-of-truth file list, and NOT re-derived from `ranges`
//!   here).
//!
//! Both are handled with the **precompute-and-carry** pattern: the caller (the Swift differential
//! harness, using the real `String.count`) computes the grapheme count once and passes it across
//! the wire as an explicit word (`loaded_content_char_count`, `slice_total_characters`); this
//! crate never recomputes a character count from raw bytes. A third Unicode-adjacent site,
//! `TokenCalculationService.middleTruncate`'s grapheme-boundary-aligned truncation, is **kept
//! Swift-side and NOT ported** here: it is not part of this port's deliverable scope (estimation
//! heuristics, line counting, entry-metrics computation) and has no caller in the entry-metrics
//! path this module reproduces.
//!
//! `TokenInfo.formatted`/`percentage` (`String(format: "%.2fk", ...)` / a plain division) are
//! ported directly (`format::format_token_count`/`format::percentage`): both are ordinary IEEE-754
//! double-precision arithmetic and decimal formatting, not Unicode-sensitive.

pub mod components;
pub mod contract;
pub mod entries;
pub mod estimate;
mod wire;

pub use components::{ComponentBreakdown, ComponentInput, compute_component_breakdown};
pub use contract::{
    COMPONENT_RESULT_STRIDE, COMPONENT_STRIDE, ENTRY_RESULT_STRIDE, ENTRY_STRIDE,
    STRING_RANGE_STRIDE, TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
};
pub use entries::{
    Aggregates, CodeMapComposed, EntryInput, EntryResult, FolderTotals, RenderMode, compute_entries,
};
pub use estimate::{
    count_lines, estimate_tokens, estimate_tokens_from_byte_count, extract_folder_path,
    format_token_count, percentage,
};
pub use wire::{
    TokenAccountingError, TokenAccountingRequestV1, TokenAccountingResponseV1,
    TokenAccountingService,
};
