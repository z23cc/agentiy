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
| C11 | Normalize and normalize-then-compress | `RegexToolkit.normalise` / adapter | `regex_repair_normalise_v1` | attempt order, behavior, repair kind | passing: reviewer/orchestrator-approved old-bug disposition below; `testRepairAndErrorClassificationParity` freezes Rust `normalise`, one line hit, and byte range `[0,4)` for `\\\\{)` against subject `\\{)` |
| C12 | Invalid escapes/brackets/parentheses/quantifiers | `RegexToolkit` tests/oracle | `regex_syntax_errors_v1` | stable error category | passing: `testRepairAndErrorClassificationParity` |
| C13 | Variable-length lookbehind | `RepoPromptPCRE2Adapter` mapping | `regex_lookbehind_error_v1` | category and fixed/bounded-width guidance | passing: `testRepairAndErrorClassificationParity` |
| C14 | Complexity length/capture/high-risk rejection | `RegexToolkit.validateComplexity` | `regex_complexity_v1` | accept/reject boundary and category | passing: `testRepairAndErrorClassificationParity` |
| C15 | Full-buffer/line/path match, depth, heap limits | adapter policy; `PCRE2RegexTests.testMatchLimitIsReported` | `regex_limits_v1` | exact tier and failure class | passing: `testRepairAndErrorClassificationParity` compares match plus interpreter-forced depth/heap failure classes across full-buffer, line, and short-path policy tiers; Rust contract test also covers inline limit acceptance |
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
| X01 | Content cancellation | current task-group/scanner behavior | `content_cancel_v1` + latency bound | no stale results; Swift `CancellationError` | passing: pre-start differential and Bridge no-late-result coverage plus Rust `running_content_cancellation_latency_is_bounded_v1`; direct-line fast plan checks every 64 lines and observes running cancellation within the asserted 2s upper bound |
| X02 | Path cancellation | `filterPathIndicesResult` | `path_cancel_v1` + latency bound | ordered partial prefix and exact visited count | passing: pre-start differential, exact zero-prefix visited count, and Rust `running_path_cancellation_latency_is_bounded_v1`; per-snapshot checkpoint preserves an ordered partial prefix and observes running cancellation within the asserted 2s upper bound |
| X03 | Runtime identity/shutdown/poison | P0 Bridge tests | `core_search_lifecycle_v1` | fail closed; no late result/fallback | passing: `AgentryCoreServiceTests` + `CoreSearchTests` |
| X04 | Cache hit/miss | current `NSCache` behavior | `regex_cache_v1` | result equality and bounded cache | passing: Rust `regex_cache_v1`; differential result corpus |
| X05 | Count-only and collection cap | current content aggregation | `search_count_collection_cap_v1` | total matching-line count independent of payload cap | passing: `testCollectionLimitsAndCancellationParity` |
| X06 | Deterministic randomized differential corpus | committed Swift/C exporter | fixed-seed Rust property suite | byte-for-byte canonical result/error record | passing: `testFixedSeedSyntheticPropertyCorpusParity` seed `0x5eedcafe` |
| X07 | Compact batch transport and materialization | structured logical result view | `compact_batch_*_v1` plus Bridge compact-table tests | subject alignment; sparse/overlapping context arithmetic; collection cap; stride/slice/range/UTF-8 fail-closed; final line/context/matching results unchanged | passing requires Rust `compact_batch_layout_empty_and_sparse_v1`, `compact_batch_layout_overlapping_context_v1`, `compact_batch_collection_cap_v1`, `compact_batch_subject_alignment_v1`; Bridge `testCompactBatchPreservesSubjectAlignmentAndContextArithmetic`, `testCompactBatchRejectsMalformedTableStrides`, `testCompactBatchRejectsOutOfBoundsSubjectSlices`, `testCompactBatchRejectsInvalidUTF8Boundaries`; and all 8 `RustSearchDifferentialTests` |

## Differential corpus and seeds

The corpus must include synthetic ASCII/Unicode subjects, all three line endings, empty/interior/trailing empty lines, long lines, zero-length and cross-line patterns, capture groups, fixed and variable lookbehind, each repair candidate, each limit tier, JIT-eligible and registered interpreter-only patterns, every fast-plan eligibility boundary, and every path clause/root restriction combination.

