//! P3-4: compact batch wire (request + response) for a DIFFERENTIAL-ONLY token-accounting entry
//! point, driving [`super::compute_entries`] and [`super::compute_component_breakdown`] over a
//! BATCH of entries/component rows in a single call. Follows `pathsearch::wire`'s conventions
//! (see that module's doc for the shared "differential-only, not production shape" rationale):
//! `TokenCalculationService` is an `actor` driven by live `PromptFileEntrySnapshot`/
//! `TokenCalculationSnapshot` values built from in-memory view-model state on every keystroke --
//! a stateless whole-batch-per-call FFI entry is fine for a byte-exact differential test but is
//! NOT how a real per-keystroke caller would be shaped. This wire exists ONLY to drive
//! `TokenAccountingRustSwiftDifferentialTests`; there is no production caller.
//!
//! # Wire shape
//!
//! - **String pool**: `utf8_blob` + `string_range_words` (stride [`super::STRING_RANGE_STRIDE`]:
//!   `start, end` byte offsets), exactly like `pathsearch::wire`'s pool convention. No
//!   `char_count`/`cleaned_byte_len` companion arrays here either: pooled strings are consumed
//!   as raw UTF-8 byte spans everywhere except the two explicit precompute-and-carry character
//!   counts below.
//! - **Entries** (stride [`super::ENTRY_STRIDE`]): `is_codemap_requested,
//!   codemap_content_present, codemap_content_idx, available_codemap_token_count,
//!   resolved_as_slice, slice_combined_text_idx, slice_total_characters,
//!   loaded_content_present, loaded_content_idx, loaded_content_char_count,
//!   cached_full_token_count_present, cached_full_token_count, relative_path_idx`. Every
//!   `*_present`/`resolved_as_slice`/`is_codemap_requested`/`codemap_content_present` flag word
//!   MUST decode to exactly `0` or `1` -- any other value is a decode error. Decode is
//!   fail-closed on presence/payload consistency, mirroring `pathsearch::wire`'s
//!   find-mode-prefix check: when a `*_present` flag is `0`, the paired pooled string MUST
//!   resolve to an empty string and the paired numeric word (character count / cached token
//!   count) MUST be `0` -- a builder bug can never produce a request whose wire shape lies about
//!   which fields are live. `loaded_content_char_count`/`slice_total_characters` are the
//!   precompute-and-carry grapheme (`String.count`) counts of `loaded_content`/
//!   `slice_combined_text` respectively; this wire never recomputes a character count from raw
//!   bytes (see `super`'s module doc).
//! - **Components** (stride [`super::COMPONENT_STRIDE`]): `prompt_idx, instructions_idx,
//!   file_tree_idx, git_diff_idx, metadata_idx, duplicate_flag`. `duplicate_flag` MUST decode to
//!   `0` or `1`.
//!
//! # Response shape
//!
//! - `entry_result_words` (stride [`super::ENTRY_RESULT_STRIDE`]): `render_mode, display_tokens,
//!   full_tokens, codemap_tokens, display_line_count_present, display_line_count,
//!   char_count_contribution`, index-aligned with the request's entries.
//!   `render_mode`: `0` = full, `1` = slice, `2` = codemap (resolved), `3` = codemap
//!   (unresolved).
//! - `entry_formatted` / `entry_percentage`: index-aligned with the request's entries;
//!   `super::format_token_count`/`super::percentage` applied to each entry's `display_tokens`
//!   against `combined_display_tokens` (mirrors the per-file `TokenInfo` Swift builds from
//!   `fileTokenInfo`).
//! - `aggregate_words`: a single row, `[total_content_tokens, full_count, slice_count,
//!   codemap_count, full_tokens, slice_tokens, codemap_tokens, char_count]` (see
//!   [`super::Aggregates`] for field semantics, including why `codemap_tokens` here differs from
//!   `code_map_token_count` below).
//! - `combined_display_tokens`: `total_content_tokens + codemap_tokens` (the aggregate one) --
//!   the percentage denominator `fileTokenInfo`/`folderTokenInfo` share.
//! - `total_display_tokens`: `total_content_tokens + code_map_token_count` (the composed one) --
//!   mirrors `PromptEntriesEvaluation.totalDisplayTokens`.
//! - `code_map_content` / `code_map_file_count` / `code_map_token_count`: mirror
//!   `PromptEntriesEvaluation.codeMapContent`/`codeMapFileCount`/`codeMapTokenCount`.
//! - `folder_names` / `folder_token_counts` / `folder_formatted` / `folder_percentage`:
//!   index-aligned, first-encounter order (see [`super::FolderTotals`] -- callers must sort by
//!   `folder_names` before comparing against Swift's `[String: TokenInfo]`).
//! - `component_result_words` (stride [`super::COMPONENT_RESULT_STRIDE`]): `prompt,
//!   duplicate_prompt, instructions, file_tree, git_diff, metadata`, index-aligned with the
//!   request's component rows.

