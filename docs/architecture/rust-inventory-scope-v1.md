# Rust Inventory Scope Contract v1

Status: **P4-1 contract freeze.** This document freezes the shape of the workspace inventory
authority migration (charter Phase 5 slice, tracked as `P4`) before any Rust `InventoryScope`
candidate exists. It authorizes no cutover by itself; P4-2's de-risking experiments gate P4-3a,
and P4-6b's single commit is the only step that deletes the Swift arm. Full narrative rationale,
evidence, and the round-2-reviewed decision record live in
`docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` (**APPROVED**); this document
extracts the frozen, implementation-facing contract per that design's P4-1 step and does not
restate its rationale.

**Anchor commit for every line citation below: `2803d3d9`** (branch `dev`, current at authoring).
The design's own citations are anchored at `a756190d`; P4-1 re-derives every reproducible figure
against the later commit (§Recon below) rather than trusting the earlier anchor to still hold.

## 1. Scope, root, and handle model

One `ScopeRegistry` primitive is added to `agentry-runtime`, holding long-lived, ID-addressed
mutable domain scopes; `InventoryScope` is its first tenant. Per charter §8.3 and iron law 3,
scopes are addressed by typed ID (`InventoryScopeId`), never by a UniFFI `Arc` proxy — Rust
business lifetime is never decided by Swift `deinit`. `CoreRuntime` remains the only root object.

- **One scope per process** (open question 2, still open at the design level; P4-1 does not
  decide multi-workspace granularity). Roots are sub-entities of a scope, matching today's
  single-store topology.
- **Handles are explicit IDs, not proxy objects**, at every layer: `InventoryScopeId`, `RootId`,
  `RootLifetimeId`, `SnapshotHandleId`, `BulkLoadId`. The bridge-owned ARC wrapper
  (`CoreInventorySnapshot`, layer 1 of §4 below) is the only place a Swift `deinit` exists, and it
  is a convenience over an explicit `close()`, never the product lifecycle mechanism.

## 2. `InventoryScope`'s concurrency model and critical-section discipline

The model mirrors what `WorkspaceFileContextStore` already does: mutable identity maps live
behind one lock; immutable per-generation artifacts are ARC/`Arc`-retained and handed to readers
by reference.

| Concern | Mechanism |
|---|---|
| Scope state (identity maps, path indexes, per-root counters, handle table) | One `std::sync::Mutex<InventoryScopeState>` per scope, acquired with the crate's exceptionless poison-recovery idiom |
| Published generations (sorted tables, entries projection, path index) | `Arc<RootGeneration>`, immutable once published; a reader clones the `Arc` under the lock and does all paging/query work outside it |
| Snapshot handles | Handle table mapping `SnapshotHandleId -> Arc<RootGeneration>` plus a generation token |
| Expensive authoritative rebuild (backstop) | Computed outside the lock from an `Arc`-cloned base plus the delta log; the lock is taken only to install the result, and only if the base is still current |

**Critical-section discipline (the testable invariant).** Every critical section is O(1) or
O(log n): a hash lookup, a sorted insert, an `Arc` clone, or a pointer swap. No critical section
performs a full-table sort, a full-root materialization, an index build, or an FFI-visible
allocation of unbounded size. A `debug_assert`-backed instrumentation counter records the longest
observed critical section per scope, surfaced in `InventoryDiagnosticsV1`. P4-3a's cargo gate
enforces this mechanically (a concurrency test asserting a reader is never blocked by an in-flight
authoritative rebuild); P4-1 freezes the shape, not the test.

**Poison handling is a binding constraint, not a style note.** Every state-plane lock acquisition
uses:

```rust
let state = self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
```

`InventoryScope` follows the **recovery** branch, never the typed-error branch: a panic in any one
of the scope's many entry points must not permanently wedge the inventory authority for the life
of the process. `.lock().unwrap()` is forbidden everywhere in the scope.

