//! Pure port of `TokenCalculationService.calculateEntryTokens` /
//! `TokenCalculationService.evaluatePromptEntries`'s `codeMapComposed` computation.
//!
//! # Scope note: slice assembly is precompute-and-carry, not re-derived
//!
//! The Swift source builds a per-entry `FileViewModel.SliceAssembly` (`combinedText` +
//! `totalCharacters`) from `entry.ranges` + `entry.loadedContent` via
//! `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceAssembly.swift`'s
//! `SliceAssemblyBuilder.build` -- a file outside this port's source-of-truth list, and whose
//! `totalCharacters` is `combinedText.count` (grapheme-cluster count, Unicode-text-segmentation
//! dependent; see `super`'s module doc). This module does not build slice assemblies: callers
//! (the wire decoder, ultimately the Swift differential harness driving the REAL
//! `FileViewModel.buildSliceAssembly`) supply `EntryInput::resolved_as_slice` (mirroring
//! `sliceAssemblies[entry.fileID] != nil` -- note this is `entry.ranges` non-nil-and-non-empty
//! **AND** `entry.loadedContent != nil`; a ranges-bearing entry with no loaded content still
//! resolves to the full-mode branch, exactly as in `buildSliceAssemblies`), plus the already
//! -materialized `slice_combined_text` and precomputed `slice_total_characters`.
//!
//! # Ordinal wire, not UUID-keyed
//!
//! The Swift source keys `entryResultsByFileID` by `UUID`, so a snapshot with duplicate
//! `fileID`s collapses (last-bucket-processed wins, with the unresolved-codemap loop's
//! `if entryResultsByFileID[entry.fileID] != nil { continue }` guard as the one place that
//! explicitly special-cases it). `EntryInput` carries no identity field: each input row IS its
//! ordinal position, so there is no duplicate-identity concept here and every row produces
//! exactly one `EntryResult`, index-aligned with the input. This is intentional -- a
//! `PromptFileEntrySnapshot` list in real production callers is built from one entry per unique
//! file id, so duplicate-id collapsing is a defensive-only Swift-side edge case that has no
//! meaningful analog on this wire. Differential tests must not synthesize duplicate-identity
//! snapshots when comparing against this port.

use super::estimate::{count_lines, estimate_tokens, extract_folder_path};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenderMode {
    /// `PromptEntriesEvaluation.RenderMode.full`.
    Full,
    /// `PromptEntriesEvaluation.RenderMode.slice`.
    Slice,
    /// `PromptEntriesEvaluation.RenderMode.codemap`, resolved (`codeMapContent != nil`).
    Codemap,
    /// `PromptEntriesEvaluation.RenderMode.codemap`, unresolved (`codeMapContent == nil`).
    CodemapUnresolved,
}

/// One `PromptFileEntrySnapshot`-equivalent row. See the module doc for the ordinal (no
/// `fileID`) and precompute-and-carry (no `ranges`) simplifications versus the Swift type.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EntryInput<'a> {
    /// Mirrors `entry.isCodemapRequested`.
    pub is_codemap_requested: bool,
    /// Mirrors `entry.codeMapContent != nil`.
    pub codemap_content_present: bool,
    /// Mirrors `entry.codeMapContent` (meaningless/must be `""` when not present).
    pub codemap_content: &'a str,
    /// Mirrors `entry.availableCodeMapTokenCount`.
    pub available_codemap_token_count: u64,
    /// Mirrors `sliceAssemblies[entry.fileID] != nil` -- see the module doc.
    pub resolved_as_slice: bool,
    /// Mirrors `assembly.combinedText` (meaningless/must be `""` when `resolved_as_slice` is
    /// `false`).
    pub slice_combined_text: &'a str,
    /// Precomputed `assembly.totalCharacters` (`combinedText.count`, grapheme clusters; meaningless
    /// /must be `0` when `resolved_as_slice` is `false`).
    pub slice_total_characters: u64,
    /// Mirrors `entry.loadedContent != nil`.
    pub loaded_content_present: bool,
    /// Mirrors `entry.loadedContent` (meaningless/must be `""` when not present).
    pub loaded_content: &'a str,
    /// Precomputed `entry.loadedContent!.count` (grapheme clusters; meaningless/must be `0` when
    /// `loaded_content_present` is `false`).
    pub loaded_content_char_count: u64,
    /// Mirrors `entry.cachedFullTokenCount != nil`.
    pub cached_full_token_count_present: bool,
    /// Mirrors `entry.cachedFullTokenCount` (meaningless/must be `0` when not present).
    pub cached_full_token_count: u64,
    /// Mirrors `entry.relativePath` (used only for `extractFolderPath`).
    pub relative_path: &'a str,
}