use std::fmt;

use super::components::{ComponentInput, compute_component_breakdown};
use super::contract::{
    COMPONENT_RESULT_STRIDE, COMPONENT_STRIDE, ENTRY_RESULT_STRIDE, ENTRY_STRIDE,
    STRING_RANGE_STRIDE, TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
};
use super::entries::{EntryInput, RenderMode, compute_entries};
use super::estimate::{format_token_count, percentage};

// ---- wire types ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TokenAccountingRequestV1 {
    pub contract_version: u16,
    pub utf8_blob: Vec<u8>,
    pub string_range_words: Vec<u64>,
    pub entry_words: Vec<u64>,
    pub component_words: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TokenAccountingError {
    InvalidRequest(String),
    Cancelled,
}

impl fmt::Display for TokenAccountingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(value) => {
                write!(formatter, "invalid token-accounting request: {value}")
            }
            Self::Cancelled => formatter.write_str("token-accounting compute cancelled"),
        }
    }
}
impl std::error::Error for TokenAccountingError {}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TokenAccountingResponseV1 {
    pub entry_result_words: Vec<u64>,
    pub entry_formatted: Vec<String>,
    pub entry_percentage: Vec<f64>,
    pub aggregate_words: Vec<u64>,
    pub combined_display_tokens: u64,
    pub total_display_tokens: u64,
    pub code_map_content: String,
    pub code_map_file_count: u64,
    pub code_map_token_count: u64,
    pub folder_names: Vec<String>,
    pub folder_token_counts: Vec<u64>,
    pub folder_formatted: Vec<String>,
    pub folder_percentage: Vec<f64>,
    pub component_result_words: Vec<u64>,
}

// ---- encode (request-builder helpers; used by Rust unit tests and mirrored by the Swift codec) -

impl TokenAccountingRequestV1 {
    /// Pools `text` verbatim (no dedup -- see `pathmatch::indexes`'s `push_string` doc for the
    /// same convention). Never fails; wire-level UTF-8/NUL validation happens at decode time.
    pub fn push_string(&mut self, text: &str) -> u64 {
        let start = self.utf8_blob.len() as u64;
        self.utf8_blob.extend_from_slice(text.as_bytes());
        let end = self.utf8_blob.len() as u64;
        let index = (self.string_range_words.len() / STRING_RANGE_STRIDE) as u64;
        self.string_range_words.push(start);
        self.string_range_words.push(end);
        index
    }

    /// Appends a content (non-codemap) entry row. Returns the assigned entry ordinal.
    #[allow(clippy::too_many_arguments)]
    pub fn push_content_entry(
        &mut self,
        available_codemap_token_count: u64,
        slice: Option<(&str, u64)>,
        loaded_content: Option<(&str, u64)>,
        cached_full_token_count: Option<u64>,
        relative_path: &str,
    ) -> u64 {
        self.push_entry_row(
            false,
            None,
            available_codemap_token_count,
            slice,
            loaded_content,
            cached_full_token_count,
            relative_path,
        )
    }