Seed records use a stable ID, generator version, numeric seed, minimized input digest, and expected canonical-output digest. They contain no absolute developer path, username, timestamp, UUID, prompt, token, or real workspace text. Rust unit tests consume the canonical corpus; Swift/Bridge differential tests consume the same fixtures until cutover. Release builds never execute both engines.

## Allowed known operational drift

Exactly two known drifts are permitted:

1. **Remove the production `REPOPROMPT_PCRE2_JIT` switch.** The Rust product path always probes JIT and requests it for eligible patterns. Pattern-specific interpreter fallback remains diagnostic and test-registered; runtime JIT unavailability blocks initialization.
2. **Use fixed-stride Rust cancellation checkpoints.** Checkpoint placement may differ from Swift, but tests must establish a bounded maximum delay while preserving result order, uniqueness, partial-path visited count, and no stale content publication.

These are operational-policy differences only. Matching sets, line numbers, UTF-8 byte ranges, ordering, context, repair outcome, error classification, and limit behavior cannot be waived as known drift.

## Closed blocker dispositions

- **C11 old implementation bug (reviewer/orchestrator-approved):** focused reproducer `\\\\{)` shows that the old adapter omits the distinct normalize-only compile attempt and therefore reaches the later combined normalize/compress attempt, reporting `normaliseThenCompression`. This contradicts the frozen four-stage contract. Rust is authoritative for this case: it succeeds at stage 3 with `repairKind=normalise`; against subject `\\{)` it returns one line hit with match byte range `[0,4)`. `testRepairAndErrorClassificationParity` freezes that result. This is an old-adapter implementation defect, not a permitted parity drift.
- **C15 evidence closed:** `testRepairAndErrorClassificationParity` uses `\\C` to force both engines onto the interpreter path, avoiding JIT-specific limit competition, and compares depth/heap failure classification for all three frozen policy tiers.
- **X01/X02 evidence closed:** `running_content_cancellation_latency_is_bounded_v1` and `running_path_cancellation_latency_is_bounded_v1` start real operations, cancel after work begins, and assert completion within two seconds. The content direct-line fast plan now checks every 64 lines; path filtering checks each snapshot. Existing differential/Bridge tests retain ordering, visited-count, and no-late-publication evidence.

## Difference disposition

Every observed difference must take exactly one path before cutover:

1. **Fix Rust** and add/minimize a regression fixture when Swift/C behavior is the contract.
2. **Prove an old implementation bug**, with a focused reproducer, documented rationale, reviewer-approved entry appended to this document, and updated canonical expectation. A claim without proof is not a drift registration.
3. **Block cutover** when neither resolution is complete.

There is no automatic fallback, dual-engine production retry, environment switch, or “best effort” result substitution. Shadow comparison is restricted to tests, benchmarks, or an explicitly DEBUG-only diagnostic and is deleted from the production cutover unit.

## Performance fixture tiers

The G4 performance comparison has two explicitly named tiers. `file-tree-batch`, `codemap`, `search-results`, and `transcript` are micro fixtures whose 38–47 µs Swift baseline is dominated by the fixed typed-UniFFI boundary cost. They remain recorded against the unchanged 110% wall/CPU and 125% allocation/memory ratios as informational boundary-tax tracking.

The cutover constraint binds `representative-large-subject` (one realistic source-shaped subject over 100 KB), `representative-multi-file-batch` (64 source-shaped subjects passed through one batch export), and `representative-match-density` (12.5% matching lines). Every representative fixture must satisfy the same unchanged 110%/125% ratios and active-JIT requirement. This tier disposition is the orchestrator decision completing G4's original representative-workload intent; it does not relax a cap or ratio, and micro measurements continue to be published.

## Cutover gate

All matrix rows must name an executable test and carry passing evidence. The known-drift section must still contain only the two operational items above unless a separately reviewed old-bug proof changes the contract. Any unexplained mismatch, unbounded cancellation latency, JIT initialization failure, malformed range, or fallback to Swift/C blocks cutover.
