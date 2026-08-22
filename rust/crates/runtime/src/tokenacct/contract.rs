//! Wire/contract constants for the P3-4 DIFFERENTIAL-ONLY token-accounting batch entry. Mirrors
//! the shape of `pathsearch::contract`: a version tag plus the word-table strides used by
//! `wire.rs` to encode/decode the compact batch request/response.
//!
//! IMPORTANT: this wire is differential-only -- see `wire.rs`'s module doc.

pub const TOKEN_ACCOUNTING_CONTRACT_VERSION_V1: u16 = 1;

/// Words per pooled string range entry (`start`, `end` byte offsets into `utf8_blob`).
pub const STRING_RANGE_STRIDE: usize = 2;

/// Words per entry row: `is_codemap_requested, codemap_content_present, codemap_content_idx,
/// available_codemap_token_count, resolved_as_slice, slice_combined_text_idx,
/// slice_total_characters, loaded_content_present, loaded_content_idx,
/// loaded_content_char_count, cached_full_token_count_present, cached_full_token_count,
/// relative_path_idx`. See `wire.rs` module doc for field semantics and decode's strict
/// presence-flag/empty-payload consistency contract.
pub const ENTRY_STRIDE: usize = 13;

/// Words per entry-result row: `render_mode, display_tokens, full_tokens, codemap_tokens,
/// display_line_count_present, display_line_count, char_count_contribution`, index-aligned with
/// the request's entry rows.
pub const ENTRY_RESULT_STRIDE: usize = 7;

/// Words per component-breakdown request row: `prompt_idx, instructions_idx, file_tree_idx,
/// git_diff_idx, metadata_idx, duplicate_user_instructions_at_top`.
pub const COMPONENT_STRIDE: usize = 6;

/// Words per component-breakdown result row: `prompt, duplicate_prompt, instructions, file_tree,
/// git_diff, metadata`, index-aligned with the request's component rows.
pub const COMPONENT_RESULT_STRIDE: usize = 6;