/// One `PromptEntriesEvaluation.EntryResult`-equivalent row, minus the pass-through
/// `fileID`/`renderedDisplayPath` fields (no computation touches them).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EntryResult {
    pub render_mode: RenderMode,
    pub display_tokens: u64,
    pub full_tokens: u64,
    pub codemap_tokens: u64,
    pub display_line_count: Option<u64>,
    /// Only meaningful for `Full`/`Slice` modes; `Codemap`/`CodemapUnresolved` rows carry `0`
    /// here and are excluded from `Aggregates::char_count`, mirroring the Swift source (which
    /// never computes a `charCountContribution` for codemap-branch entries at all).
    pub char_count_contribution: u64,
}

/// Mirrors `AggregatedEntryTokens`, minus `entryResultsByFileID`/`fileTokenInfo`/
/// `folderTokenInfo` (callers derive `TokenInfo` from `EntryResult`/`FolderTotals` plus
/// `estimate::format_token_count`/`estimate::percentage`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Aggregates {
    pub total_content_tokens: u64,
    pub full_count: u64,
    pub slice_count: u64,
    /// `codemapCount` -- the sum of the resolved AND unresolved codemap buckets.
    pub codemap_count: u64,
    pub full_tokens: u64,
    pub slice_tokens: u64,
    /// The per-file-loop aggregate `codemapTokens` accumulated over EVERY resolved-codemap-bucket
    /// entry (including ones whose `codemap_content` is `""`). This is the denominator
    /// `fileTokenInfo`/`folderTokenInfo` percentages use (`combinedDisplayTokens =
    /// totalContentTokens + codemapTokens`) -- NOT the same number as `CodeMapComposed
    /// ::token_count` below, which excludes empty-content entries. See the module doc for why
    /// these two "codemap total" numbers are allowed to diverge.
    pub codemap_tokens: u64,
    pub char_count: u64,
}

/// Mirrors `evaluatePromptEntries`'s inline `codeMapComposed` tuple: the joined codemap snippet
/// text plus file/token counts, computed ONLY over resolved-codemap-bucket entries with
/// non-empty `codemap_content` (`guard let content = entry.codeMapContent, !content.isEmpty else
/// { continue }`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CodeMapComposed {
    pub content: String,
    pub file_count: u64,
    pub token_count: u64,
}

/// Mirrors the `folderTokenAccum: [String: Int]` dictionary as parallel, first-encounter-ordered
/// arrays (a `HashMap` has no defined iteration order; callers must sort by `names` before
/// comparing against Swift's dictionary-derived `folderTokenInfo`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FolderTotals {
    pub names: Vec<String>,
    pub tokens: Vec<u64>,
}

fn accumulate_folder(
    relative_path: &str,
    tokens: u64,
    folder_index: &mut HashMap<String, usize>,
    totals: &mut FolderTotals,
) {
    let folder = extract_folder_path(relative_path);
    if let Some(&index) = folder_index.get(&folder) {
        totals.tokens[index] += tokens;
    } else {
        let index = totals.names.len();
        folder_index.insert(folder.clone(), index);
        totals.names.push(folder);
        totals.tokens.push(tokens);
    }
}

/// Resolves one entry's `full_tokens` fallback chain: `cachedFullTokenCount ??
/// loadedContent.map(estimateTokens) ?? 0`. Shared by the slice, resolved-codemap, and
/// unresolved-codemap branches (each uses this exact chain in the Swift source).
fn full_tokens_fallback(entry: &EntryInput<'_>) -> u64 {
    if entry.cached_full_token_count_present {
        entry.cached_full_token_count
    } else if entry.loaded_content_present {
        estimate_tokens(entry.loaded_content)
    } else {
        0
    }
}

