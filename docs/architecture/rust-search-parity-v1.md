# Rust Search Parity Matrix v1

Status: **P1 parity skeleton**. Populate Rust test/evidence columns during implementation; no unchecked row may cross the production cutover gate.

The pre-cutover Swift/C implementation is the differential oracle. Frozen fixtures and property tests must compare result sets, ordering, 0-based line numbers, UTF-8 byte ranges, context ranges, repair kind, error classification, cancellation metadata, and path visited counts. Fixed seeds are committed with each property corpus; failure output contains the seed and minimized synthetic input, never workspace content.

## Matrix

| ID | Behavior | Swift/C oracle | Planned Rust/Bridge test | Required equality/evidence | Status |
|---|---|---|---|---|---|
| C01 | LF, lone CR, CRLF, consecutive and trailing terminators | `SearchLineIndex` / search tests | `search_lines_line_endings_v1` | line count, byte ranges, text ranges | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C02 | Empty subject, empty line, long line | `SearchMatch` scan paths | `search_lines_boundaries_v1` | hits, counts, no overflow | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C03 | Unicode scalar boundaries and non-ASCII before match | `PCRE2RegexTests.testCompileMatchCapturesAndUTF8ByteRanges` | `regex_utf8_byte_ranges_v1` | exact half-open UTF-8 byte ranges | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C04 | Zero-length and cross-line matches | `PCRE2RegexTests.testEnumerationAdvancesPastZeroLengthUnicodeMatches` plus differential fixture | `regex_zero_length_cross_line_v1` | forward progress and start-line assignment | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C05 | Multiple occurrences on one line | current content scanner | `regex_matching_line_dedup_v1` | one hit per line, first match retained | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C06 | Result and context ordering | `SearchDocument` materialization | `regex_context_ranges_v1` | ascending unique lines; clipped before/after ranges | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C07 | Case-insensitive and whole-word behavior, ASCII and Unicode | adapter/PCRE2 oracle | `regex_case_word_v1` | matches and byte ranges | passing: `testUnicodeLineEndingZeroLengthAndCrossLineParity` Unicode casefold/whole-word differential plus fast-plan ASCII case |
| C08 | Multiline anchors versus path candidate boundaries | content/path compilers | `regex_anchor_modes_v1` | content and path results | passing: `RustSearchDifferentialTests` line/property/fast differential |
| C09 | Original-pattern success | `compileSearchRegexWithRepairsResult` | `regex_repair_original_v1` | effective pattern result, `repairKind=none` | passing: `testRepairAndErrorClassificationParity` |
| C10 | Double-escape compression | adapter and path compiler | `regex_repair_compression_v1` | effective behavior and repair kind | passing: `testRepairAndErrorClassificationParity` |
| C11 | Normalize and normalize-then-compress | `RegexToolkit.normalise` / adapter | `regex_repair_normalise_v1` | attempt order, behavior, repair kind | **blocked:** normalize parity passes; `\\\\{)` proves the old adapter skips normalize-only and reports `normaliseThenCompression`, while the four-stage v1 contract/Rust reports `normalise`; old-bug disposition requires reviewer approval |
| C12 | Invalid escapes/brackets/parentheses/quantifiers | `RegexToolkit` tests/oracle | `regex_syntax_errors_v1` | stable error category | passing: `testRepairAndErrorClassificationParity` |
| C13 | Variable-length lookbehind | `RepoPromptPCRE2Adapter` mapping | `regex_lookbehind_error_v1` | category and fixed/bounded-width guidance | passing: `testRepairAndErrorClassificationParity` |
| C14 | Complexity length/capture/high-risk rejection | `RegexToolkit.validateComplexity` | `regex_complexity_v1` | accept/reject boundary and category | passing: `testRepairAndErrorClassificationParity` |
| C15 | Full-buffer/line/path match, depth, heap limits | adapter policy; `PCRE2RegexTests.testMatchLimitIsReported` | `regex_limits_v1` | exact tier and failure class | partial: match-limit differential passes; Rust `pcre2_contract_inline_match_depth_and_heap_limits_are_accepted` covers exact depth/heap classification; cross-engine policy-tier depth/heap fixture remains pending |
| C16 | JIT-eligible pattern | `PCRE2JITTests` and build probe | `regex_jit_required_v1` | JIT active and same matches | passing: `testBasicContentParityMatchesLinesByteRangesAndContext` JIT assertion |
| C17 | Pattern-specific interpreter fallback | PCRE2 oracle fixture | `regex_jit_pattern_fallback_v1` | same matches plus registered fallback diagnostic | passing: `testRegisteredInterpreterFallbackParity` registers `\\C`, compares matches/ranges, and asserts `pcre2InterpreterFallback` |
| C18 | ASCII whole-word fast plan | `PCRE2SearchFastPlansTests` | `fast_plan_ascii_word_v1` | fast plan equals forced PCRE2 | passing: `testFastPlansEqualLegacyAndForcedGeneralPCRE2` |
| C19 | Anchored declaration fast plan | Swift fast plan + forced PCRE2 | `fast_plan_declaration_v1` | matches/ranges/errors equal | passing: `testFastPlansEqualLegacyAndForcedGeneralPCRE2` |
| C20 | ASCII marker fast plan | Swift fast plan + forced PCRE2 | `fast_plan_marker_v1` | matches/ranges/errors equal | passing: `testFastPlansEqualLegacyAndForcedGeneralPCRE2` |
| C21 | Anchored line prefilter | Swift fast plan + forced PCRE2 | `fast_plan_line_prefilter_v1` | matches/ranges/errors equal | passing: `testFastPlansEqualLegacyAndForcedGeneralPCRE2` |
| C22 | Path suffix fast plan | Swift fast plan + forced PCRE2 | `fast_plan_path_suffix_v1` | matches/ranges/errors equal | passing: `testFastPlansEqualLegacyAndForcedGeneralPCRE2` |
| P01 | Empty clauses/snapshots | `SearchPathFiltering` | `path_empty_v1` | indices, visited, cancelled | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P02 | Exact file absolute/relative/root restriction | `filterPathIndicesResult` | `path_exact_file_v1` | case-sensitive match and root semantics | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P03 | Exact folder equality/descendant boundary | `filterPathIndicesResult` | `path_exact_folder_v1` | lowercase and `/` boundary behavior | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P04 | Glob display/relative/full order and flags | `repo_wildmatch` search call | `path_glob_v1` | full corpus including `**`, slash, casefold | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P05 | Legacy prefix equality/descendant boundary | `filterPathIndicesResult` | `path_legacy_prefix_v1` | empty/lowercase/boundary behavior | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P06 | Clause OR, input order, per-snapshot dedup | `filterPathIndicesResult` | `path_order_dedup_v1` | exact index sequence | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| P07 | Folder suffix normalization and resolution | suffix-index helpers | `path_folder_suffix_v1` | exact returned input indices | passing: `testPathClausesGlobFolderSuffixAndCancellationParity` |
| X01 | Content cancellation | current task-group/scanner behavior | `content_cancel_v1` + latency bound | no stale results; Swift `CancellationError` | partial: deterministic pre-start differential in `testCollectionLimitsAndCancellationParity` and Bridge no-late-result coverage pass; running-operation latency bound remains pending |
| X02 | Path cancellation | `filterPathIndicesResult` | `path_cancel_v1` + latency bound | ordered partial prefix and exact visited count | partial: deterministic pre-start differential and Rust exact zero-prefix visited count pass; running-operation latency bound remains pending |
| X03 | Runtime identity/shutdown/poison | P0 Bridge tests | `core_search_lifecycle_v1` | fail closed; no late result/fallback | passing: `AgentryCoreServiceTests` + `CoreSearchTests` |
| X04 | Cache hit/miss | current `NSCache` behavior | `regex_cache_v1` | result equality and bounded cache | passing: Rust `regex_cache_v1`; differential result corpus |
| X05 | Count-only and collection cap | current content aggregation | `search_count_collection_cap_v1` | total matching-line count independent of payload cap | passing: `testCollectionLimitsAndCancellationParity` |
| X06 | Deterministic randomized differential corpus | committed Swift/C exporter | fixed-seed Rust property suite | byte-for-byte canonical result/error record | passing: `testFixedSeedSyntheticPropertyCorpusParity` seed `0x5eedcafe` |

