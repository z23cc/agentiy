# Rust Apply Edits Compact Contract v1

Status: draft for P2-3 implementation and differential validation.

## Purpose and authority boundary

This contract carries pure `apply_edits` preview computation through Agentry core. Swift remains authoritative for MCP payload normalization into domain modes, workspace/scope/path resolution, approval, file reads, create/overwrite policy, stale-write protection, persistence, selection, and UI orchestration. Rust receives already-read UTF-8 text plus normalized operations and owns literal/escape fallback, exact/high-precision/fuzzy matching, ambiguity, `replace_all`, indentation correction, semantic edits/chunks, output reconstruction, and presentation diff generation.

The core never reads or writes a path. `pathLabel` is opaque computation input used only for diff headers and file-extension-sensitive indentation behavior. A core failure must not silently fall back to Swift and must not expose an approvable partial preview.

## Version and request

```text
CoreApplyEditsBatchRequestV1
  contractVersion: u16 (= 1)
  subjects: [CoreApplyEditsSubjectRequestV1]

CoreApplyEditsSubjectRequestV1
  pathLabel: string
  originalUTF8: bytes
  mode: rewrite | single | batch
  rewriteReplacement?: string
  operations: [CoreApplyEditsOperationV1]
  verbose: bool
  includeToolCardUnifiedDiff: bool

CoreApplyEditsOperationV1
  search: string
  replace: string
  replaceAll: bool
```

- All bytes and text fields must be valid UTF-8.
- `OnMissing`, file existence, and overwrite permission are not wire fields.
- Operation order is preserved.
- Escape fallback, matching, and replacement content are not preprocessed by Swift.
- `searchStartLine` is not a wire field. The current public Swift request and operation models do not carry it. It is an internal, zero-based lower bound derived by the batch cursor per normalized search block: single edit starts at zero; a successful batch match advances that search block's cursor to at least `firstChunk.startLine + rawSearchLineCount`; `replaceAll` advances its local scan to the previous global match end.
- Empty batch maps to the existing invalid-params meaning `edits array cannot be empty`.
- Single and batch operations reject a `search` that is empty or contains only whitespace/newlines with invalid params; an empty selector is never interpreted as a match.
- Each subject's rolling and final updated UTF-8 text is limited to 64 MiB. The engine checks the prospective size before every literal replacement and matcher patch application; exceeding the limit returns invalid params with `result size limit exceeded` and never truncates output.
- Diff generation is independently bounded: original and updated inputs are each limited to 64 MiB and 100,000 byte-preserving lines; the retained Myers trace is limited to 64 MiB; semantic chunk line content and estimated unified-diff rendering are each limited to 64 MiB. Exceeding any diff bound returns invalid params with `diff too large` and produces no partial preview. Updated text remains the apply result authority, while byte edits and unfiltered chunks remain required reconstruction outputs; unified-diff text is rendered only when `verbose` or `includeToolCardUnifiedDiff` requests it.

## Required algorithm order

### Rewrite

Rewrite produces the requested replacement directly and bypasses escape and selector matching. It still emits validated semantic byte edits/chunks and optional presentation text.

### Single edit

1. Search raw literal text first.
2. Only when raw search misses, search is non-empty, and contains a backslash, apply the current C-style escape decoder.
3. Decode replacement text only when the decoded search actually matches the original.
4. A unique literal match replaces directly.
5. Multiple literal matches with `replaceAll == false` are ambiguous and rejected.
6. `replaceAll == true` with no literal match preserves the current no-literal-match error.
7. Other misses proceed through the high-precision matcher.

### Batch

1. Resolve every escape fallback relative to the original text, not an intermediate edit result.
2. Attempt the complete literal fast path in request order against rolling text.
3. If any operation is missing, ambiguous, or otherwise ineligible, discard all fast-path intermediate state and run the whole batch through the diff matcher.
4. Preserve the current repeated-search-block ambiguity exemption.
5. Outcome indices always refer to original request order; a batch can succeed, partially succeed, or fail.

### Matcher and indentation invariants

