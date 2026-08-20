# Rust Search Leaf Contract v1

Status: **P1 contract freeze**. This document freezes behavior before implementation. It does not authorize product cutover by itself.

## Scope and ownership

The target production chain is `RepoPromptApp -> AgentryCoreBridge -> typed UniFFI -> agentry-runtime search leaf`. Rust owns deterministic content matching, UTF-8 line decoding, PCRE2/JIT execution, repair selection, fast-plan equivalence, and deterministic path-clause evaluation. Swift retains file acquisition/freshness, workspace inventory and authority, batch orchestration, result caps, and final snippet/AppKit rendering.

Rust is the sole decoder that converts search subjects into lines. Swift may convert returned UTF-8 byte ranges to `String.Index`, UTF-16, `NSRange`, or AppKit ranges only at the final materialization/rendering boundary.

## Typed leaf API

### Content request

`ContentSearchRequest` contains:

- runtime identity and a request-scoped cancellation handle;
- `pattern`, `subject`, and match mode (`contentFullBuffer` or `contentLine`);
- `caseInsensitive`, `wholeWord`, and `multilineAnchors`;
- `collectMatches` and optional `maxCollectedMatches`;
- non-negative `contextLines`;
- frozen match-limit policy (`fileSearchFullBuffer` or `fileSearchLine`).

`subject` is a valid in-process Swift/Rust string. The API does not accept precomputed Swift line tables or UTF-16 offsets.

### Content result

`ContentSearchResult` contains:

- ordered, unique `ContentLineHit` records;
- `matchingLineCount` independent of whether hit payload collection was capped;
- `cancelled`;
- one privacy-safe diagnostic record.

Each `ContentLineHit` contains a 0-based `lineNumber`, a `lineByteRange`, the first accepted `matchByteRange` for that line, and ordered `contextBeforeByteRanges` / `contextAfterByteRanges`. Every range is relative to the start of the original UTF-8 subject.

### Path request and result

`PathFilterRequest` contains runtime identity, cancellation handle, snapshots in caller order, clauses in caller order, and `caseInsensitive`. Each snapshot contains `standardizedFullPath`, `standardizedRelativePath`, `standardizedRootPath`, and `clientDisplayPath`; Rust does not standardize, discover, authorize, or persist these values.

`PathFilterResult` contains `matchedSnapshotIndices`, `visitedSnapshotCount`, `cancelled`, and a privacy-safe diagnostic. Indices are in snapshot input order and each snapshot occurs at most once. Empty clauses produce no matches; empty snapshots produce zero visited entries.

Folder-suffix matching is a separate stateless request over a fragment and caller-supplied relative paths. It returns input indices only and creates no durable index or workspace authority.

## Coordinates, lines, and context

- Line numbers are 0-based.
- All offsets and ranges are unsigned UTF-8 byte offsets and half-open: `[start, end)`.
- Ranges must be ordered, in bounds, and on UTF-8 scalar boundaries. A malformed result is an internal/transport invariant failure, never a truncated snippet.
- `LF`, lone `CR`, and `CRLF` each terminate a line. `CRLF` is one terminator, never an empty intervening line.
- Terminator bytes are excluded from `lineByteRange` and rendered line text.
- An empty subject has zero lines. A trailing terminator does not synthesize an additional final empty line. Interior consecutive terminators do represent empty lines.
- A zero-length match is assigned by its start byte and iteration must make forward progress. A cross-line match is assigned to the line containing its start byte.
- Multiple occurrences assigned to the same line produce one hit: retain the first accepted match in ascending byte order.
- Hits sort by `lineNumber`, then `matchByteRange.start`; they contain no duplicate line number.
- For requested context `N`, before-ranges are `[max(0, line-N), line)` and after-ranges are `(line, min(lineCount, line+N+1))`, both in document order. Missing sides are empty collections at the leaf boundary; Swift may preserve its existing optional presentation shape.

## Pattern validation and repair

Complexity limits and classifications from `RegexToolkit` are observable behavior: length, capture-group count, high-risk rejection, invalid escapes, brackets, parentheses, quantifiers, and variable-length lookbehind guidance must retain their current user-facing category.

Compilation attempts are deterministic and de-duplicated in this order:

1. original pattern;
2. double-escape compression before recognized regex metacharacters;
3. `RegexToolkit.normalise` equivalent;
4. compression of the normalized pattern.

A candidate identical to an earlier candidate is skipped. `wholeWord` wraps the effective candidate with the current `\b(?:...)\b`-equivalent behavior. The result reports `repairKind` (`none`, `doubleEscapeCompression`, `normalise`, or `normaliseThenCompression`) and whether repair occurred. Failure reports the final stable search error classification; variable-length lookbehind retains its specific fixed/bounded-width guidance.

The higher-level optional no-results literal rescue remains an explicit caller policy and must be modeled/tested separately. It is not an engine-error fallback and cannot silently substitute for a failed Rust call.

## Engine, JIT, limits, and fast-plan fallback

Product code does not read `REPOPROMPT_PCRE2_JIT`. Runtime initialization performs a JIT probe; JIT being unavailable at runtime initialization is fatal to the Rust search service. Every eligible compiled pattern requests JIT. A pattern that PCRE2 cannot JIT may run in the interpreter only with `jitStatus = pcre2InterpreterFallback`; it must be covered by the parity register. There is no Swift/C production fallback.

The frozen PCRE2 policy tiers are:

| Policy | Match limit | Depth limit | Heap limit |
|---|---:|---:|---:|
| `fileSearchFullBuffer` | 10,000,000 | 100,000 | 64 MiB |
| `fileSearchLine` | 1,000,000 | 10,000 | 16 MiB |
| `pathSearchShortSubject` | 100,000 | 1,000 | 4 MiB |

