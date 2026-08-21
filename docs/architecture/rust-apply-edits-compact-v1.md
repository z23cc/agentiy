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