- Preserve strict and loose line keys, the high-precision line index, the reachable fast/fuzzy selector, and the 400 candidate-key fuzzy budget. The current Swift `findBestMatchUsingNGrams` throws immediately when the fast matcher returns no candidate, so its later n-gram block is unreachable and is not an additional fallback in v1.
- Only candidates after `minimumMatchIndex` consume that budget.
- Preserve the 1-2, 3-5, and 6+ line selector gates.
- Reject ambiguity for non-`replaceAll` operations.
- `replaceAll` finds left-to-right non-overlapping matches in original-file global coordinates from `searchStartLine`; accumulated application offsets do not change match authority.
- Preserve leading escaped-tab promotion, indentation style detection, and indentation correction before final diff application.
- Fuzzy thresholds are frozen from the reachable Swift fast matcher: 6+ lines use `0.90`; 3-5 lines use `0.855`; 1-2 lines use `0.25`, `0.35`, `0.50`, `0.65`, `0.70`, or `0.80` when the shortest strict key length is respectively `<=4`, `5...7`, `8...12`, `13...20`, `21...40`, or `>40` UTF-8-decoded characters. Dice scoring itself uses ASCII-lowercased UTF-8 byte bigram multisets, not Unicode-scalar sets.
- Stable user-facing mappings are: single matcher miss `search block not found in file`; single literal `replaceAll` miss `search text not found in file (no literal matches for replace_all)`; single encoded `replaceAll` miss `search block not found in file (no matches for replace_all)`; batch misses and ambiguity remain per-operation localized errors and do not stop later operations. Literal ambiguity and matcher ambiguity retain their existing distinct Swift strings.

## Batch-wide compact result

```text
CoreCompactApplyEditsBatchResultV1
  subjectSummaries
  utf8Blob
  stringRangeWords       // stride 2
  byteEditWords          // stride 4
  chunkWords             // stride 8
  diffLineWords          // stride 2
  outcomeWords           // stride 3
```

All words are unsigned 64-bit integers. `u64::MAX` is the only optional-value sentinel and is never a valid offset, count, or index.

| Table | Words in row |
|---|---|
| `stringRangeWords` | `startByte, endByte` |
| `byteEditWords` | `oldStartByte, oldEndByte, newStartByte, newEndByte` |
| `chunkWords` | `startLine, oldStartByte, oldEndByte, newStartByte, newEndByte, lineStart, lineCount, flags` |
| `diffLineWords` | `lineType, stringIndex` |
| `outcomeWords` | `operationIndex, statusTag, errorStringIndex?` |

Numeric v1 tags are frozen as follows. These are new wire choices; Swift did not previously assign numeric raw values.

| Domain | Tags |
|---|---|
| mode | `rewrite = 0`, `single = 1`, `batch = 2` |
| result status | `success = 0`, `partial = 1`, `failed = 2` |
| operation outcome | `success = 0`, `failed = 1` |
| line type | `context = 0`, `addition = 1`, `removal = 2` |
| chunk flags | `0` only in v1; every nonzero value is reserved and rejected |

Each subject summary contains `inputByteCount`; `blobStart/blobCount`; `stringStart/stringCount`; `updatedTextStringIndex`; start/count pairs for byte edits, chunks, diff lines, and outcomes; edits requested/applied; result status; an outcomes-present bit (distinguishing `nil` from an empty array); a stats-present bit plus `linesChanged/statsChunkCount`; and optional note/verbose unified diff/tool-card diff string indices. Blob and string ranges are required so the Bridge can prove subject-local string ownership while exhausting batch-wide cursors.

`fileCreated` and `fileOverwritten` are not returned. Swift adds those values after a successful host mutation.

## Encoder and semantic invariants

1. Old byte ranges are monotonic, non-overlapping, bounded by original bytes, and on UTF-8 scalar boundaries.
2. New byte ranges are monotonic, bounded by updated bytes, and on UTF-8 scalar boundaries.
3. Applying new slices to the corresponding old ranges reconstructs updated bytes exactly.
4. Chunks refer only to this subject's byte ranges and diff-line pool. Chunk order is request/application order and must not be sorted: same-start chunks and accumulated line deltas make order observable.
5. Outcome indices are contiguous from zero through `editsRequested - 1` when outcomes are present.
6. `editsApplied` equals successful operation count; summary status and outcome statuses agree.
7. Single/rewrite preserve the existing `nil` outcomes behavior.
8. Subject ranges are contiguous batch-wide; subjects never reference another subject's strings or rows.
9. Checked arithmetic and checked integer conversion are mandatory; overflow is an internal error.