/// Mirrors `TokenCalculationService.calculateEntryTokens` plus `evaluatePromptEntries`'s
/// `codeMapComposed` computation. Returns `(entry_results, aggregates, code_map_composed,
/// folder_totals)`; `entry_results` is index-aligned with `entries`.
#[must_use]
pub fn compute_entries(
    entries: &[EntryInput<'_>],
) -> (Vec<EntryResult>, Aggregates, CodeMapComposed, FolderTotals) {
    let mut results: Vec<Option<EntryResult>> = vec![None; entries.len()];
    let mut aggregates = Aggregates::default();
    let mut folder_index: HashMap<String, usize> = HashMap::new();
    let mut folder_totals = FolderTotals::default();

    // Pass 1: content entries (`!isCodemapRequested`), in original order.
    for (index, entry) in entries.iter().enumerate() {
        if entry.is_codemap_requested {
            continue;
        }

        let result = if entry.resolved_as_slice {
            let display_tokens = estimate_tokens(entry.slice_combined_text);
            let full_tokens = if entry.cached_full_token_count_present {
                entry.cached_full_token_count
            } else if entry.loaded_content_present {
                estimate_tokens(entry.loaded_content)
            } else {
                display_tokens
            };
            aggregates.slice_count += 1;
            aggregates.slice_tokens += display_tokens;
            EntryResult {
                render_mode: RenderMode::Slice,
                display_tokens,
                full_tokens,
                codemap_tokens: entry.available_codemap_token_count,
                display_line_count: Some(count_lines(entry.slice_combined_text)),
                char_count_contribution: entry.slice_total_characters,
            }
        } else {
            let estimated_tokens = entry
                .loaded_content_present
                .then(|| estimate_tokens(entry.loaded_content));
            let resolved_tokens = if entry.cached_full_token_count_present {
                entry.cached_full_token_count
            } else {
                estimated_tokens.unwrap_or(0)
            };
            let char_count_contribution = if entry.loaded_content_present {
                entry.loaded_content_char_count
            } else if resolved_tokens > 0 {
                (resolved_tokens as f64 * 4.0) as u64
            } else {
                0
            };
            aggregates.full_count += 1;
            aggregates.full_tokens += resolved_tokens;
            EntryResult {
                render_mode: RenderMode::Full,
                display_tokens: resolved_tokens,
                full_tokens: resolved_tokens,
                codemap_tokens: entry.available_codemap_token_count,
                display_line_count: entry
                    .loaded_content_present
                    .then(|| count_lines(entry.loaded_content)),
                char_count_contribution,
            }
        };

        aggregates.char_count += result.char_count_contribution;
        accumulate_folder(
            entry.relative_path,
            result.display_tokens,
            &mut folder_index,
            &mut folder_totals,
        );
        results[index] = Some(result);
    }

    // Pass 2: resolved codemap entries (`isCodemapRequested && codeMapContent != nil`), in
    // original order.
    let mut snippets: Vec<&str> = Vec::new();
    let mut code_map_composed = CodeMapComposed::default();
    for (index, entry) in entries.iter().enumerate() {
        if !(entry.is_codemap_requested && entry.codemap_content_present) {
            continue;
        }

        let api_tokens = entry.available_codemap_token_count;
        aggregates.codemap_count += 1;
        aggregates.codemap_tokens += api_tokens;
        accumulate_folder(entry.relative_path, api_tokens, &mut folder_index, &mut folder_totals);
        results[index] = Some(EntryResult {
            render_mode: RenderMode::Codemap,
            display_tokens: api_tokens,
            full_tokens: full_tokens_fallback(entry),
            codemap_tokens: api_tokens,
            display_line_count: Some(count_lines(entry.codemap_content)),
            char_count_contribution: 0,
        });

        if !entry.codemap_content.is_empty() {
            snippets.push(entry.codemap_content);
            code_map_composed.file_count += 1;
            code_map_composed.token_count += api_tokens;
        }
    }
    code_map_composed.content = snippets.join("\n");

    // Pass 3: unresolved codemap entries (`isCodemapRequested && codeMapContent == nil`), in
    // original order.
    for (index, entry) in entries.iter().enumerate() {
        if !(entry.is_codemap_requested && !entry.codemap_content_present) {
            continue;
        }

        aggregates.codemap_count += 1;
        results[index] = Some(EntryResult {
            render_mode: RenderMode::CodemapUnresolved,
            display_tokens: 0,
            full_tokens: full_tokens_fallback(entry),
            codemap_tokens: 0,
            display_line_count: None,
            char_count_contribution: 0,
        });
    }

    aggregates.total_content_tokens = aggregates.full_tokens + aggregates.slice_tokens;

    let entry_results = results
        .into_iter()
        .enumerate()
        .map(|(index, result)| {
            result.unwrap_or_else(|| {
                panic!(
                    "entry {index} classified into none of the three mutually exclusive buckets \
                     (is_codemap_requested/codemap_content_present partition every row)"
                )
            })
        })
        .collect();

    (entry_results, aggregates, code_map_composed, folder_totals)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_entry<'a>(loaded_content: &'a str, relative_path: &'a str) -> EntryInput<'a> {
        EntryInput {
            loaded_content_present: true,
            loaded_content,
            loaded_content_char_count: loaded_content.chars().count() as u64,
            relative_path,
            ..Default::default()
        }
    }

    #[test]
    fn full_mode_entry_without_cache_uses_estimate_for_display_and_full() {
        let entries = [full_entry("hello world", "src/a.swift")];
        let (results, aggregates, _, folders) = compute_entries(&entries);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].render_mode, RenderMode::Full);
        let expected = estimate_tokens("hello world");
        assert_eq!(results[0].display_tokens, expected);
        assert_eq!(results[0].full_tokens, expected);
        assert_eq!(results[0].char_count_contribution, 11);
        assert_eq!(aggregates.full_count, 1);
        assert_eq!(aggregates.full_tokens, expected);
        assert_eq!(folders.names, vec!["src".to_owned()]);
        assert_eq!(folders.tokens, vec![expected]);
    }

    #[test]
    fn full_mode_entry_with_cache_prefers_cache_over_estimate() {
        let mut entry = full_entry("hello world", "a.swift");
        entry.cached_full_token_count_present = true;
        entry.cached_full_token_count = 999;
        let (results, aggregates, _, _) = compute_entries(&[entry]);
        assert_eq!(results[0].display_tokens, 999);
        assert_eq!(results[0].full_tokens, 999);
        assert_eq!(aggregates.full_tokens, 999);
    }

    #[test]
    fn full_mode_entry_without_loaded_content_falls_back_to_byte_multiplied_char_count() {
        let mut entry = EntryInput { relative_path: "a.swift", ..Default::default() };
        entry.cached_full_token_count_present = true;
        entry.cached_full_token_count = 10;
        let (results, _, _, _) = compute_entries(&[entry]);
        assert_eq!(results[0].display_tokens, 10);
        assert_eq!(results[0].char_count_contribution, 40);
        assert_eq!(results[0].display_line_count, None);
    }

    #[test]
    fn full_mode_entry_without_loaded_content_or_cache_or_tokens_has_zero_char_contribution() {
        let entry = EntryInput { relative_path: "a.swift", ..Default::default() };
        let (results, _, _, _) = compute_entries(&[entry]);
        assert_eq!(results[0].display_tokens, 0);
        assert_eq!(results[0].char_count_contribution, 0);
    }

    #[test]
    fn slice_mode_entry_uses_combined_text_for_display_tokens_and_precomputed_char_count() {
        let entry = EntryInput {
            resolved_as_slice: true,
            slice_combined_text: "line one\nline two\n",
            slice_total_characters: 19,
            relative_path: "src/pkg/b.swift",
            ..Default::default()
        };
        let (results, aggregates, _, folders) = compute_entries(&[entry]);
        assert_eq!(results[0].render_mode, RenderMode::Slice);
        let expected = estimate_tokens("line one\nline two\n");
        assert_eq!(results[0].display_tokens, expected);
        assert_eq!(results[0].full_tokens, expected, "no cache/loaded content: full falls back to display");
        assert_eq!(results[0].char_count_contribution, 19);
        assert_eq!(results[0].display_line_count, Some(2));
        assert_eq!(aggregates.slice_count, 1);
        assert_eq!(folders.names, vec!["src/pkg".to_owned()]);
    }

    #[test]
    fn slice_mode_entry_with_loaded_content_uses_it_for_full_tokens_not_display_tokens() {
        let entry = EntryInput {
            resolved_as_slice: true,
            slice_combined_text: "a",
            slice_total_characters: 1,
            loaded_content_present: true,
            loaded_content: "a much longer full file body here",
            loaded_content_char_count: 34,
            relative_path: "a.swift",
            ..Default::default()
        };
        let (results, _, _, _) = compute_entries(&[entry]);
        assert_eq!(results[0].display_tokens, estimate_tokens("a"));
        assert_eq!(results[0].full_tokens, estimate_tokens("a much longer full file body here"));
    }

    #[test]
    fn resolved_codemap_entry_with_empty_content_counts_toward_aggregate_but_not_composed() {
        let entry = EntryInput {
            is_codemap_requested: true,
            codemap_content_present: true,
            codemap_content: "",
            available_codemap_token_count: 42,
            relative_path: "a.swift",
            ..Default::default()
        };
        let (results, aggregates, composed, folders) = compute_entries(&[entry]);
        assert_eq!(results[0].render_mode, RenderMode::Codemap);
        assert_eq!(results[0].display_tokens, 42);
        assert_eq!(results[0].display_line_count, Some(0));
        assert_eq!(aggregates.codemap_count, 1);
        assert_eq!(aggregates.codemap_tokens, 42, "aggregate counts empty-content entries");
        assert_eq!(composed.file_count, 0, "composed excludes empty-content entries");
        assert_eq!(composed.token_count, 0);
        assert_eq!(composed.content, "");
        assert_eq!(folders.tokens, vec![42], "folder rollup counts empty-content entries too");
    }

    #[test]
    fn resolved_codemap_entries_with_content_are_newline_joined_in_order() {
        let entries = [
            EntryInput {
                is_codemap_requested: true,
                codemap_content_present: true,
                codemap_content: "func a() {}",
                available_codemap_token_count: 5,
                relative_path: "a.swift",
                ..Default::default()
            },
            EntryInput {
                is_codemap_requested: true,
                codemap_content_present: true,
                codemap_content: "func b() {}",
                available_codemap_token_count: 7,
                relative_path: "b.swift",
                ..Default::default()
            },
        ];
        let (_, _, composed, _) = compute_entries(&entries);
        assert_eq!(composed.content, "func a() {}\nfunc b() {}");
        assert_eq!(composed.file_count, 2);
        assert_eq!(composed.token_count, 12);
    }

    #[test]
    fn unresolved_codemap_entry_has_zero_display_tokens_and_nil_line_count() {
        let mut entry = EntryInput { is_codemap_requested: true, relative_path: "a.swift", ..Default::default() };
        entry.loaded_content_present = true;
        entry.loaded_content = "cached body";
        entry.loaded_content_char_count = 11;
        let (results, aggregates, composed, folders) = compute_entries(&[entry]);
        assert_eq!(results[0].render_mode, RenderMode::CodemapUnresolved);
        assert_eq!(results[0].display_tokens, 0);
        assert_eq!(results[0].codemap_tokens, 0);
        assert_eq!(results[0].full_tokens, estimate_tokens("cached body"));
        assert_eq!(results[0].display_line_count, None);
        assert_eq!(aggregates.codemap_count, 1);
        assert_eq!(composed.file_count, 0);
        assert!(folders.names.is_empty(), "unresolved entries never touch folder rollups");
    }

    #[test]
    fn empty_entries_produce_zeroed_aggregates() {
        let (results, aggregates, composed, folders) = compute_entries(&[]);
        assert!(results.is_empty());
        assert_eq!(aggregates, Aggregates::default());
        assert_eq!(composed, CodeMapComposed::default());
        assert!(folders.names.is_empty());
    }

    #[test]
    fn folder_rollups_accumulate_across_multiple_entries_in_the_same_folder() {
        let entries = [
            full_entry("aaaa", "src/pkg/a.swift"),
            full_entry("bbbbbbbb", "src/pkg/b.swift"),
            full_entry("c", "src/other/c.swift"),
        ];
        let (_, _, _, folders) = compute_entries(&entries);
        let src_pkg_index = folders.names.iter().position(|n| n == "src/pkg").unwrap();
        let expected = estimate_tokens("aaaa") + estimate_tokens("bbbbbbbb");
        assert_eq!(folders.tokens[src_pkg_index], expected);
    }

    #[test]
    fn mixed_bucket_results_stay_index_aligned_with_input_order() {
        let entries = [
            full_entry("full body", "a.swift"),
            EntryInput {
                is_codemap_requested: true,
                codemap_content_present: true,
                codemap_content: "cm",
                available_codemap_token_count: 3,
                relative_path: "b.swift",
                ..Default::default()
            },
            EntryInput { is_codemap_requested: true, relative_path: "c.swift", ..Default::default() },
        ];
        let (results, _, _, _) = compute_entries(&entries);
        assert_eq!(results[0].render_mode, RenderMode::Full);
        assert_eq!(results[1].render_mode, RenderMode::Codemap);
        assert_eq!(results[2].render_mode, RenderMode::CodemapUnresolved);
    }
}