    /// Appends a codemap-requested entry row (`codemap_content = Some(text)` for resolved,
    /// `None` for unresolved). Returns the assigned entry ordinal.
    #[allow(clippy::too_many_arguments)]
    pub fn push_codemap_entry(
        &mut self,
        codemap_content: Option<&str>,
        available_codemap_token_count: u64,
        loaded_content: Option<(&str, u64)>,
        cached_full_token_count: Option<u64>,
        relative_path: &str,
    ) -> u64 {
        self.push_entry_row(
            true,
            codemap_content,
            available_codemap_token_count,
            None,
            loaded_content,
            cached_full_token_count,
            relative_path,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn push_entry_row(
        &mut self,
        is_codemap_requested: bool,
        codemap_content: Option<&str>,
        available_codemap_token_count: u64,
        slice: Option<(&str, u64)>,
        loaded_content: Option<(&str, u64)>,
        cached_full_token_count: Option<u64>,
        relative_path: &str,
    ) -> u64 {
        let ordinal = (self.entry_words.len() / ENTRY_STRIDE) as u64;
        let codemap_content_present = u64::from(codemap_content.is_some());
        let codemap_content_idx = self.push_string(codemap_content.unwrap_or(""));
        let resolved_as_slice = u64::from(slice.is_some());
        let (slice_text, slice_chars) = slice.unwrap_or(("", 0));
        let slice_combined_text_idx = self.push_string(slice_text);
        let loaded_content_present = u64::from(loaded_content.is_some());
        let (loaded_text, loaded_chars) = loaded_content.unwrap_or(("", 0));
        let loaded_content_idx = self.push_string(loaded_text);
        let cached_full_token_count_present = u64::from(cached_full_token_count.is_some());
        let relative_path_idx = self.push_string(relative_path);
        self.entry_words.extend([
            u64::from(is_codemap_requested),
            codemap_content_present,
            codemap_content_idx,
            available_codemap_token_count,
            resolved_as_slice,
            slice_combined_text_idx,
            slice_chars,
            loaded_content_present,
            loaded_content_idx,
            loaded_chars,
            cached_full_token_count_present,
            cached_full_token_count.unwrap_or(0),
            relative_path_idx,
        ]);
        ordinal
    }

    /// Appends a component-breakdown request row. Returns the assigned row ordinal.
    pub fn push_component(
        &mut self,
        prompt_text: &str,
        instructions_text: &str,
        file_tree_text: &str,
        git_diff_text: &str,
        metadata_text: &str,
        duplicate_user_instructions_at_top: bool,
    ) -> u64 {
        let ordinal = (self.component_words.len() / COMPONENT_STRIDE) as u64;
        let prompt_idx = self.push_string(prompt_text);
        let instructions_idx = self.push_string(instructions_text);
        let file_tree_idx = self.push_string(file_tree_text);
        let git_diff_idx = self.push_string(git_diff_text);
        let metadata_idx = self.push_string(metadata_text);
        self.component_words.extend([
            prompt_idx,
            instructions_idx,
            file_tree_idx,
            git_diff_idx,
            metadata_idx,
            u64::from(duplicate_user_instructions_at_top),
        ]);
        ordinal
    }
}

// ---- decode + fail-closed validation -------------------------------------------------------

fn usize_word(value: u64) -> Result<usize, TokenAccountingError> {
    usize::try_from(value).map_err(|_| {
        TokenAccountingError::InvalidRequest("compact word exceeds platform index".into())
    })
}

fn decode_flag(value: u64, field: &str) -> Result<bool, TokenAccountingError> {
    match value {
        0 => Ok(false),
        1 => Ok(true),
        other => Err(TokenAccountingError::InvalidRequest(format!(
            "{field} must be 0 or 1, got {other}"
        ))),
    }
}

fn decode_text(
    request: &TokenAccountingRequestV1,
    index: u64,
) -> Result<&str, TokenAccountingError> {
    let row = usize_word(index)?;
    let base = row
        .checked_mul(STRING_RANGE_STRIDE)
        .ok_or_else(|| TokenAccountingError::InvalidRequest("string pool index overflow".into()))?;
    let range = request
        .string_range_words
        .get(base..base + STRING_RANGE_STRIDE)
        .ok_or_else(|| {
            TokenAccountingError::InvalidRequest("string pool index out of range".into())
        })?;
    let start = usize_word(range[0])?;
    let end = usize_word(range[1])?;
    if end < start || end > request.utf8_blob.len() {
        return Err(TokenAccountingError::InvalidRequest(
            "string range out of bounds".into(),
        ));
    }
    let text = std::str::from_utf8(&request.utf8_blob[start..end]).map_err(|_| {
        TokenAccountingError::InvalidRequest("string range is not valid UTF-8".into())
    })?;
    if text.as_bytes().contains(&0) {
        return Err(TokenAccountingError::InvalidRequest(
            "string contains an embedded NUL byte".into(),
        ));
    }
    Ok(text)
}

fn require_empty_when_absent(
    present: bool,
    text: &str,
    numeric: u64,
    field: &str,
) -> Result<(), TokenAccountingError> {
    if !present && (!text.is_empty() || numeric != 0) {
        return Err(TokenAccountingError::InvalidRequest(format!(
            "{field} must carry an empty pooled string and a zero companion word when its \
             presence flag is 0"
        )));
    }
    Ok(())
}

pub(crate) struct DecodedRequest<'a> {
    pub entries: Vec<EntryInput<'a>>,
    pub components: Vec<ComponentInput<'a>>,
}

pub(crate) fn decode(
    request: &TokenAccountingRequestV1,
) -> Result<DecodedRequest<'_>, TokenAccountingError> {
    if request.contract_version != TOKEN_ACCOUNTING_CONTRACT_VERSION_V1 {
        return Err(TokenAccountingError::InvalidRequest(format!(
            "unknown contract version {}",
            request.contract_version
        )));
    }
    if request.string_range_words.len() % STRING_RANGE_STRIDE != 0 {
        return Err(TokenAccountingError::InvalidRequest(
            "string_range_words length is not a multiple of STRING_RANGE_STRIDE".into(),
        ));
    }
    if request.entry_words.len() % ENTRY_STRIDE != 0 {
        return Err(TokenAccountingError::InvalidRequest(
            "entry_words length is not a multiple of ENTRY_STRIDE".into(),
        ));
    }
    if request.component_words.len() % COMPONENT_STRIDE != 0 {
        return Err(TokenAccountingError::InvalidRequest(
            "component_words length is not a multiple of COMPONENT_STRIDE".into(),
        ));
    }