Match, depth, and heap failures remain distinguishable stable error/diagnostic categories. Fast plans are exact optimizations only: ASCII whole-word literal, anchored declaration, ASCII marker, path suffix, and anchored line prefilter. If eligibility or a prefilter cannot prove equivalence, execution falls back to Rust PCRE2 using the same effective pattern, options, limits, cancellation, byte ranges, and error semantics. Fast-plan disagreement is a parity failure, not permission to return a different result.

The compiled-pattern cache remains runtime-owned, bounded to 256 entries and an estimated 16 MiB. Diagnostics distinguish fast plan, JIT PCRE2, interpreter fallback, and cache hit without exposing input data.

## Path-clause semantics

Clauses are ORed in caller order. Root restrictions compare `restrictedRootPath` to `standardizedRootPath` case-sensitively even when `caseInsensitive` is true. Evaluation stops after the first matching clause for a snapshot.

- `exactFile(absPath, relPath, restrictedRootPath?)`: match when full equals `absPath`; otherwise match when relative equals `relPath` and the optional root restriction equals the snapshot root. Exact comparisons are case-sensitive.
- `exactFolder(absLower, relLower, restrictedRootPath?)`: reject a root mismatch first. Lowercase full and relative candidates using current Swift-equivalent lowercasing. Match equality or a descendant prefix at a `/` boundary for either absolute or relative form.
- `glob(pattern, restrictedRootPath?)`: reject a root mismatch first. Preserve the current `repo_wildmatch` search semantics and flags: `WM_WILDSTAR` only when the pattern contains `**`, `WM_CASEFOLD` from `caseInsensitive`, and no implicit `WM_PATHNAME`/`WM_NOESCAPE`. Test, in order, client display path, relative path, then full path.
- `legacyPrefix(candidateLower)`: an empty candidate never matches. Compare lowercase relative, client display, and full forms for equality or descendant prefix at a `/` boundary.
- folder suffix: standardize and trim `/`; reject empty fragments. Apply optional lowercasing. Match a relative path when it equals the candidate or ends with `/<candidate>`, preserving caller input order.

The Rust wildmatch port must reproduce the existing repository implementation rather than selecting a generic glob crate.

## Cancellation and partial results

Each request owns an identity-bound, idempotent cancellation handle. Rust checks cancellation at fixed documented strides: before/after PCRE2 calls and during line, match, and snapshot iteration. This fixed-stride placement is an allowed operational drift only when tests bound maximum cancellation latency.

Content cancellation maps to `CancellationError` at the Swift API and publishes no stale late hits. Path cancellation returns the already completed prefix with `cancelled = true` and an exact `visitedSnapshotCount`; the snapshot whose evaluation began is counted. Partial path results remain ordered and unique. Runtime invalidation, shutdown, stale identity, or poison discards late results and never constructs a legacy fallback.

## Errors and observability

Stable error groups are: invalid pattern (including current syntax subcategories and lookbehind guidance), pattern too complex, match/depth/heap limit exceeded, JIT unavailable, cancelled, runtime invalidated/stopped/poisoned, malformed range/internal invariant, and transport failure. Path/content top-level and per-file error placement remains compatible with `SearchResults`.

A leaf diagnostic may contain only: engine/fast-plan kind, `jitStatus`, cache hit, `repairKind`, selected limit policy, subject byte count, line count, hit/matching-line count, visited snapshot count, cancellation flag/checkpoint class, limit-failure class, and normalized duration/counter fields approved by telemetry policy. It must never contain pattern, subject, path, snippet, filename, workspace identity, or captured text.

## Boundary exclusions

P1 does not migrate or own:

- `RepoPromptWorkspaceCore/StandardizedPath.swift` or `WorkspacePathPolicy.swift`;
- workspace root lookup, aliases, bookmarks, containment/permission/visibility decisions, storage, or authority;
- file inventory, file I/O/freshness, codemap, search orchestration, result batching, or selection;
- codemap regex behavior (its old-target compile blocker is converted locally, not moved into the search leaf);
- UI, transcript, diff, MCP/domain-runtime regexes, AppKit/TextKit ranges, or rendering;
- inventory/codemap/edits/Agent domains, authority/storage migration, XCFramework distribution, signing, notarization, or release.

## Boundary transport decision: typed DTOs, not Protobuf

P1 uses typed UniFFI records/enums. These calls are synchronous, in-process, and guarded by the existing binding checksum/build fingerprint; no persisted or cross-version wire format exists. Protobuf would still copy strings while adding a second schema, code generator, and runtime. The P0 event envelope remains for the event data plane and is not reused for this leaf API. G4 measurement must include the real typed-DTO FFI copying cost.

## Cutover rule

The Rust implementation must pass the parity matrix before production cutover. Runtime or parity errors never trigger automatic Swift/C fallback. After cutover, rollback is source/artifact rollback only.

## 8-business-day beta release gate

The release checklist must reserve a gate beginning with the first beta artifact that contains the unique Rust search implementation and continuing for **8 consecutive business days**. Allowed aggregate observations are search crash/hang, runtime poison, JIT unavailable/interpreter-fallback counts, limit-error rate, and p99 latency/RSS. Pattern, path, content, snippets, and workspace identity must not be uploaded.

Actual release is blocked until the full 8-business-day interval completes and any parity regression, JIT initialization failure, unexplained fallback, or G4 threshold regression is resolved. P1 does not perform or simulate the soak, launch an app, sign/notarize/upload an artifact, or publish a release.