**Lock census, re-derived at `2803d3d9` (§Recon confirms unchanged from the design's anchor):**
`rust/crates/runtime/src` contains **40** `.lock()` sites — `registry.rs` 10, `subscription.rs`
12, `lifecycle.rs` 10, `wake_pipe.rs` 5, `search/cache.rs` 2, `codemap/engine.rs` 1. **37** use the
closure spelling `.unwrap_or_else(|poisoned| poisoned.into_inner())`; **2** more
(`search/cache.rs:49`, `:71`) use the equivalent function-reference spelling
`.unwrap_or_else(std::sync::PoisonError::into_inner)`; and exactly **one** (`codemap/engine.rs:115`)
deliberately maps poisoning to a typed `CodeMapError::Internal("query cache poisoned")` instead,
because a query cache is trivially rebuildable and its caller has an error channel — a long-lived
authority scope has neither property. **Zero** `.lock().unwrap()` sites exist anywhere in the
crate. `InventoryScope` inherits the 39-exceptionless/1-typed-error convention and adds no third
pattern. P4-3a's grep-based CI gate (its own done-when line, not landed here) enforces this over
`rust/crates/runtime/src` going forward; this document freezes the convention the gate checks.

**Rejected, per the design (§5.2.1):** `RwLock` (no benefit when reads are O(1) under the lock and
heavy work is already outside it); per-root locks (deferred behind P4-2's E-4 measurement, not
assumed); lock-free/optimistic versioning (unjustified complexity for a single-writer workload).

## 3. Wire schema: `inventory-scope-v1`

Retires `inventory-compute-v1` (a stateless whole-table request/response schema whose
non-interning encoder is the measured cause of the 1.2-80x transport tax that blocks P3-2's
cutover). `inventory-scope-v1` is a distinct versioned data-plane schema (charter §10.2) with:

- string interning by value into a UTF-8 blob;
- delta framing as the primary shape; tables only as bulk-load chunks and paged reads;
- fail-closed decode with max decoded size, max collection/string lengths, and unknown-version
  rejection.

Per charter §15.3 item 6, `inventory-scope-v1` ships a Rust codec *and* a hand-written Swift
mirror in `AgentryCoreBridge`, fingerprint-locked the way P2's
`swift_pipeline_fingerprint_mirror_matches_rust_truth` locks the codemap wire: Rust is the
canonical schema source, drift is a red cargo test, never a runtime decode failure. This is a
P4-4 done-when line, frozen here so P4-4 has no design discretion left over the mechanism.

`inventory-compute-v1` and its 17-test differential remain as-is through P4-5 as the standing
parity contract for builder semantics, then retire with the Swift builders at P4-8.

## 4. Generation-lease / handle-lifecycle contract (§7.5's naming requirement)

Four layers map ARC retention onto explicit Rust-side handles:

1. **Bridge-owned ARC wrapper.** The raw `SnapshotHandleId` is never exposed above
   `AgentryCoreBridge`. The bridge vends `final class CoreInventorySnapshot` whose `deinit` calls
   `inventoryCloseSnapshot`; `close()` is idempotent and the product-facing lifecycle mechanism,
   `deinit` is the backstop only.
2. **Rust-side generation cap (`cap = 8`), preserved verbatim.** Exceeding it marks the shard
   dirty, records `.retentionBoundary`, increments `backstopCount`, clears
   `publishedTopologyGeneration`, and **lets the mutation proceed.** A retained generation costs
   memory, never progress — this asymmetry is the property E-3 proves and E-4 measures under
   contention.
3. **Mass invalidation on scope/identity events.** `inventoryCloseRoot` invalidates every handle
   over that root lifetime; `inventoryCloseScope` invalidates every handle in the scope; a
   `RuntimeIdentity` change or panic-poison invalidates all handles process-wide. A read on an
   invalidated handle returns a typed `handleInvalidated(reason:)` business outcome, not an error.
4. **Leak observability (DEBUG).** Each handle records open time and an origin tag;
   `inventoryScopeDiagnostics` reports open handle count, oldest handle age, and an origin
   histogram; a DEBUG-only assertion fires when a handle outlives a threshold.

**Instance-identity contract (the mechanical-port anchor for `WorkspaceCatalogShardTests`).**
`WorkspaceCatalogShardTests` today asserts reference identity as a cache signal
(`indexed.rootPathIndexes[0] === indexedRootA.rootPathIndexes[0]`, `:95`). Post-migration the
equivalent contract is **"same generation ⇒ same `generationToken`"** on the snapshot handle: the
token is an opaque per-generation identity value, and ported tests assert token equality where
they previously asserted `===`. Named here so the test port is mechanical, not improvised.

## 5. FFI surface (control, bulk-load, ingest, read, event planes)

All calls carry `RuntimeIdentity` and are rejected on identity mismatch or poison. All are
synchronous and fast except where noted; none traverse the P0 operation registry (reads must be
direct synchronous exports, matching P1/P2's `searchRegex` / `codeMapExtractBatchCompactV1`
precedent).

```text
// Control plane
CoreRuntime.inventoryOpenScope(InventoryScopeConfig) throws -> InventoryScopeHandleV1
CoreRuntime.inventoryCloseScope(RuntimeIdentity, InventoryScopeId) throws            // idempotent
CoreRuntime.inventoryOpenRoot(InventoryRootOpenV1) throws -> InventoryRootLifetimeV1
CoreRuntime.inventoryCloseRoot(RuntimeIdentity, InventoryScopeId, RootId, RootLifetimeId)
    throws -> InventoryRootUnloadReceiptV1
CoreRuntime.inventoryScopeDiagnostics(RuntimeIdentity, InventoryScopeId)
    throws -> InventoryDiagnosticsV1                 // mirrors RootCatalogShardDebugSnapshot

// Bulk load (chunked; never one blocking megacall)
CoreRuntime.inventoryBeginBulkLoad(RuntimeIdentity, InventoryScopeId, RootId, RootLifetimeId)
    throws -> BulkLoadId
CoreRuntime.inventoryPushBulkChunk(BulkLoadId, bytes) throws -> BulkChunkReceiptV1
CoreRuntime.inventoryCommitBulkLoad(BulkLoadId, InventoryPublishModeV1)
    throws -> InventoryGenerationReceiptV1
CoreRuntime.inventoryAbortBulkLoad(BulkLoadId) throws

// Ingest (the hot path -- synchronous, ordered, in-place)
CoreRuntime.inventoryApplyDeltaV1(InventoryDeltaCommandV1) throws -> InventoryDeltaReceiptV1

// Read plane (handle-based)
CoreRuntime.inventoryOpenSnapshot(InventorySnapshotRequestV1) throws -> InventorySnapshotHandleV1
CoreRuntime.inventorySnapshotPage(SnapshotHandleId, offset, limit, projection)
    throws -> CompactInventoryPageV1
CoreRuntime.inventoryLookupPaths(SnapshotHandleId, [path]) throws -> CompactLookupResultV1
CoreRuntime.inventoryQuery(SnapshotHandleId, CompactQueryV1) throws -> CompactQueryResultV1
CoreRuntime.inventoryExportCompactV1(SnapshotHandleId, range) throws -> bytes   // escape hatch
CoreRuntime.inventoryCloseSnapshot(SnapshotHandleId) throws                     // idempotent

// Codemap/consumer read surface (the promotion of appliedIndexRecordLookup, see §6)
CoreRuntime.inventoryResolveRecords(InventoryResolveRequestV1) throws -> CompactRecordBlockV1
CoreRuntime.inventoryOpenProjectedShard(InventoryProjectedShardRequestV1)
    throws -> InventorySnapshotHandleV1
```

### 5.1 `InventoryDeltaCommandV1` / `InventoryDeltaReceiptV1` and typed rejection reasons

`InventoryDeltaCommandV1` carries `scopeId`, `rootId`, `rootLifetimeId`, `watcherAcceptedWatermark`
(optional), `requiresFullResync`, `source`, and a compact `inventory-scope-v1` delta blob of
path-keyed operations. `InventoryDeltaReceiptV1` returns `appliedIndexGeneration`,
`catalogGeneration`, an `InventoryApplyOutcome` (`patched` / `rebuiltAuthoritative` / `rejected`),
and on rejection a typed `InventoryRejectionReason`:

- `staleWatermark(expected:actual:)`
- `lifetimeMismatch`
- `generationGap(expected:actual:)`
- `unknownRoot`, `scopeClosed`, `identityMismatch`

Rejection is a business outcome, not an error — the same modeling choice already made for
`InventoryShardPatchOutcomeTag::NotPatchable` (`contract.rs:76`).

**`staleWatermark` is new bookkeeping, not a port of an existing steady-state guard** (today's
`lastAppliedWatcherWatermark` check is scoped to the seeded-root replay transition only; the
steady-state path has no watermark comparison at any layer). Three constraints, each verified
against the mailbox rather than assumed, are frozen here:

1. **Non-strict comparison** (`accepted >= lastApplied`). Consecutive publications can legitimately
   carry the same watermark value.
2. **`nil` bypasses the sequence check entirely**, and must never be coerced to zero. Synthetic-
   mutation, edit-path, and seeded-replay publications carry `watcherAcceptedWatermark: nil`.
3. **Pressure collapse must pass.** `collapseQueuedPayloads` preserves `min(lowest)` / `max(high)`
   across a collapsed overflow batch, so the published high watermark is non-decreasing through an
   overflow event, and the collapsed payload carries the root-rescan sentinel mapping to
   `requiresFullResync`. The gate cannot reject an overflow sequence.

P4-2's E-1c replay (a named deliverable of that step, not this one) is the acceptance test: zero
rejections across recorded/synthesized production delta sequences, or the gate ships
observe-only (count, don't reject) until explained.

### 5.2 Bulk-load contract: `BulkLoadId` abort-vs-commit ordering

- `inventoryBeginBulkLoad` opens a staging buffer that is **invisible** to every read/query/lookup
  export until commit; `inventoryPushBulkChunk` appends to that private buffer and bounds
  per-call latency on the Swift actor (chunking, never one blocking megacall).
- `inventoryCommitBulkLoad(BulkLoadId, InventoryPublishModeV1.atomicPublish)` publishes the entire
  staged root in **one critical section** — the 8D atomic root publication invariant that
  `buildPendingCatalogComponents` exists to serve today, preserved verbatim.
- `inventoryAbortBulkLoad(BulkLoadId)` discards the staging buffer; **a `BulkLoadId` is single-use
  across its lifecycle** — once aborted or committed it is terminal, and a subsequent push,
  commit, or abort against the same `BulkLoadId` is rejected rather than silently accepted or
  silently re-opening a new stage. There is no "push after abort" path: an abort tombstones the
  ID the same way `OperationRegistry`'s cancel-before-admission tombstones an operation ID (P0
  precedent, `registry.rs`), so a chunk that was in flight when an abort lands cannot resurrect
  the staging buffer it targeted.

### 5.3 `inventoryResolveRecords` / `inventoryLookupPaths`: facts, not verdicts

**The API returns facts; each call site composes its own predicate.** This is the central
decision the design's §4.3.1.1 forces after auditing all 11 B1 call sites: no single fixed
predicate serves eleven sites that check eleven different things, so the promoted API cannot
enforce a verdict — it must expose the facts a verdict would be built from, atomically, under one
lock acquisition against one generation.

`CompactRecordBlockV1` fact fields, per requested id:

```text
CompactRecordBlockV1
  generation, rootLifetimeId                       // or a whole-block `stale` in place of all facts
  per id: exists, rootId, isDiscoverable, pathRoundTripsToSelf,
          standardizedRelativePath, standardizedFullPath, name,
          recordFingerprint, <projected fields>
```

`inventoryLookupPaths` returns the **identical fact shape**, keyed by path instead of id:

```text
CompactLookupResultV1
  generation, rootLifetimeId                       // or a whole-block `stale`
  per path: exists, fileId?, folderId?, rootId, isDiscoverable,
            standardizedRelativePath, standardizedFullPath, name, recordFingerprint
```

Neither shape includes a boolean "passed" field. `isDiscoverable`, `pathRoundTripsToSelf`, and
`recordFingerprint` are independent facts; a call site that does not check discoverability today
simply does not read `isDiscoverable` tomorrow. This is what makes P4-6a's rewiring
predicate-delta-preserving by construction rather than by review discipline.

`recordFingerprint` exists for exactly one verified reason: a caller holding a **captured** copy of
a record (frozen into a previously-built shard, an event payload, or its own earlier call) must
still be able to ask "is the authority's current record byte-identical to the copy I am holding?"
— the check at `WorkspaceFileContextStore.swift:14592` today, preserved as **D-11** rather than
dropped as a tautology (see §7 below).

### 5.4 The six-site discoverability-gap registry (preserve-verbatim constraint on P4-6a)

Re-deriving all 11 B1 sites' predicates against the reference guard
(`appliedIndexRecordLookup`'s five clauses, `:6700-6725`) found that **discoverability (R4,
`isDiscoverableFileID`) is absent at 6 of 11 sites.** Because the fact API returns facts rather
than a verdict, P4-6a's rewiring **must not** add `isDiscoverable` to any of these six —
doing so would silently start filtering managed-only files out of paths that serve them
intentionally today. This registry is the preserve-verbatim constraint; **P4-6a's gate forbids
closing any of these six.**

| # | Site (function) | What the gap currently permits |
|---|---|---|
| 1 | `revalidateAutomaticCodemapSelection` (`:11777-11804`) | Serves managed-only files on codemap re-selection |
| 2 | `requestCodemapArtifactWithOwnership` (`:12557-12567`) | Serves managed-only files on codemap artifact demand |
| 3 | `codemapManifestCandidate` (`:14850-14859`) | Serves managed-only files on manifest candidacy |
| 4 | `acceptCodemapMarkerReadinessUpdate` (`:14682-14689`) | Serves managed-only files on marker-readiness updates |
| 5 | `readCodemapSource` (`:14887-14923`) | Serves managed-only files on codemap source reads |
| 6 | `codemapDemandIsCurrent` (`:14966-14975`) | Serves managed-only files on demand-currency checks |

Each is filed as its own **post-cutover** adjudication item (whether the gap is a latent bug or
intentional support for explicitly-added, non-directory-discovered files), each with its own
regression test, each decided **after** P4-6b so a semantic product decision never entangles with
the mechanical rewiring:

- **PC-1** (site 1) — adjudicate whether re-selection should exclude managed-only files.
- **PC-2** (site 2) — adjudicate whether artifact demand should exclude managed-only files.
- **PC-3** (site 3) — adjudicate whether manifest candidacy should exclude managed-only files.
- **PC-4** (site 4) — adjudicate whether marker-readiness should exclude managed-only files.
- **PC-5** (site 5) — adjudicate whether source reads should exclude managed-only files.
- **PC-6** (site 6) — adjudicate whether demand-currency should exclude managed-only files.

## 5b. Event catalog (event plane, reused P0 machinery)

Inventory publishes to a subscription scope. Events are notifications, never tables:

| Event | Class | Coalesce key | Payload |
|---|---|---|---|
| `inventoryGenerationAdvanced` | `Coalescible` | `scope:root` | generations + change summary counts |
| `inventoryAppliedIndexBatch` | `Coalescible` | `scope:root` | compact applied-index delta (the `WorkspaceAppliedIndexBatchEvent` equivalent) |
| `inventoryRootPublished` / `inventoryRootUnloaded` | `Lossless` | -- | root id + lifetime id |
| `inventoryShardFallback` | `Droppable` | `scope:root:reason` | diagnostic only |
| `inventoryResnapshotRequired` | `Lossless` | -- | reason (gap, overflow, backstop, identity change) |

Bounded drain, delivery cursors, gap markers, and `resnapshot_required` all come from the existing
P0 implementation unchanged. Consumers that hit a gap discard their projection and re-bootstrap
from a fresh snapshot handle (charter §9.3, already tested at P0).

## 5c. Diagnostics field map (`InventoryDiagnosticsV1` mirrors `RootCatalogShardDebugSnapshot`)

R6 and §7.2 layer 4 both require field-for-field parity so the store's existing diagnostics tests
port rather than get reinvented. `RootCatalogShardDebugSnapshot`
(`WorkspaceFileContextStore.swift:249-261`) and its per-root child
`RootCatalogShardGenerationDebugSnapshot` (`:230-245`) are the fields `InventoryDiagnosticsV1` must
carry:

| Swift field (today) | Scope | `InventoryDiagnosticsV1` carries |
|---|---|---|
| `liveGenerationCapPerRoot` | scope-wide | verbatim (the `cap = 8` constant, §4) |
| `maxPatchLogicalMutationCount` | scope-wide | verbatim (D-1's tunable N, default 1 until E-1 sets it) |
| `publishedShardCount` | scope-wide | verbatim |
| `totalBuildCount` / `totalBackstopCount` | scope-wide | verbatim |
| `singleShardCompositionReuseCount` / `genericMergeElementVisitCount` | scope-wide | verbatim |
| `shadowComparisonCount` / `shadowMismatchCount` / `lastShadowByteCount` | scope-wide | verbatim through P4-5; repurposed to a Rust-internal self-check per D-5 post-cutover, field names kept |
| per-root `rootID` / `lifetimeID` | per-root | verbatim (`RootId` / `RootLifetimeId`) |
| per-root `publishedTopologyGeneration` | per-root | verbatim (nil when the cap backstop has fired, §7.2 layer 2) |
| per-root `liveTopologyGenerations` / `retainedTopologyGenerations` | per-root | verbatim |
| per-root `buildCount` / `patchCount` / `authoritativeRebuildCount` | per-root | verbatim |
| per-root `pathIndexBuildCount` / `overlayPathIndexBuildCount` | per-root | verbatim (now covering the ported index orchestration, §4.4.1) |
| per-root `fallbackCount` / `fallbackReasonCounts` | per-root | verbatim, keyed by the same eight `RootCatalogShardFallbackReason` cases (§7.4 table below) |
| per-root `lastAppliedIndexGeneration` | per-root | verbatim |
| per-root `deltaStateDirty` / `backstopCount` | per-root | verbatim |
| *(new)* longest observed critical section | per-scope | added per §2's instrumentation requirement -- has no Swift-side precedent, since the actor has no critical-section concept |
| *(new)* open handle count / oldest handle age / origin histogram | per-scope | added per §4 layer 4 (DEBUG leak observability) -- has no Swift-side precedent |

**The eight `RootCatalogShardFallbackReason` cases and their P4 fate (design §7.4, reproduced here
because the diagnostics map is meaningless without the enum it counts):**

| Reason | Fate |
|---|---|
| `missingReusableShard` | Preserved -- cold-start / evicted-shard path |
| `generationGap` | Preserved, promoted to `InventoryRejectionReason.generationGap` on the delta receipt |
| `fullResync` | Preserved -- driven by `requiresFullResync` |
| `unsafeOrAmbiguousBatch` | Preserved but expected to become rare (one owner now mutates maps and tables in one critical section, D-4) |
| `retentionBoundary` | Preserved verbatim (§4 layer 2) |
| `patchThresholdExceeded` | Expected to become rare (D-1, `maxRootCatalogShardPatchLogicalMutationCount` 1 -> N) |
| `patchApplicationBackstop` | Preserved -- patch computed but unsafe to apply |
| `shadowValidationMismatch` | Repurposed, not deleted -- Rust-internal self-check post-cutover (D-5) |

## 6. `inventoryOpenProjectedShard` (B2) and `inventoryQuery` (the suggestion-service seam)

**`inventoryOpenProjectedShard`** builds the codemap graph-index catalog shard authority-side: same
discoverability filter, same `WorkspaceInventoryOrdering` comparators, plus a codemap projection
list. The codemap-capable extension->language table (`SyntaxManager.supportsCodeMap`,
`CodeMapSyntaxEngine.extensionToLanguage`) is Swift-owned policy passed **in** at
`inventoryOpenScope` as scope configuration, not resolved implicitly inside Rust. Consumption
stays paged via `inventorySnapshotPage`; no whole-root payload crosses the boundary in either
direction.

**`inventoryQuery` is specified against a real consumer** (`AgentFileTagSuggestionService`), not a
generic filtered page. Two obligations beyond a plain filtered page, both frozen here:

1. **A haystack variant selector.** The service's haystack is
   `[logicalPath, displayPath, name, standardizedRelativePath, standardizedFullPath]` joined,
   which differs from the authority index's `pathSearchIndexKey`. `CompactQueryV1` carries the
   variant so the authority searches the right subject text.
2. **A caller-supplied logical-path prefix, per root**, not per file. Swift computes one display
   prefix per root — via `ClientPathFormatter.displayPath(root:relativePath:visibleRoots:)`'s
   three branches (`WorkspacePathPolicy.swift:329-351`) — and passes it in the query; Rust
   concatenates prefix + relative path, the same simple-concatenation shape
   `WorkspaceSearchCatalogEntry.defaultDisplayPath` uses today
   (`WorkspaceFileContextModels.swift:215-218`). **No path standardization moves to Rust.**

   **Pinned by `Tests/RepoPromptWorkspaceCoreTests/WorkspacePathPolicyTests.swift
   .testInventoryQueryDisplayPrefixCompositionMatchesClientPathFormatterAcrossAllBranchesAndEmptyRelativePath`
   (landed in this step):** all three of `displayPath`'s branches (single visible root -> no
   prefix; multiple roots, unique name -> `name/`; multiple roots, ambiguous name ->
   `standardizedFullPath/`) special-case the **empty relative path** to a bare root identifier
   rather than reducing to `prefix + ""`. The frozen `CompactQueryV1` contract is therefore: Swift
   computes **both** the non-empty-relative prefix and the distinct empty-relative-path override
   value per root; Rust never re-derives branch selection, and never applies the prefix
   unconditionally to an empty relative path.

Because suggestion ranking is user-visible, P4-7 (not P4-1) carries the hard-assertion
result-set-and-order parity differential and the mention-path latency SLO.

## 7. Drift this document pins (mechanical-port anchors, not new decisions)

Recorded here only where P4-1 is the step that must name the mechanical anchor so a later step's
port is not improvised; full drift register and justification remain in the design's §9.

- **D-11 carve-out, frozen:** the `filesByID[fileID] == record` self re-fetch (reference clause
  R5) is a tautology only where both operands come from the same live synchronous read (no `await`
  between bind and compare) — the fact model does not reproduce it, and doesn't need to. Where one
  operand is a **captured** record (frozen into a shard built behind an earlier `await`, e.g.
  `readCodemapGraphIndexCatalogPage`'s `:14587-14592`), the comparison is not tautological and is
  preserved via `recordFingerprint` (§5.3 above). P4-6a's per-site audit classifies every R5
  occurrence into one of the two forms before touching it; this document does not perform that
  audit, it only freezes which fact makes the audit possible.
- **D-8 anchor:** 8 of the 15 measurable codemap functions in Appendix A of the design are async
  and need a per-site staleness check (an `await` between the guard and the use of the guarded
  record); a hoisted `CompactRecordBlockV1` carries `catalogGeneration` + `rootLifetimeId` so the
  check is generation-detectable rather than silent. P4-6a lands the per-site tests; this document
  only freezes that the block carries the fields the check needs.

## 8. SLO registration

Absolute and relative SLO targets for E-1, E-1d, E-2, and E-4 are registered in
`rust/benchmarks/slo-v1.json` under the `inventoryScopeV1` key, per this step's done-when
("`slo-v1.json` extended with registered inventory targets including the mention-path and
contention SLOs"). See that file for the frozen numeric targets and the Swift baseline capture
status; see `Tests/RepoPromptTests/WorkspaceContext/InventoryScopeSwiftBaselineTests.swift` for
the env-gated harness (`RP_RUN_INVENTORY_SCOPE_SWIFT_BASELINE=1`) that captures the E-1
kill-criterion reference numbers ahead of any Rust candidate.

## 9. Recon (P4-1 done-when items discharged here)

- **Appendix A ledger re-derived at `2803d3d9`:** the design's reproducible python derivation over
  the ten inventory tables in `WorkspaceFileContextStore.swift` (19,818 lines, unchanged from the
  design's own citation) reproduces **267 occurrences across 68 scopes**, identical to the design's
  anchor at `a756190d`. **No delta to reconcile** — P3-4 (token-accounting Rust port) did not touch
  this file.
- **Lock census re-derived at `2803d3d9`:** reproduces **40 / 37 / 2 / 1** exactly as stated in
  §2 above — identical to the design's corrected count. **No delta to reconcile.**
- **Open question 3 (UUID persistence) re-confirmed, sweep extended to presets/prompt storage per
  §11's explicit instruction:** `Infrastructure/Persistence/` (incl. `Presets/` and
  `DurableArtifacts/`), `Features/Prompt/Models/Presets/`, and `Features/Chat/Models/Presets/`
  contain zero `fileID` / `fileId` / `fileIDs` references at `2803d3d9`. The four persisted
  `Codable` document/override types in that surface --
  `PresetFileStore.WorkflowPresetDocument`/`.ModelPresetDocument`, `CopyPresetOverrides`,
  `ChatPresetOverrides` -- carry only preset/prompt identity UUIDs (`presetID`, `storedPromptIds`),
  never a file/folder inventory UUID. `CodeMapArtifactKey` remains keyed by `rawSHA256` +
  `rawByteCount` + `pipelineIdentity`, carrying no `UUID` field. The sweep is unchanged from the
  design's closure of this open question: nothing durable keys on a file UUID.
- **§3.5 correction, found during this recon (not present in the design as authored):** the
  design states "`snapshot.files` / `snapshot.entries` have no other reader" beyond
  `AgentFileTagSuggestionService`, and that `searchCatalogSnapshot` has "exactly five" call sites
  outside the store. **Both are stale at `2803d3d9`.** A repo-wide grep for `searchCatalogAccess(`
  (the store's thin wrapper over `searchCatalogSnapshot`, `WorkspaceFileContextStore.swift:7094-7102`)
  finds **two** additional whole-table consumers beyond the design's five direct-call sites, for a
  corrected total of **seven**:
  1. `Features/Search/StoreBackedWorkspaceSearch.swift:306-334` reads `snapshot.files` in full
     (`let allFiles = snapshot.files`, `:334`) to build per-file search snapshots for explicit-path
     search filtering.
  2. `Features/AgentMode/Services/AgentContextFileBrowseService.swift:524-547`
     (`storeBackedCandidates`) reads `snapshot.entries` in full, filters it, and builds and caches a
     private `StoreSearchIndex` per `SearchIndexKey` -- the same "whole-table walk plus a per-query
     index build" shape §3.5 attributes solely to `AgentFileTagSuggestionService`.

  Neither is a passive counted/forwarded reference like the four non-consumer sites the design's
  table correctly classifies. This does not change P4's architecture (`inventoryQuery` / paged
  reads already serve filtered-file-list and haystack-query consumption; both sites need the same
  served-page/query shape `AgentFileTagSuggestionService` needs, not a new one) but it does mean
  **P4-7's suggestion-service cutover is not the only site that must move off a full-table
  `snapshot.files`/`snapshot.entries` read** -- recorded here so P4-6a/P4-7 do not rediscover it as
  a surprise, and so P4-7's done-when is understood to cover at least three sites, not one. No fix
  lands in this step; this is a recon correction, not a behavior change.

## 9b. P4-2 results (de-risking experiments GO/NO-GO gate)

**Status: GO-with-E2-deferred.** P4-2 ran all six experiments from the design's §10 (E-1, E-1c,
E-1d id-keyed, E-1d path-keyed, E-2, E-3, E-4) against a throwaway `InventoryScope` spike in
`rust/spikes/inventory-scope-spike` (explicitly permitted by §10's "Prototype `InventoryScope` in
Rust with in-place sorted tables"; not the P4-3a production scope). Full results, raw numbers, and
methodology notes (including two corrections made after an adversarial self-review of the first
draft): `rust/benchmarks/results/v1/p4-2-inventory-scope-derisking-v1.md` (narrative) and the
paired `.json` (raw data). SLO registrations updated in `rust/benchmarks/slo-v1.json`'s
`inventoryScopeV1` key and its new `p4TwoResults` key.

Verdict summary: E-1 (kill criterion) passes by 3-4 orders of magnitude under both cargo release
and debug profiles, after correcting a tail-append measurement bias in the first-draft harness
(the corrected margin is smaller but the verdict is unchanged -- see results doc §2). E-1c passes
with zero unexplained rejections across six replayed scenarios, each independently re-verified
against the live watermark/collapse source rather than trusted from this document's own summary,
**explicitly scoped to the `staleWatermark` rejection reason only** -- the other five typed
rejection reasons (§5.1) are deferred to P4-3a's cargo property tests. E-1d id-keyed passes under
both profiles with large margin; E-1d path-keyed passes under the release profile Rust code
actually ships at, **with a thin margin at N=1000/10000** that a genuine (failed, blocked by an
unrelated pre-existing compile break) release-profile Swift capture attempt could not close out --
flagged explicitly rather than assumed safe -- plus a named, non-blocking debug-profile regression
(~5x) tracked forward. E-3 (10k-iteration handle soak, ASan-clean) and E-4 (contention soak,
TSan-clean, p99 208.79us against a 1ms cap) both pass and E-4 additionally answers open question 6
with measured evidence (per-root locking gives ~3.35x lower p99 at 8 roots but is not required to
clear the cap; the §5.2.1 per-scope default is kept for P4-3a). E-2 is correctly reported
**BLOCKED** rather than passed or failed: its registered criteria (time-to-first-paint,
`@MainActor` apply cost, wire bytes, the mention-query, the B2 shard page) all require
infrastructure (the bridge, `@MainActor` wiring, the suggestion-service rewiring) that does not
exist before P4-4/P4-6b/P4-7; partial allocation-economics evidence is recorded but does not
discharge those criteria, and R8's memory-regression risk carries effectively no comparative
evidence out of this step (recorded as a gap, not papered over) -- both must be revisited at those
later steps.

D-1's N is set to **1** (unchanged from today's `maxLogicalMutationCount`), provisionally, pending
a real FFI-dispatch-tax measurement once P4-4's bridge exists to measure it against (this
cargo-only spike found no in-process batching benefit because it crosses no real FFI boundary).
The 10k-path session-startup budget (§8's `slo-v1.json` registration) is set to **50ms**.

## 10. Registration

This document is registered in `Scripts/source_layout_guardrails.sh`'s `allowed_tracked_docs`
allowlist in the same change that adds it (guardrail 8), per the design's promotion-path
requirement (§12): failing to do so blocked an earlier ADR gate and is not optional bookkeeping.