    let mut entries = Vec::with_capacity(request.entry_words.len() / ENTRY_STRIDE);
    for row in request.entry_words.chunks_exact(ENTRY_STRIDE) {
        let is_codemap_requested = decode_flag(row[0], "is_codemap_requested")?;
        let codemap_content_present = decode_flag(row[1], "codemap_content_present")?;
        let codemap_content = decode_text(request, row[2])?;
        let available_codemap_token_count = row[3];
        let resolved_as_slice = decode_flag(row[4], "resolved_as_slice")?;
        let slice_combined_text = decode_text(request, row[5])?;
        let slice_total_characters = row[6];
        let loaded_content_present = decode_flag(row[7], "loaded_content_present")?;
        let loaded_content = decode_text(request, row[8])?;
        let loaded_content_char_count = row[9];
        let cached_full_token_count_present =
            decode_flag(row[10], "cached_full_token_count_present")?;
        let cached_full_token_count = row[11];
        let relative_path = decode_text(request, row[12])?;

        require_empty_when_absent(
            codemap_content_present,
            codemap_content,
            0,
            "codemap_content",
        )?;
        require_empty_when_absent(
            resolved_as_slice,
            slice_combined_text,
            slice_total_characters,
            "slice_combined_text/slice_total_characters",
        )?;
        require_empty_when_absent(
            loaded_content_present,
            loaded_content,
            loaded_content_char_count,
            "loaded_content/loaded_content_char_count",
        )?;
        if !cached_full_token_count_present && cached_full_token_count != 0 {
            return Err(TokenAccountingError::InvalidRequest(
                "cached_full_token_count must be 0 when cached_full_token_count_present is 0"
                    .into(),
            ));
        }

        entries.push(EntryInput {
            is_codemap_requested,
            codemap_content_present,
            codemap_content,
            available_codemap_token_count,
            resolved_as_slice,
            slice_combined_text,
            slice_total_characters,
            loaded_content_present,
            loaded_content,
            loaded_content_char_count,
            cached_full_token_count_present,
            cached_full_token_count,
            relative_path,
        });
    }