## Bridge single-pass validation and Swift materialization

Before constructing any Swift `ApplyEditsResult`, the Bridge validates the complete batch once:

1. Summary count and subject order match the request.
2. Table lengths are divisible by their strides.
3. Every subject start equals the monotonic expected cursor and all final cursors exhaust every table/blob exactly.
4. String ranges are bounded, ordered, valid UTF-8, and subject-local.
5. Updated text decodes as UTF-8.
6. Byte edits satisfy all original/new monotonicity and boundary rules.
7. Independent byte-edit reconstruction equals updated bytes exactly.
8. Chunk ranges, diff-line ranges, line types, flags, and optional sentinels are valid.
9. Materialized existing `[DiffChunk]` passed through `DiffChunkTextApplier` reproduces updated UTF-8 bytes exactly; this Swift applier becomes a defensive validator, not the production computer.
10. Outcome indices/counts/status agree with the summary and existing Swift result semantics.
11. Any malformed value rejects the whole batch; no preview reaches approval or host write.

Validated fields map to existing `ApplyEditsResult`, `DiffChunk`, diff-line, stats, note, and operation-outcome DTOs using the tag and error mappings above. Presentation diff grouping/text may knowingly drift; updated bytes, semantic regions, status, counts, ambiguity/match set, escape behavior, line statistics, and operation outcomes must remain exact.

Compact `chunkWords`/`diffLineWords` carry the unfiltered semantic chunks used for reconstruction. Presentation stats and unified diff may use the existing whitespace-only filter. This separation is required because current Swift filters an adjacent removal/addition pair when their whitespace-stripped content is equal; such filtered chunks cannot reconstruct a whitespace-only updated text. The authoritative byte-edit table and the unfiltered semantic chunk table must both reconstruct exactly.

## Error and mutation semantics

- Invalid version, mode, UTF-8, or edit shape maps to domain invalid params.
- Match misses, ambiguity, and request-level failures preserve current invalid-params or per-operation outcome semantics.
- Diff/apply/reconstruction invariant failure is an internal core error.
- Malformed compact output, runtime, or transport failure maps to Swift internal error and cannot fall back to Swift computation.
- Cancellation returns no preview and performs no mutation.
- Swift must approve and write the same validated preview. Existing-file writes continue through `writeTextIfUnchanged`; creates remain non-overwriting. A post-preview stale write is not retried as a forced overwrite.

## Cargo-first measurement policy

P2 uses pure Rust contract, regression, property, and measurement harnesses as the default fast loop. Arm64 release measurement uses one warmup plus five samples with fixed workload order and recorded OS/CPU/Rust/commit metadata. Core compute, compact encoding, and Bridge validation/materialization are separate intervals; file I/O, workspace lookup, approval, and persistence are outside core timing. Swift codegen/integration gates are batched after the DTO stabilizes.

Required parity is 100% for updated UTF-8 bytes and correctness semantics. Target warm p95 is no worse than `1.10x` frozen Swift baseline, maximum request no worse than `1.25x`, peak RSS no worse than `1.15x`, and cancellable Rust loops exit within 100 ms. Increasing sample count is the only permitted response to machine noise; correctness and difficult fixtures are not relaxed.

## P2-3 evidence and remaining integration work

- The isolated staging crate ports recovery/routing fixtures for escape fallback, literal ambiguity, fuzzy budget, selector gates, reused full-file replace-all indexes, positive/negative line deltas, tab promotion, CRLF, Unicode, batch partial outcomes, Myers chunks, malformed tables, and independent byte/chunk reconstruction.
- Single/rewrite outcomes are `nil`. Diff-path batch outcomes are present regardless of verbosity. Literal-fast-path batch outcomes are present only when verbose, preserving current Swift behavior. When present, outcome indices are contiguous and success count equals `editsApplied`.
- Presentation-only differential fixtures must be individually named before integration; wildcard drift allowlists remain forbidden.
- P2-4 must add the generated FFI DTOs, Bridge single-pass validator/materializer, codegen drift check, and source-layout documentation registration if the guard requires it.


## Step 12 batch differential: parity matrix and step-13 verdict