## Differential corpus and seeds

The corpus must include synthetic ASCII/Unicode subjects, all three line endings, empty/interior/trailing empty lines, long lines, zero-length and cross-line patterns, capture groups, fixed and variable lookbehind, each repair candidate, each limit tier, JIT-eligible and registered interpreter-only patterns, every fast-plan eligibility boundary, and every path clause/root restriction combination.

Seed records use a stable ID, generator version, numeric seed, minimized input digest, and expected canonical-output digest. They contain no absolute developer path, username, timestamp, UUID, prompt, token, or real workspace text. Rust unit tests consume the canonical corpus; Swift/Bridge differential tests consume the same fixtures until cutover. Release builds never execute both engines.

## Allowed known operational drift

Exactly two known drifts are permitted:

1. **Remove the production `REPOPROMPT_PCRE2_JIT` switch.** The Rust product path always probes JIT and requests it for eligible patterns. Pattern-specific interpreter fallback remains diagnostic and test-registered; runtime JIT unavailability blocks initialization.
2. **Use fixed-stride Rust cancellation checkpoints.** Checkpoint placement may differ from Swift, but tests must establish a bounded maximum delay while preserving result order, uniqueness, partial-path visited count, and no stale content publication.

These are operational-policy differences only. Matching sets, line numbers, UTF-8 byte ranges, ordering, context, repair outcome, error classification, and limit behavior cannot be waived as known drift.

## Observed blockers

- `C11`: focused reproducer `\\\\{)` reaches the old adapter's combined normalize/compress attempt and reports `normaliseThenCompression`; the Rust implementation follows the documented four-candidate order and succeeds earlier with `normalise`. Treating the old skipped attempt as a bug is consistent with the v1 contract, but the required reviewer-approved old-bug entry does not yet exist, so production cutover remains blocked.
- `C15`, `X01`, and `X02`: the named partial rows are evidence gaps, not registered behavior drifts. They remain cutover blockers until executable cross-engine depth/heap policy fixtures and running-cancellation latency bounds pass.

## Difference disposition

Every observed difference must take exactly one path before cutover:

1. **Fix Rust** and add/minimize a regression fixture when Swift/C behavior is the contract.
2. **Prove an old implementation bug**, with a focused reproducer, documented rationale, reviewer-approved entry appended to this document, and updated canonical expectation. A claim without proof is not a drift registration.
3. **Block cutover** when neither resolution is complete.

There is no automatic fallback, dual-engine production retry, environment switch, or “best effort” result substitution. Shadow comparison is restricted to tests, benchmarks, or an explicitly DEBUG-only diagnostic and is deleted from the production cutover unit.

## Cutover gate

All matrix rows must name an executable test and carry passing evidence. The known-drift section must still contain only the two operational items above unless a separately reviewed old-bug proof changes the contract. Any unexplained mismatch, unbounded cancellation latency, JIT initialization failure, malformed range, or fallback to Swift/C blocks cutover.