    let mut components = Vec::with_capacity(request.component_words.len() / COMPONENT_STRIDE);
    for row in request.component_words.chunks_exact(COMPONENT_STRIDE) {
        let prompt_text = decode_text(request, row[0])?;
        let selected_instructions_text = decode_text(request, row[1])?;
        let file_tree_text = decode_text(request, row[2])?;
        let git_diff_text = decode_text(request, row[3])?;
        let metadata_text = decode_text(request, row[4])?;
        let duplicate_user_instructions_at_top =
            decode_flag(row[5], "duplicate_user_instructions_at_top")?;
        components.push(ComponentInput {
            prompt_text,
            selected_instructions_text,
            file_tree_text,
            git_diff_text,
            metadata_text,
            duplicate_user_instructions_at_top,
        });
    }

    Ok(DecodedRequest {
        entries,
        components,
    })
}

// ---- service --------------------------------------------------------------------------------

/// Batch entry mirroring the differential test's one-call-per-snapshot shape: decode once, run
/// [`super::compute_entries`] over every entry and [`super::compute_component_breakdown`] over
/// every component row. See the module doc for why this is NOT the eventual production shape.
#[derive(Default)]
pub struct TokenAccountingService;

impl TokenAccountingService {
    pub fn compute(
        &self,
        request: &TokenAccountingRequestV1,
    ) -> Result<TokenAccountingResponseV1, TokenAccountingError> {
        self.compute_with_cancellation(request, None)
    }