Evidence: `Tests/RepoPromptTests/MCP/ApplyEdits/ApplyEditsRustSwiftDifferentialTests.swift` runs the
legacy Swift `ApplyEditsEngine.default` and the production Rust seam `RustApplyEditsComputer` (real
`AgentryCoreBridge` runtime, no mocking) over 16 fixtures spanning rewrite/single/batch,
replace-all, escape-fallback, ambiguity, partial success, literal fast-path, indentation
conversion, CRLF, Unicode, and two fuzzy near-misses (multi-line and single-line). Both engines'
`apply(request:to:options:)` share the identical `ApplyEditsComputing` protocol, so this is a direct
differential, not an approximation. Both success and thrown-error paths are captured as
`Result<ApplyEditsResult, Error>` on both sides so single-mode's `throw`-on-unmatched/ambiguous
behavior (vs batch-mode's `.failed` status with `outcomes`) is not silently skipped by a
happy-path-only comparison.

**12/16 fixtures: exact match** on every strict field (`updatedText`, `status`,
`editsRequested`/`editsApplied`, `note`, `outcomes[].index/status/error`, `stats.linesChanged`,
`stats` nil-vs-non-nil, error classification `invalidParams`/`internalError`): `rewrite_basic`,
`single_basic`, `single_escaped_search_fallback`, `single_replace_all`, `batch_literal_fastpath`,
`batch_unmatched_failed`, `batch_diff_success`, `batch_diff_partial_ambiguity`,
`batch_replace_all_multi`, `crlf_line_endings`, `unicode_content`, `fuzzy_near_miss_single_line`.

**Allowed drift is recorded per fixture, not blanket-excluded.** `diffChunks` shape (count,
`startLine`, addition/removal/context type sequence) and `stats.chunks` are documented allowed
drift (plan §3.10), but the differential still *measures and names* every instance rather than
skipping the comparison outright -- satisfying "每个漂移必须进入具名 fixture allowlist，记录
Swift/Rust 输出" instead of a wildcard exclusion. Two of the three drifting fixtures are genuinely
harmless; the third is a symptom of a real defect, not independent drift -- see below.

**Certified harmless** (chunk-shape/grouping differs, but `updatedText` and `stats.linesChanged` are
identical -- the plan's required "automatic proof"):

| Fixture | Field | Swift | Rust |
| --- | --- | --- | --- |
| `batch_diff_success` | `stats.chunks` | `2` | `1` |
| `batch_diff_success` | `diffChunks.count` | `2` | `1` |
| `crlf_line_endings` | `diffChunks[0].startLine` | `0` | `1` |
| `crlf_line_endings` | `diffChunks[0]` line-type sequence | `[context, removal, addition]` | `[removal, addition]` |

**Not independent drift -- a symptom of the indentation defect below** (this fixture's `updatedText`
already fails strict comparison, so the "automatic proof" does not apply; different indentation
almost certainly produces different chunk boundaries/context as a downstream effect of the same
root cause, not a separately-harmless difference):

| Fixture | Field | Swift | Rust |
| --- | --- | --- | --- |
| `indentation_tabs_file_spaces_edit` | `diffChunks[0].startLine` | `0` | `1` |
| `indentation_tabs_file_spaces_edit` | `diffChunks[0]` line-type sequence | `[context, removal, addition]` | `[removal, addition]` |

### Mismatches (4/16 fixtures)

| Fixture | Field | Swift | Rust | Disposition | Notes |
| --- | --- | --- | --- | --- | --- |
| `single_unmatched_throws`, `single_ambiguous_throws`, `fuzzy_near_miss_missing_semicolon` | `invalidParams` message text (classification matches on all three) | `"search block not found in file"` / `"Search text matches multiple locations (lines 1, 2)...."` | `"invalid compute request"` (identical generic text on all three) | **rust-defect (FFI contract gap), one root cause** | `CoreTransportError.applyEditsInvalidParams` (`Sources/AgentryCoreBridge/CoreBridge.swift:1072`) is a message-less generated FFI error case -- the Rust core's specific diagnostic never crosses the FFI boundary for the single-edit throw path, unlike batch-mode's `outcomes[].error`, which *is* transmitted and matched exactly on `batch_unmatched_failed`/`batch_diff_partial_ambiguity`. Fixing this needs a UniFFI/FFI contract change (add a message payload to the generated error case) plus Rust-side wiring to populate it -- an engineer task with a defined target, not a maintainer spec call. Plan §3.10 lists "ambiguity/replace-all 匹配集合" as strict, and losing the matched-line-number detail is a real information-loss regression for the calling agent, not cosmetic wording. |
| `indentation_tabs_file_spaces_edit` | `updatedText` (+ its two chunk-shape drift rows above, as a symptom) | `"func f() {\n\tlet a = 10\n\tlet b = 2\n}\n"` | `"func f() {\n    let a = 10\n\tlet b = 2\n}\n"` | **rust-defect (feature port needed)** | Not ambiguous: Swift's `ApplyEditsEngine` deliberately detects the file's dominant indentation style (`String.detectIndentationTypeFromLines`, tabs here from `\tlet b = 2`) and re-encodes the replacement text (`encodeIndentationWithConversion`) to match it before applying. `RustApplyEditsComputer` applies the replacement text verbatim, leaving mixed tab/space indentation. This changes `updatedText` bytes, explicitly strict per plan §3.10 -- it is a missing feature in the Rust engine with a clear target (port the Swift indentation-detection/re-encode pipeline), not a design question. Not fixed this pass: it is a real pipeline port, not a contained bug. |

### Coverage gaps in this fixture set (neither pass nor fail evidence)

- **`internalError` classification is unexercised.** Plan §3.10 lists `invalidParams`/`internalError`
  classification as strict, but no fixture in this set naturally reaches `ApplyEditsError.internalError`
  through the default engine/computer (the one Swift-side trigger, an empty-chunk-generator injection
  in `ApplyEditsCoreRecoveryTests`, is a test-only seam, not a normally reachable request shape). This
  is a coverage gap in this pass's fixture set, not evidence of parity either way.
- **Fuzzy-probe path engagement is inferred, not directly observed.** `fuzzy_near_miss_single_line`
  (search `"computeSum(value)"` against source containing `"computeSum(values)"`, no exact literal
  match) produced an identical `updatedText` on both engines, and by elimination neither side threw
  (a throw would have surfaced as a message mismatch or a success/failure asymmetry). That is solid
  evidence the two engines agree on this near-miss shape. Whether both sides actually routed through
  `DiffGenerationUtility`'s bi-gram Dice fuzzy probe specifically (rather than some other path) was
  not directly confirmed: that code path's diagnostic `print("🔍 Fuzzy probe ...")` statements are
  gated behind `enableDetailedLogging`, which this run did not enable, so their absence from the test
  log is inconclusive rather than negative evidence. Broader fuzzy-threshold-boundary coverage (near
  the 0.90 Dice cutoff, multi-candidate ties) also remains unexercised.

### Step 13 verdict: **NO-GO**

Step 13 (delete the legacy Swift apply-edits algorithm) is **not** cleared by this pass:

1. Single-mode thrown-error messages lose the ambiguity/not-found diagnostic detail across the FFI
   boundary (all three `invalidParams`-message mismatches share this one root cause: a message-less
   generated error case). This is explicitly a strict field per plan §3.10 ("ambiguity/replace-all
   匹配集合"), and it needs an FFI contract change, not a query/mapping tweak.
2. Indentation-style auto-conversion (`updatedText` bytes, strict) is not reproduced by the Rust
   engine -- a real, well-defined feature gap, not presentation-only drift, and it also produces the
   chunk-shape drift on that same fixture as a downstream symptom.

Fuzzy near-miss parity is evidenced as matching for the one shape directly tested (`updatedText`
identical); the specific code path taken to get there was not independently confirmed, and
threshold-boundary coverage remains open -- neither is a blocker on its own, but both are listed so
a future pass does not read "12/16 pass" as broader fuzzy coverage than what was actually measured.

**No wildcard allowlist was used or is proposed.** All 4 named mismatches, and all 6 named
allowed-drift instances (both engines' output recorded for each, and the 2 that are symptomatic of
the indentation defect are labeled as such rather than folded into the "harmless" bucket), are
individually dispositioned above per the plan's "每个漂移必须进入具名 fixture allowlist...不得使用
通配 allowlist" requirement. `ApplyEditsRustSwiftDifferentialTests` remains red by design.