    pub fn compute_with_cancellation(
        &self,
        request: &TokenAccountingRequestV1,
        cancellation: Option<&crate::LeafCancellation>,
    ) -> Result<TokenAccountingResponseV1, TokenAccountingError> {
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(TokenAccountingError::Cancelled);
        }
        let decoded = decode(request)?;
        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(TokenAccountingError::Cancelled);
        }

        let (entry_results, aggregates, composed, folders) = compute_entries(&decoded.entries);
        let combined_display_tokens = aggregates.total_content_tokens + aggregates.codemap_tokens;
        let total_display_tokens = aggregates.total_content_tokens + composed.token_count;

        let mut response = TokenAccountingResponseV1 {
            aggregate_words: vec![
                aggregates.total_content_tokens,
                aggregates.full_count,
                aggregates.slice_count,
                aggregates.codemap_count,
                aggregates.full_tokens,
                aggregates.slice_tokens,
                aggregates.codemap_tokens,
                aggregates.char_count,
            ],
            combined_display_tokens,
            total_display_tokens,
            code_map_content: composed.content,
            code_map_file_count: composed.file_count,
            code_map_token_count: composed.token_count,
            folder_names: folders.names,
            folder_token_counts: folders.tokens.clone(),
            folder_formatted: folders
                .tokens
                .iter()
                .map(|&tokens| format_token_count(tokens))
                .collect(),
            folder_percentage: folders
                .tokens
                .iter()
                .map(|&tokens| percentage(tokens, combined_display_tokens))
                .collect(),
            ..Default::default()
        };

        response
            .entry_result_words
            .reserve(entry_results.len() * ENTRY_RESULT_STRIDE);
        response.entry_formatted.reserve(entry_results.len());
        response.entry_percentage.reserve(entry_results.len());
        for (entry_index, result) in entry_results.iter().enumerate() {
            if entry_index % 256 == 0
                && cancellation.is_some_and(crate::LeafCancellation::is_cancelled)
            {
                return Err(TokenAccountingError::Cancelled);
            }
            let render_mode = match result.render_mode {
                RenderMode::Full => 0u64,
                RenderMode::Slice => 1,
                RenderMode::Codemap => 2,
                RenderMode::CodemapUnresolved => 3,
            };
            response.entry_result_words.extend([
                render_mode,
                result.display_tokens,
                result.full_tokens,
                result.codemap_tokens,
                u64::from(result.display_line_count.is_some()),
                result.display_line_count.unwrap_or(0),
                result.char_count_contribution,
            ]);
            response
                .entry_formatted
                .push(format_token_count(result.display_tokens));
            response
                .entry_percentage
                .push(percentage(result.display_tokens, combined_display_tokens));
        }

        for (component_index, component) in decoded.components.iter().enumerate() {
            if component_index % 256 == 0
                && cancellation.is_some_and(crate::LeafCancellation::is_cancelled)
            {
                return Err(TokenAccountingError::Cancelled);
            }
            let breakdown = compute_component_breakdown(component);
            response.component_result_words.extend([
                breakdown.prompt,
                breakdown.duplicate_prompt,
                breakdown.instructions,
                breakdown.file_tree,
                breakdown.git_diff,
                breakdown.metadata,
            ]);
        }

        if cancellation.is_some_and(crate::LeafCancellation::is_cancelled) {
            return Err(TokenAccountingError::Cancelled);
        }
        debug_assert_eq!(
            response.entry_result_words.len(),
            decoded.entries.len() * ENTRY_RESULT_STRIDE
        );
        debug_assert_eq!(
            response.component_result_words.len(),
            decoded.components.len() * COMPONENT_RESULT_STRIDE
        );
        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_one_full_entry_one_component_row() {
        let mut request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        request.push_content_entry(0, None, Some(("hello world", 11)), None, "src/a.swift");
        request.push_component("prompt text", "", "", "", "", false);

        let response = TokenAccountingService.compute(&request).expect("compute");
        assert_eq!(response.entry_result_words.len(), ENTRY_RESULT_STRIDE);
        assert_eq!(response.entry_result_words[0], 0, "render_mode full");
        assert_eq!(
            response.component_result_words.len(),
            COMPONENT_RESULT_STRIDE
        );
        assert!(response.component_result_words[0] > 0, "prompt tokens");
        assert_eq!(response.folder_names, vec!["src".to_owned()]);
    }

    #[test]
    fn empty_request_normalizes_to_empty_response() {
        let request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        let response = TokenAccountingService.compute(&request).expect("compute");
        assert_eq!(
            response,
            TokenAccountingResponseV1 {
                aggregate_words: vec![0; 8],
                ..Default::default()
            }
        );
    }

    #[test]
    fn unknown_contract_version_is_rejected() {
        let request = TokenAccountingRequestV1 {
            contract_version: 2,
            ..Default::default()
        };
        assert_eq!(
            TokenAccountingService.compute(&request),
            Err(TokenAccountingError::InvalidRequest(
                "unknown contract version 2".into()
            ))
        );
    }

    #[test]
    fn out_of_range_flag_word_is_rejected() {
        let mut request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        let empty = request.push_string("");
        request
            .entry_words
            .extend([2u64, 0, empty, 0, 0, empty, 0, 0, empty, 0, 0, 0, empty]);
        assert_eq!(
            TokenAccountingService.compute(&request),
            Err(TokenAccountingError::InvalidRequest(
                "is_codemap_requested must be 0 or 1, got 2".into()
            ))
        );
    }

    #[test]
    fn nonempty_payload_with_absent_flag_is_rejected() {
        let mut request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        let empty = request.push_string("");
        let dirty = request.push_string("not empty");
        request
            .entry_words
            .extend([0u64, 0, empty, 0, 0, dirty, 0, 0, empty, 0, 0, 0, empty]);
        assert_eq!(
            TokenAccountingService.compute(&request),
            Err(TokenAccountingError::InvalidRequest(
                "slice_combined_text/slice_total_characters must carry an empty pooled string \
                 and a zero companion word when its presence flag is 0"
                    .into()
            ))
        );
    }

    #[test]
    fn embedded_nul_byte_is_rejected() {
        let mut request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        request.push_content_entry(0, None, None, None, "a\0b.swift");
        assert_eq!(
            TokenAccountingService.compute(&request),
            Err(TokenAccountingError::InvalidRequest(
                "string contains an embedded NUL byte".into()
            ))
        );
    }

    #[test]
    fn pre_cancelled_leaf_short_circuits_before_decode() {
        let request = TokenAccountingRequestV1 {
            contract_version: TOKEN_ACCOUNTING_CONTRACT_VERSION_V1,
            ..Default::default()
        };
        let identity = crate::RuntimeIdentity::fresh(&"a".repeat(64), &"b".repeat(64)).unwrap();
        let cancellation = crate::LeafCancellation::new(identity);
        cancellation.cancel();
        assert_eq!(
            TokenAccountingService.compute_with_cancellation(&request, Some(&cancellation)),
            Err(TokenAccountingError::Cancelled)
        );
    }
}
