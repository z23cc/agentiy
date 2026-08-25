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

`inventory-compute-v1` and its 17-test differential remained as-is through P4-5 as the standing
parity contract for builder semantics. **Update (P4-8):** the wire, its Rust codec
(`agentry_runtime::inventory::compact`/`contract`), its Swift FFI seam (`RustInventoryComputer`,
`CoreComputeClient.inventoryBuild*`, `CoreRuntime.inventory_compute_v1` / `inventoryComputeV1`),
and the 17-assertion Swift differential (`InventoryRustSwiftDifferentialTests`) plus its paired
`InventoryCutoverBenchmarkTests` (ADR-0008's `RP_RUN_INVENTORY_CUTOVER_BENCHMARK` harness) are
retired. One documented boundary from that differential (`folder_order`'s raw-byte-vs-Unicode-
canonical divergence on precomposed/decomposed folder names) is re-pinned Rust-side as
`inventory::ordering::tests::folder_order_diverges_from_swift_unicode_canonical_equivalence`,
since `build_authoritative_catalog_components` / `build_root_catalog_shard_patch` (and all of
`ordering`) remain live, reused verbatim by `InventoryScope`'s state machine. The Swift builders
themselves (`WorkspaceInventoryCatalogBuilders`) are **not** retired by this step -- they remain
production-authoritative and out of this step's scope; their retirement, `WorkspaceInventoryCatalogBuilders`
deletion, and the Tier-3 (`inventoryExportCompactV1`) zero-call-site assertion remain open P4-8
done-when items, gated on P4-7 landing first.

### P4-8 prerequisite amendment — complete authority-owned snapshot paging

Before a general catalog can stop rebuilding ordered inputs through Swift dictionaries, the
read plane must guarantee that a complete immutable Rust generation can be consumed without
silently truncating either record table. `inventorySnapshotPage` pages files and folders through
the same offset/limit window independently. Its progress fields therefore use the larger of the
returned file/folder counts, and `hasMore` remains true while either table fills the window. The
former files-only calculation truncated roots whose folder table outlived their file table.

`WorkspaceInventoryScopeAuthority.readOrderedSnapshot` now owns the full paging loop, validates
the Swift and Rust lifetime fences before and after the suspending page reads, preserves Rust-
published order, rejects inconsistent/non-progressing page metadata, and closes the handle before
returning either a complete generation or an error. Existing
`WorkspaceFileContextStore.fetchFileTreePageIndex` consumes that helper, revalidates the Swift
lifetime after the authority await, and degrades only the explicit no-published-generation outcome
to an empty root; cancellation, lifetime rotation, malformed progress, and page/transport failure
return no page index rather than publishing a partial or falsely empty result. Callers of the
store's non-throwing catalog fallback remain best-effort and may omit an unavailable root;
this helper-local contract is not an end-to-end availability claim.

### P4-8a amendment — normal per-root shard direct read

The normal `RootCatalogShard` cold/rebuild path now consumes
`WorkspaceInventoryScopeAuthority.readOrderedSnapshot` directly. It stable-filters the remaining
Swift-local managed-only visibility overlay, maps records through the shared republication adapter,
synthesizes the root marker, and materializes aligned search entries without rebuilding id-keyed
dictionaries or re-sorting Rust's published file/folder tables. A root with no published Rust
generation is a successful cacheable empty shard containing only that marker.

The store validates the root key, Swift applied-index generation, store-local inventory mutation
epoch/depth, delta state, and published-shard identity across every suspending read and again for
the complete multi-root batch immediately before its atomic publication. The mutation fence spans
each store-owned Rust commit through Swift topology/event publication, closing the reentrant window
where new Rust records could otherwise be published under an old Swift generation. An unavailable,
cancelled, or stale direct read never publishes a partial shard; the existing non-throwing
catalog fallback remains best-effort and uncached. DEBUG catalog sort accounting is
intentionally zero on the successful direct path because no Swift sort ran.

P4-8a initially routed folder mutations through that direct rebuild while retaining the file-only
Swift patch temporarily, avoiding binary insertion into a Rust-ordered folder table with Swift's
non-equivalent canonical-comparison ordering. P4-8b below retires the remaining file patch.

### P4-8b amendment — retire applied-event shard patching

After the existing lifetime, generation, dirty-state, full-resync, and topology checks accept a
canonical applied-index event, both file and folder mutations now publish one complete ordered Rust
generation through `rebuildRootCatalogShardAuthoritatively`. Event payload records remain available
to other subscribers but no longer reconstruct the search shard. Multi-record batches therefore do
not produce `patchThresholdExceeded`, and inconsistent patch payload records do not produce
`patchApplicationBackstop`; the current Rust authority wins.

The P4-8a mutation/batch fences and retention behavior remain unchanged. A retained-generation cap
still records `retentionBoundary`, withdraws the stale publication, marks the delta state dirty, and
recovers through the next authoritative event/read after leases drain. Every successful production
shard build is now classified as authoritative. The externally visible `patchCount`,
`maxPatchLogicalMutationCount`, `patchThresholdExceeded`, and `patchApplicationBackstop` names remain
compatibility tombstones: production reports zero/absent counts without removing MCP fields or enum
spellings. The pure Swift patch builder remains only as the frozen, opt-in historical P4-1 benchmark
reference, with a source-audit test forbidding every qualified or unqualified product reference.
An absent Rust generation is synthesized as an empty shard only for a never-published generation-zero
root with no delta state. Event-driven rebuilds, including generation-zero full-resync sentinels, fail
closed by withdrawing the publication and marking the delta state dirty rather than erasing a populated
catalog.

This deliberately trades the old single-record mutation algorithm for one affected-root `O(files +
folders)` page/materialization pass per accepted event. The retired patch already performed a full
Rust page-through and rebuilt Swift id dictionaries before patching, so P4-8b removes that duplicate
reconstruction rather than adding a second whole-root fetch. No new cache or coalescing authority is
introduced without measurement.

### P4-8c amendment — retire full-snapshot fallback and DEBUG shadow

The product fallback no longer copies the Rust-authority tables into UUID-keyed Swift dictionaries
and invokes `buildAuthoritativeCatalogComponents`, and the DEBUG path no longer performs a second
whole-root read, Swift sort/materialization, JSON encoding, and byte comparison after a successful
Rust-backed composition. Both pure Swift full-snapshot and patch builders are frozen historical P4-1
benchmark arms; a production-source audit forbids callers outside their declarations.

When a normal reusable/publishable shard batch cannot be prepared, the best-effort fallback now
captures a per-root lifetime/generation/mutation/delta/publication fence, reads each complete ordered
Rust snapshot through `WorkspaceInventoryScopeAuthority.readOrderedSnapshot`, materializes temporary
root shards without re-sorting, and revalidates the entire batch after all suspending reads. A root
whose fence changes or whose authority read fails contributes no file/folder rows, while the requested
root metadata remains present as it did under the predecessor fallback. The explicit no-published-
generation outcome synthesizes an empty root only at generation zero with no delta state.

Temporary fallback shards are presentation values only: they are never registered, published,
leased, cached, or counted as shard builds. The fallback therefore remains uncached; the next stable
query can publish the ordinary authoritative shard batch. At the P4-8c slice multi-root output still
used the existing pure merge algorithm; P4-8e-b below replaces that historical state with Rust
composition using uncached-fallback accounting. Deterministic tests
cover an active mutation that forces fallback, a root-A epoch change during root-B paging, omission of
only root A's rows, cancellation omitting the current root and stopping later reads, zero
publication/composition counters, and subsequent stable publication.

At the P4-8c slice, `shadowComparisonCount`, `shadowMismatchCount`, `lastShadowByteCount`, and
`.shadowValidationMismatch` remain zero/absent compatibility tombstones. P4-8c does not claim the
later D-5 Rust-internal replacement, which is closed by the post-P5-5 amendment below. The
pending-root Swift builder and multi-root presentation merge remain live P4-8 work at this slice;
P4-8d below retires the former. This amendment also does not flip `appliedIndexEvents()` to the armed
Rust republication stream; §12's generation/filtering/slice-rebase blockers and Phase 5 remain open.

### P4-8d amendment — retire pending-root Swift construction

Diff-seeded session-worktree preparation no longer sorts `RootIndexBuffers` or materializes a Swift
catalog components payload. While the newly minted root is still absent from every visible root map,
the store freezes its replay file/folder path sets and pending authority fence, seeds those paths
through the existing Rust discovery choke points, and reads one complete immutable ordered Rust
generation. Intermediate Rust generations remain unreachable to product readers and never create a
catalog shard, cache entry, lease, or composition/build diagnostic.

The ordered read must match the replay exactly: root identity, canonical non-empty paths, file/folder
kind separation, counts, path sets, Rust file/folder order, and Swift lifetime are all fail-closed.
Only the resulting Rust-ordered file entries reach `WorkspaceSeededRootReplayValidator`. An explicit
no-published-generation outcome is accepted only when both expected path sets are empty; a non-empty
pending root may not publish a falsely empty catalog.

Every suspending seed/read step is bracketed by a pending preparation fence covering root/lifetime,
Git authority fence and invalidation watermarks, mutation depth, service/watcher progress, and replay
snapshot identity. The complete fence is synchronously revalidated after the ordered read and before
the replay validator/ready assignment, with no intervening await. Cancellation aborts the attempt;
path disagreement or read failure takes the existing one-shot seeded-preparation fallback. Both paths
await the existing discard funnel, which closes the hidden Rust binding before a full crawl can reopen
the path. The later visible publication permit is unchanged and still installs only root metadata.

The two pending Swift builder layers are deleted and the production source audit requires their
identifier to have zero hits. `RootIndexBuffers` remains a per-attempt topology/replay buffer, not a
catalog ordering authority. At the P4-8d slice the pure multi-root presentation merge was the only live product function left
in `WorkspaceInventoryCatalogBuilders`; P4-8e-b below retires it. D-5's Rust-internal self-check and
the Phase 5 event-source flip remain open.

### P4-8e-a amendment — stateful Rust multi-root composition core

P4-8e retires the final product builder without reviving the stateless whole-table
`inventory-compute-v1` boundary. Swift continues to choose root scope and presentation policy, but
opens a Rust composition from an ordered descriptor list containing only `rootID`, the exact Rust
root lifetime, and an expected generation. No `WorkspaceFileRecord`, folder, entry, or shard array
is sent from Swift back into Rust. A missing expected generation is strict: it contributes an empty
source only while that root still has no published generation; it is never a wildcard for the
latest generation.

The runtime captures every requested generation `Arc` atomically under the InventoryScope mutex,
performs alignment validation and the full-path-plus-UUID stable merge after releasing that mutex,
then reacquires the mutex and revalidates every lifetime, exact generation, and captured identity-
invalidation epoch before registering a distinct composed-snapshot handle. Zero roots produce an
empty artifact. A single published root
reuses its immutable generation rather than copying rows. Multiple roots own one aligned merged
file/entry artifact and release the captured per-root generations after registration. Duplicate
root descriptors, generation drift, file/entry misalignment, root close, scope close, and identity
change all fail closed through typed outcomes; close is idempotent.

Composed pages are bounded and keep every file/entry shared identity and path field index-aligned.
Root-only query and lookup APIs
cannot accept the distinct composed handle type. Normal presentation accounting increments Rust's
existing single-shard reuse or generic-merge visit diagnostics only after successful second
validation and handle registration. One logical root increments the single-shard counter even when
its strict never-published source is empty; uncached fallback composition increments neither.
P4-8e-a lands this cargo-only authority core and contract. The additive FFI/page schema, Swift
bridge lease, store cutover, historical benchmark relocation, and final
`WorkspaceInventoryCatalogBuilders.swift` deletion land atomically in P4-8e-b.

### P4-8e-b amendment — atomic FFI/Swift/store composition cutover

The additive UniFFI contract now exposes distinct composed open/page/close calls. Open accepts only
runtime/scope identity, ordered root descriptors, and the normal-or-fallback accounting mode; pages
reuse the bounded bulk-chunk carrier with an empty folder section and report an exact artifact row
count/`hasMore`. Registration returns the handle and exact row count in one atomic state operation,
so invalidation cannot strand an unreturned handle between open and metadata lookup. Ordinary and
composed handles reserve disjoint raw-ID namespaces; a raw ID routed to the wrong UniFFI method fails
closed rather than aliasing another table entry. `CoreInventoryComposedSnapshot` owns the distinct
raw handle behind idempotent ARC close semantics, so root-only query/lookup APIs cannot consume it.
Identity invalidation drains both handle tables and releases retained-generation bookkeeping for
each drained single-root reference before the roots continue serving the new identity epoch.

Every published `RootCatalogShard`, including the codemap graph-index replacement path, carries the
exact Rust root lifetime and catalog generation from the authority read that materialized it. The
cacheable store path captures the complete per-root Swift batch fence and published shard object
identity, opens and fully pages the Rust composition, then revalidates both domains before publishing
or caching. Its search generation lease retains both the Swift shard objects and the composed Rust
handle. A stale or malformed result is closed and falls through to the uncached path; it is never
published as a mixed-generation snapshot.

The uncached path first omits roots whose existing per-root reads/fences failed, then composes the
remaining exact descriptors with `UncachedFallback` accounting and closes the handle before return.
Cancellation preserves the predecessor contract: already completed root reads can still produce a
best-effort result, while the current and later roots are omitted. Managed-only membership remains
Swift presentation policy; filtering the Rust-ordered composed page preserves order, and a final
visible-row count check against the fenced shards fails closed on drift.

Composition diagnostics are read from `InventoryScope` rather than incremented by a parallel Swift
counter. Frozen full-snapshot and single-mutation Swift benchmark arms move to
`Tests/RepoPromptTests/WorkspaceContext/HistoricalWorkspaceInventoryCatalogBuilders.swift`; the
unused test merge is deleted, production source auditing requires zero retired-builder references,
and the product `WorkspaceInventoryCatalogBuilders.swift` file is deleted. At this amendment P4-8
is complete except for D-5's separately approved Rust-internal self-check, closed after P5-5 below.
This amendment does not flip the applied-index
event source; Phase 5 remains the next authority transition.

### P5-1 amendment — armed republication correlation hardening

The Rust inventory-scope republication path remains armed on its separate
`republishedInventoryScopeEvents()` stream; production `appliedIndexEvents()` and its two consumers
remain unchanged. Before any source flip, the adapter now pairs `generationAdvanced` and
`appliedIndexBatch` events through a per-root FIFO rather than one overwriteable slot, so two
consecutive logical mutations for the same root retain their original generation order.

Hub gaps and global `resnapshotRequired` events advance a resync epoch consumed independently by
each root's next delivery; the first active root can no longer clear another root's obligation. A
root-scoped resnapshot clears that root's partial correlation and forces its next delivery to
resync. Correlation is fenced by Rust root lifetime, so stale generation/unload events cannot mutate
a newer binding that reused the same UUID. Root publish/unload events clear all per-root adapter
state. Pending correlation is bounded to 64 generations per root and 512 scope-wide; overflow drops
the affected partial correlation and forces root-scoped or global resync rather than defeating the
bounded upstream subscription. Missing correlation still republishes with generation zero plus
`requiresFullResync`, never a guessed generation.

This slice deliberately does **not** authorize the production source flip. That transition remains
atomic across: an activation cursor/floor that excludes hidden pre-publication Rust generations;
staging behind the store's existing mutation fence; Rust events for content-only modifications;
the bounded one-shot slice-source join; managed-only visibility/removal parity; and a monotonic,
lifetime-correct unload generation. Until those contracts land with consumer coverage,
`publishAppliedIndexEvent` remains the production authority.

### P5-2 amendment — activation floor and mutation-fenced armed delivery

Ordinary and seeded roots now arm republication only at their Swift-visibility seam. The authority
opens a metadata-only Rust snapshot and translates its zero-based catalog generation into the exact
one-based applied-index floor (`catalog + 1`); a never-published root uses floor zero. The authority
revalidates the current Swift/Rust binding after every suspending snapshot open before returning a
cursor. Bulk-load
`generationAdvanced` notifications have no companion `appliedIndexBatch` and currently carry the
catalog generation in both generation fields, so the adapter classifies that exact shape as a
bulk-only marker rather than letting it occupy the next delta's per-root FIFO slot.

The store binds that exclusive floor to both Swift and Rust root lifetimes. Ordinary crawl
publication performs no await between cursor capture and visible-state activation. Seeded-root
publication first pauses every pending ingress and revalidates its activation proof, then captures
all cursors immediately before the synchronous authority publication permit. Events at or below the
floor remain hidden. Later candidates are accepted only for the bound lifetimes and monotonically
contiguous nonzero Rust generations, then rebased onto the current Swift logical applied-index
generation. Adapter generation zero is an uncorrelated sentinel: it is never promoted above the
floor, and its root's next exact delivery must resync. Any gap in either domain forces
`requiresFullResync` rather than guessing.

A store-owned inventory mutation fence now spans Rust commit through legacy Swift event/topology
publication for the armed path as well. Rust candidates arriving while a root is activating or its
mutation depth is nonzero are staged and flushed only when depth returns to zero. Staging is bounded
to 64 candidates per root and 256 scope-wide; overflow discards partial state and forces root-scoped
or scope-wide resync. A transient cursor failure leaves the root in explicit quarantine rather than
permanently dark: recovery retries after visible publication and at later zero-depth mutation fences,
captures a fresh exact cursor, and forces the first recovered delivery to resync. The real add
differential uses one deterministic synthetic ingress and pins
hidden-load suppression, equal generation/payload identity against the production stream, and no
spurious resync. Separate deterministic coverage pins floor exclusion, fence withholding, and
bulk-only generation correlation, generation-zero exclusion, and quarantined activation recovery.

This amendment still does **not** flip `appliedIndexEvents()`. Production continues through
`publishAppliedIndexEvent`; the remaining atomic follow-on must cover content-only Rust events,
managed-only discoverability and empty-batch suppression, the bounded one-shot
`modifiedFileSourceSnapshotsByID` join, and monotonic lifetime-correct unload generation.

### P5-3 amendment — content-only Rust events and bounded slice-source join

Both canonical content-only mutation paths now reach the Rust authority before legacy Swift
publication: store-owned `editFile` operations and aggregated watcher/service
`.fileModified`/`.folderModified` batches submit an id-supplied `applyDelta`. A root-local
publication permit serializes the disk-write/Rust-apply/legacy-publication interval, so actor
reentrancy cannot let a later edit take an earlier edit's one-shot source. The modification apply and
`publishAppliedIndexEvent` are also enclosed by the store-owned inventory mutation fence, including
root-wide/full-resync paths that previously relied only on codemap fencing. A successful Rust receipt
supplies the exact applied-index generation for the local payload join; a rejected or failed apply
never fabricates correlation and makes the next armed delivery resync when the stream is active.

`publishAppliedIndexEvent` remains the sole production event authority and still performs the one
and only destructive `takeSliceRebaseSource`. When that take returns source text, the same immutable
snapshot value is transferred into an armed-only join keyed by root ID, Swift lifetime, and exact
Rust generation. The join is bounded to 64 entries and 32 MiB scope-wide. An activated candidate
consumes only its exact generation and only snapshots whose file IDs are named by that Rust batch.
Stale generations, cross-lifetime entries, payload collisions, or eviction never guess a source:
they discard partial state and force resync. Generation-zero quarantine, activation replacement,
root unload, and store unload clear pending joins. Ordinary modifications without a retained
pre-edit source continue to publish an empty snapshot map, matching legacy behavior.

Real store-edit differential coverage pins generation/lifetime equality and exact snapshot equality
against production across two separately read sources, followed by a third edit proving one-shot
exhaustion. A gated concurrent-edit test holds the first Rust receipt before legacy publication,
proves the second edit waits before its disk write, and verifies source/generation order on both
streams. A real synthetic watcher modification proves the content-only path produces a nonzero
Rust-backed armed event, and deterministic overflow coverage proves the bound plus resync
degradation. The focused P5 arming suite now contains 16 cases.

This amendment still does **not** flip `appliedIndexEvents()`. Production and both consumers remain
unchanged. The remaining source-flip blockers are managed-only discoverability/removal and legacy
empty-batch suppression parity, plus monotonic lifetime-correct unload publication.

### P5-4a amendment — exact raw-batch identity and resync-cause separation

P5-4's canonical presentation plan needs to validate a Rust notification against the exact command
receipt it represents; FIFO position and summary counts are insufficient because independently
coalesced pairs can have the same cardinality while naming different records. The armed adapter's
internal candidate therefore now carries the exact paired Rust generation and complete id-bearing
`CoreInventoryAppliedIndexBatchEventV1` before Swift presentation mapping. Root-unload candidates
carry neither a delta generation nor a raw batch. Generation zero remains the explicit
missing-correlation sentinel rather than a value inferred from the mapped consumer event.

The candidate also separates `rebuiltAuthoritative` from
`correlationIntegrityRequiresResync`. Hub gaps, scoped/global resnapshot obligations, pending-pair
overflow, lifetime rejection, and missing generation correlation are integrity failures that the
future presentation plan must conservatively carry across suppressed hidden generations. A
contiguous authoritative rebuild can instead be an internal consequence of safely touching
managed-only state and must not by itself become a later consumer-visible resync. The adapter's
compatibility `ingest(_:)` result deliberately continues combining both causes in
`requiresFullResync`, so this preparatory slice changes no existing armed output; the store now reads
the exact candidate generation directly rather than recovering authority metadata from the mapped
event shape. Two focused cases pin complete raw-payload identity, rebuild-only separation, and a
missing-pair integrity failure; the P5 arming suite now contains 18 cases.

This preparatory amendment remains armed-only. It does not itself install transaction-scoped
canonical presentation plans, suppress intermediate/hidden Rust generations, reproduce mixed-batch
cardinality, flip either production consumer, or publish unload. P5-4b supplies the first three
contracts below; the source flip and unload remain P5-5 follow-ons.

### P5-4b amendment — transaction-scoped canonical presentation plans

Every republication-visible Rust apply now returns a validated mutation receipt carrying the Swift
root lifetime, Rust root lifetime, exact applied-index generation, catalog generation, and apply
outcome. The store admits catalog mutations through a root-local publication permit that spans the
filesystem write (where applicable), Rust apply, legacy Swift catalog mutation, canonical event
construction, and plan sealing. A bounded per-root mutation segment records each accepted receipt
with the exact id-bearing raw batch; missing permits, lifetime drift, rejected receipts, duplicate or
non-monotonic generations, and capacity loss fail closed to a sticky resync obligation.

At the legacy visibility seam, the store seals one plan per captured Rust generation. Intermediate
and managed-only generations receive `suppress`; only the terminal visible generation receives
`publish(canonicalEvent)`. The published plan retains the exact already-filtered Swift event,
including logical generation, lifetime, record/path payloads, and pre-modification slice-source
snapshots. This replaces the earlier generation-keyed slice-source join and makes one logical Swift
batch authoritative even when it required multiple Rust applies. Fully filtered managed-only
batches advance only the Rust cursor and never advance the Swift logical generation.

Armed delivery now requires an exact key `(rootID, Swift lifetime, Rust lifetime, Rust generation)`
and exact raw-batch equality before consuming a plan. A suppression carries forward only
correlation-integrity failures; `rebuiltAuthoritative` alone remains an internal Rust implementation
detail. Missing, stale, mismatched, or overflowed plans force resync rather than synthesizing
presentation. Plans are bounded to 64 per root, 256 scope-wide, and 32 MiB of conservatively estimated retained
raw-plus-canonical payload; UUID collections, record/object overhead, and string storage all count
toward the overflow-safe byte cap. Overflow clears the affected root's plans and requires recovery
resync. A Rust generation jump is considered explained only when every skipped generation has an
exact suppression plan; missing coverage or a skipped visible plan preserves the integrity-resync
obligation. Empty full-resync anchors are submitted only while republication is armed.

The focused arming suite contains 22 cases, including real add/edit/watcher mutations, concurrent
edit serialization, exact slice-source parity, a visible-to-ignored move that emits exactly one
canonical removal, raw-payload identity, rebuild/integrity separation, unexplained generation-gap
recovery, armed-only empty anchoring, and count/retained-byte plan bounds.
P5-4b itself left production `appliedIndexEvents()` and both consumers unchanged; P5-5 below closes
monotonic lifetime-correct unload and performs the atomic source flip.

### P5-5 amendment — lifetime-correct unload and production source flip

`appliedIndexEvents()` now starts the same single hub subscription as the differential mirror. The
continuation is registered before source startup. Rust subscription open remains asynchronous; until
registration succeeds, mutations use legacy direct publication. At the open seam the store installs
activation captures for every visible root before opening the source gate, then resolves cursors in
parallel with the single stream drain so incoming candidates stage behind an exact fence rather than
blocking the drain. Authority acquisition idempotently re-arms an existing production/mirror
subscriber, covering a transient first runtime-open miss without eagerly starting background work
for stores with no event consumer.

A visible canonical plan is delivered in strict Rust generation order to both the mirror and the
existing production continuation; `publishAppliedIndexEvent` still constructs the Swift-authority
presentation payload but directly yields it only when no Rust subscription is active. The two
production consumers retain their existing subscription API and event shape; no consumer-side
routing or payload interpretation changed.

The staged-candidate drain is fully async and awaited through the root-local publication permit. A
per-root in-flight delivery acknowledgement keeps that permit held until the Rust-correlated
canonical event has updated the root catalog shard, not merely until its presentation plan was
removed. If exact mutation capture or plan sealing fails, the retained canonical visible event is
emitted immediately with `requiresFullResync`, correlation state is quarantined, and a fresh
activation is scheduled; the current production event is never silently dropped. If the hub stream
ends or fails, unconsumed visible plans receive the same one-shot fail-closed delivery and later
mutations return to the legacy direct-publish fallback. A later subscription rebases existing roots
from fresh Rust activation cursors rather than reusing a stale generation floor.

Unload freezes its complete canonical Swift event before `closeRoot`: next logical generation,
Swift lifetime, discoverable removal IDs/paths, and the full-resync/unload flags. The Rust
`rootUnloaded` event supplies the exact Rust lifetime receipt but cannot publish early; delivery is
held until the existing Swift teardown visibility seam. A bounded one-second actor-yielding wait
allows the independent hub drain to arrive, then fails closed to the retained canonical unload so
production consumers cannot miss root removal. Every unload state clear is conditional on both the
captured Swift and Rust lifetimes; a late close from an old lifetime cannot erase a replacement
root's activation, generation, or diagnostics. The focused republication suite contains 25 cases,
including monotonic mutation-to-unload generation, exact production/mirror unload parity,
immediate precision-loss recovery, and publication-permit acknowledgement through canonical shard
application. The existing CRUD/root-unload consumer-contract test also passes unchanged.

### D-5 closure amendment — Rust-internal patch self-check

The last separately approved P4-8 closure item is implemented after the P5-5 source flip. Runtime
configuration now carries `self_check_patches`, defaulting to `cfg!(debug_assertions)`; the FFI
record is intentionally unchanged, and the FFI conversion selects the same DEBUG-default policy.
Release archives therefore retain the zero-cost patch path rather than adding a public setting or
an ABI/schema toggle.

For each eligible checked patch, Rust captures the already-updated authoritative map input while
holding the scope lock, then performs the full rebuild and canonical comparison outside that lock.
The encoding covers every semantic file, folder, and projected-entry field in fixed order, with
explicit string lengths, UUID bytes, option tags, and raw modification-date bits. It excludes the
path-index representation because full and overlay indexes are allowed to differ internally and
are deterministic functions of the compared entries. String interning and allocator identity
cannot affect the result.

Installation revalidates the exact Rust root lifetime and base generation. A match publishes the
patch unchanged. A mismatch increments `shadowMismatchCount`, records
`shadowValidationMismatch`, emits the existing shard-fallback event, and atomically publishes the
already-computed authoritative artifact; the mismatched patch is never consumer-visible. A stale
base uses the existing patch-application backstop, while a rebound lifetime is rejected rather than
installing an old artifact into the new root. Stale, root-gone, and rebound attempts do not increment
comparison/mismatch counters or emit a false `shadowValidationMismatch`; only the artifact actually
eligible for installation contributes D-5 diagnostics. `shadowComparisonCount`, `shadowMismatchCount`, and
`lastShadowByteCount` now expose Rust scope diagnostics through the existing Swift/MCP fields; the
last byte count is the authoritative canonical comparison payload. Store-local fallback diagnostics
also consume the typed D-5 shard-fallback event.

Cargo contract coverage pins both arms: a matching patch remains `Patched`, while a deterministic
managed-only maps/published skew fails closed to `RebuiltAuthoritative` and serves only the
canonical discoverable rows. A barrier-driven stale-base race additionally proves the abandoned
self-check records only `patchApplicationBackstop` and leaves all three shadow diagnostics at zero;
event coverage pins mismatch ordering as `shardFallback` → `generationAdvanced` →
`appliedIndexBatch`. D-5 is therefore closed without restoring the deleted Swift shadow or creating
a second authority.

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
| `shadowComparisonCount` / `shadowMismatchCount` / `lastShadowByteCount` | scope-wide | Rust-internal D-5 canonical patch-vs-authoritative counts and the last authoritative comparison payload size; zero when the config gate is disabled or no eligible patch has run |
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
| `shadowValidationMismatch` | Produced by D-5 when canonical patch and authoritative bytes differ; the patch is discarded and the authoritative generation is installed |

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

## 11. Amendment: the discovery mint site (file/folder UUID minting)

**Status: landed alongside this amendment, pre-P4-6b.** This section documents a gap discovered
during P4-6b gate verification and closed before the cutover, not a new design decision requiring
its own review cycle -- the design doc's §4.1 item 3 and §4.1.1 already mandated this capability
as part of the indivisible items-1-8 unit; it was simply never built.

### 11.0 The claim-vs-built discrepancy, stated honestly

P4-3a's commit message and this document's earlier sections describe "UUID minting with test
seed" as part of P4-3a's landed, cargo-tested scope. What actually landed was `ids.rs`'s
`UuidMinter`, used exclusively to mint `InventoryScopeId` and `RootLifetimeId` — **scope and root
lifetime identity, not file/folder record identity.** Every mutation entry point
(`inventoryPushBulkChunk`, `inventoryApplyDeltaV1`) required the caller to supply `id` on every
`InventoryFileRecord`/`InventoryFolderRecord`; nothing in `bulk_load.rs`, `delta.rs`,
`identity_maps.rs`, `resolve.rs`, or the wire's `RECORD_STRIDE` row shape carried any provision for
an absent id. Neither this contract doc nor `descriptor()`/`fingerprint()` ever specified file/
folder minting. §4.1.1's explicit requirement — "Rust mints v4-shaped UUIDs from a per-scope
CSPRNG, with a test-only deterministic seed" — was undischarged. This was caught by direct
inspection of the Rust source (not by a failing test, since no test asserted the capability
existed) during P4-6b's pre-cutover re-verification, and is recorded here rather than silently
patched over.

### 11.1 The mint site

`InventoryScope` gains a second `UuidMinter` field, `record_minter`, kept deliberately independent
of `lifetime_minter`'s stream (a test-seeded scope's record ids and lifetime ids must not
coincidentally share a sequence). `new_seeded_for_testing(seed)` derives the record stream as
`seed ^ RECORD_MINTER_SEED_SALT` rather than adding a second caller-facing seed parameter, so the
existing public constructor signature is unchanged.

File/folder record identity requires RFC4122 version-4 shape (the byte pattern
`Foundation.UUID()` already produces at today's pre-cutover Swift mint site), unlike
`InventoryScopeId`/`RootLifetimeId`, which are opaque internal tokens never round-tripped through
`Foundation.UUID`. `UuidMinter::next_v4_bytes()` is `next_bytes()` with the version nibble (byte 6,
high 4 bits → `0100`) and variant bits (byte 8, high 2 bits → `10`) forced, added alongside the
existing `next_bytes()` (unchanged, still used for scope/lifetime minting).

`InventoryScope::mint_file_id()` / `mint_folder_id()` are the two `&self`-callable entry points
(interior-mutable via `record_minter`'s own `AtomicU64`, matching every other minter call site in
this module).

### 11.2 Additive wire shape: `DiscoveredFileRecord` / `DiscoveredFolderRecord`

**The existing id-supplied `RECORD_STRIDE` (14 words), `bulkChunk`, and `deltaEvent` message kinds
are unchanged, byte-for-byte** — this amendment does not touch them. A parallel, additive
`DISCOVERY_RECORD_STRIDE` (12 words: the same nine-field row shape minus the two `id` words) backs
two new message kinds:

```text
MessageKind::DiscoveryBulkChunk = 13    // sections: discoveredFileWords, discoveredFolderWords,
                                         //   stringRangeWords, blob
MessageKind::DiscoveryDeltaEvent = 14   // sections: rootId, upsertedDiscoveredFileWords,
                                         //   upsertedDiscoveredFolderWords, removedFileIds,
                                         //   removedFolderIds, removedFilePaths,
                                         //   removedFolderPaths, modifiedFileIds,
                                         //   modifiedFolderIds, stringRangeWords, blob
```

`DiscoveredFileRecord` / `DiscoveredFolderRecord` (Rust-only intermediate types, `wire.rs`) carry
`root_id`, `name`, `relative_path`, `standardized_relative_path`, `full_path`,
`standardized_full_path`, `parent_folder_id`, `modification_date` — every field of
`InventoryFileRecord`/`InventoryFolderRecord` except `id`. `InventoryDiscoveryAppliedIndexBatchEvent`
mirrors `InventoryAppliedIndexBatchEvent` with `upserted_files`/`upserted_folders` carrying the
id-less shape; every other field (removals, modifications — operations that by definition
reference an *already-known* id) is identical.

The Swift mirror (`CoreInventoryScopeWire` in `AgentryCoreBridge/CoreInventoryScope.swift`) carries
the matching additive types (`CoreDiscoveredFileRecordV1`/`CoreDiscoveredFolderRecordV1`/
`CoreInventoryDiscoveryAppliedIndexBatchEventV1`) and codec functions
(`encodeDiscoveryBulkChunk`/`decodeDiscoveryBulkChunk`,
`encodeDiscoveryDeltaEvent`/`decodeDiscoveryDeltaEvent`), fingerprint-locked to `wire.rs` exactly
as the id-supplied shapes already are (§15.3 item 6; `InventoryScopeWireFingerprintTests.swift`).

### 11.3 New scope methods and FFI exports

`InventoryScope::push_bulk_chunk_discovery` / `apply_delta_discovery` mint an id for each decoded
discovered record, then call the **existing, unchanged** `push_bulk_chunk` / `apply_delta` with the
now-fully-formed records — every gate (watermark, generation, lifetime), the patch/rebuild state
machine, and the published-generation bookkeeping are identical to the id-supplied path's already-
tested behavior. The receipt (`BulkChunkDiscoveryReceipt` / `InventoryDeltaDiscoveryReceipt`) echoes
the minted ids **in the same order as the input record vectors** (or, for delta, in
`event.upserted_files`/`upserted_folders` order) so the caller — which knows the discovered paths
in that order but not yet their ids — can zip them back together.

```text
CoreRuntime.inventoryPushBulkChunkDiscovery(RuntimeIdentity, InventoryScopeId, BulkLoadId, RootId,
    bytes) throws -> BulkChunkDiscoveryReceiptV1
CoreRuntime.inventoryApplyDeltaDiscoveryV1(InventoryDeltaDiscoveryCommandV1)
    throws -> InventoryDeltaDiscoveryReceiptV1
```

Minted ids are populated **even on a `Rejected` outcome** — minting happens before the gate runs
(the ids are needed to build the event the gate evaluates), so a caller must not attempt to
"un-mint" or reuse ids from a rejected delta; they are safe to discard (ids are cheap, per-scope,
never persisted).

`CoreInventoryScope.pushBulkChunkDiscovery` / `applyDeltaDiscovery` (Swift facade,
`AgentryCoreBridge`) are the corresponding public entry points, threaded through the same five
layers (`CoreRuntimeTransport` protocol requirement + default-unavailable extension,
`AgentryCoreBridge`'s real transport implementation, `AgentryCoreBridge`'s UUID-based wrapper,
`CoreInventoryScope`'s typed facade) the id-supplied path already uses.

### 11.4 Path→ID stability invariant (§4.1.1), restated as a testable contract

- A path with an **already-known id** is never re-minted: reuse the known id through the ordinary
  id-supplied `applyDelta`/`pushBulkChunk` path (the "modify" case).
- A path being staged for the **first time in a root lifetime**, or **re-added after removal**,
  goes through the discovery path and always mints a fresh id — discovery mints unconditionally on
  every call; it is the caller's responsibility (Swift's discovery/mutation pipeline, landed at
  P4-6b) to route a path to the id-supplied path once its id is known, never to discovery on every
  observation of the same path.

Proven end-to-end through the real FFI round trip in
`Tests/AgentryCoreBridgeTests/CoreInventoryScopeDiscoveryTests.swift`
(`testPathIdentityIsStableAcrossModifyButMintsAFreshIdAcrossRemoveThenReDiscovery`); seeded
deterministic minting and RFC4122 v4 shape are proven at the cargo level against the bare
`UuidMinter` (`rust/crates/runtime/src/inventory_scope/ids.rs`'s
`v4_bytes_are_deterministic_under_a_seeded_minter` / `v4_bytes_are_shaped_as_rfc4122_version_4`) —
the FFI layer has no seeded-scope constructor (production always opens a fresh-entropy scope), so
there is nothing further to prove about seeding through the bridge.

### 11.5 What this amendment does not do

It does not change any id-supplied wire byte, FFI signature, or Swift call site's behavior — every
addition here is a new, parallel surface. It does not itself wire Swift's discovery/mutation
pipeline (`WorkspaceFileContextStore`'s `indexFiles`/`indexFolders`/`ensureParentFolderID`) onto
these new exports — that wiring is P4-6b's own scope, now unblocked by this amendment rather than
discharged by it.

## 12. Amendment: the authority-swap cutover commit

P4-6b's actor-level table deletion (`filesByID`/`foldersByID` and their path-index siblings) and
the P4-5 shadow-arm deletion land in the cutover commit this section documents. Rust is now the
sole authority for the inventory tables; the DEBUG-only Swift-vs-Rust dual-read comparator that
verified the design before cutover is deleted along with it (§8.2's own framing: "the shadow arm
is the safety mechanism, and it lives entirely before the cutover"). This section states, plainly,
what shipped and what did not — full detail (file:line, reproduction commands, hypotheses) is in
`Tests/RepoPromptTests/WorkspaceContext/P4-6b-table-deletion-conversion-ledger.md`'s "Swap-completion
amendment" section; this is the architecture-facing summary.

### 12.1 Shipped

- Actor-level table declarations deleted; every live reader converted to a Rust-authority read
  primitive (`resolveRecordsScopeWide`, `lookupPaths`, `openSnapshot`/paging via
  `fetchFileTreePageIndex`) per the table-deletion ledger's per-site classification.
- Shadow apparatus deleted: the P4-5 `#if DEBUG` comparator block,
  `WorkspaceInventoryScopeShadowForwarder`, and its three shadow-only test files. The *other*,
  unrelated `RootCatalogShard` shadow-comparison feature (§5c's diagnostics; predates and is
  independent of the P4-5 arm) is unaffected and remains live.
- §4.3's republication adapter (`WorkspaceInventoryScopeRepublicationAdapter`) is constructed,
  subscribed to the authority's own event stream, and its translated output is live on a new,
  independent stream (`WorkspaceFileContextStore.republishedInventoryScopeEvents()`) — proven
  end-to-end against a real mutation. It is **armed, not flipped**: §12.2 below.
- D-6 (§9's drift register): snapshot instance identity (`===`) is now generation-token identity
  (`WorkspaceSearchRootPathIndexIdentity`), pinned by `WorkspaceCatalogShardTests`.

### 12.2 Not shipped — the republication source flip

§4.3 specifies the adapter replacing `publishAppliedIndexEvent`'s ~10 Swift-side call sites as
the production source for `appliedIndexEvents()`, the stream `WorkspaceSearchService` and
`WorkspaceFilesViewModel` actually consume. That flip did not happen in this commit. Two gaps,
discovered while arming the adapter against the real running tree rather than assumed from the
design:

1. **Generation-counter provenance across the Swift/Rust boundary is unproven.** The adapter
   numbers generations from Rust's `generationAdvanced.appliedIndexGeneration`;
   `publishAppliedIndexEvent` numbers them from Swift's own
   `nextAppliedIndexGeneration(forRootID:)`. Both consumers guard on `event.generation >
   handledGeneration`. Nothing in this pass proved the two counters agree for an already-loaded
   root — a mismatch would silently starve both consumers of updates (no crash, no
   focused-test signal) rather than fail loudly.
2. **`modifiedFileSourceSnapshotsByID`'s "local join" (§4.3 point 3) assumed a co-located
   producer.** `takeSliceRebaseSource` is a **take**, consumed exactly once, synchronously, at
   `publishAppliedIndexEvent`'s call site. A second, asynchronous consumer reading Rust's event
   stream in the background cannot take the same resource without a stash/eviction lifetime the
   design does not specify.

Neither gap is fixed here; both are named so the flip is a scoped follow-on with its own
resolution, not a guess made under this commit's pressure.

### 12.2a Amendment — republication source flip shipped in P5-5

P5-3/P5-4 replaced the one-shot asynchronous join with transaction-scoped canonical presentation
plans carrying the exact Swift logical generation and slice-source payload; P5-5 adds the
lifetime-correct unload seam and makes validated Rust correlation the production event source.
`appliedIndexEvents()` remains the consumer API, so `WorkspaceSearchService` and
`WorkspaceFilesViewModel` require no routing changes. Subscription failure emits retained visible
plans with full resync and restores legacy direct publication until a fresh activation rebase.

### 12.3 Not shipped — two behavioral regressions found by this commit's own gates

Both were found by running the tests the cutover's own gate requires (not introduced by loosening
that gate), and neither is fixed in this commit for the same reason as §12.2: a live fix authored
under cutover pressure, to code with a materially different risk profile than a table deletion, is
a worse trade than shipping a named, reproducible open item.

- **Catalog-shard patch decline.** `WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch`'s
  upserted-record equality guard now compares against a record re-fetched across the FFI
  (`fetchFileTreePageIndex`) instead of the same in-memory dictionary read the event was built
  from. The comparison is a full `WorkspaceFileRecord`/`WorkspaceFolderRecord` `==`, which
  includes `modificationDate: Date?` — a plausible (unconfirmed) precision-loss site on that
  round trip. Effect: the patch path declines (`nil`) where it used to succeed, falling back to
  `.patchApplicationBackstop` and a full rebuild on every affected upsert. Four
  `WorkspaceCatalogShardTests` are quarantined (`XCTSkip`, not deleted, not silently
  re-literaled) pending investigation.
- **`AgentContextFileBrowseModelTests` — whole class quarantined.** What began as one known-crash
  turned out to be at least three broken tests, each discovered only by running into it (three
  full unfiltered `swift test` runs each stopped partway through this one class): two crash the
  whole `RepoPromptTests.xctest` process outright (`mutationQueue.removeFirst()` on an empty
  array; an out-of-range index, crash site not yet isolated), one fails without crashing (an
  expected folder never surfaces in the tree read within the test's wait window). A Swift fatal
  error kills the whole process and `swift test` does not resume a crashed bundle's remaining
  tests, so any one of these silently voids the gate for every alphabetically-later class. The
  remaining ~17 tests in the class were never reached, so their status is unverified. The whole
  class is quarantined (`setUpWithError()` throwing `XCTSkip`), not the three known-broken tests
  individually, so this doesn't silently claim the unverified ~17 are known-good. The production
  file (`AgentContextFileBrowseModel.swift`) is untouched. The leading hypothesis, shared across
  all three, is that this cutover's changed read-path timing (async Rust round trips where there
  were synchronous dictionary reads) exposed pre-existing latent races/assumptions in this
  model's session-fenced mutation and tree-loading state machine rather than introduced new ones,
  but this is not confirmed by a diagnosed root cause.

### 12.3a Amendment — both §12.3 open items resolved in a follow-on commit

Both open items above are now fixed, root-caused, and verified. Full detail (instrumentation used,
reproduction, per-site fixes) lives in
`Tests/RepoPromptTests/WorkspaceContext/P4-6b-table-deletion-conversion-ledger.md`'s per-item
resolution notes and this class's own doc comment
(`Tests/RepoPromptTests/AgentMode/AgentContextFileBrowseModelTests.swift`); this is the
architecture-facing summary.

- **Catalog-shard patch decline.** The `modificationDate` precision-loss hypothesis was wrong.
  Direct field-level instrumentation showed the mismatch was always in `parentFolderID`:
  `WorkspaceFileContextStore.file(rootID:relativePath:)`/`.folder(rootID:relativePath:)` returned
  Rust's raw `fact.parentFolderID` (root-marker-excluded convention: `nil` for a top-level record)
  instead of denormalizing it back through
  `WorkspaceInventoryScopeRepublicationAdapter.denormalizedParentFolderID` to Swift's
  self-referencing-marker convention (`parentFolderID == rootID`) the way every other
  reconstruction path already does. Fixing that then exposed a second, previously-masked bug in
  `buildRootCatalogShardPatch`'s ancestor-folder walk, which required a `foldersByID` lookup for
  the root marker itself — never populated, since the root folder is never sent to Rust — fixed by
  treating `parentFolderID == event.rootID` as the walk's implicit terminal case. All four
  quarantined `WorkspaceCatalogShardTests` are un-skipped and green.
- **`AgentContextFileBrowseModelTests`.** The "async-timing race" hypothesis was also wrong for the
  dominant failure — the real cause was a deterministic correctness bug, not a race.
  `AgentContextFileBrowseService.currentTreeIndex` searched
  `WorkspaceFileContextStore.appliedIndexRootSnapshot`'s `folders` array for the synthetic
  root-folder marker to seed `RootTreeIndex.rootFolderID`; post-cutover that array is sourced from
  `folders(inRoot:)`'s Rust-paged read, which — like the rest of the Rust boundary — never carries
  the root marker, so the search always failed, every root-level `hierarchy(...)` call reported
  `.missing`, and the model's `.missing` handler immediately collapsed the very node the caller had
  just expanded. Fixed by using `rootID` (`snapshot.root.id`) directly instead of searching for a
  marker record that no longer exists post-cutover. This single fix resolved all three
  crash/hang symptoms — the two crashes were downstream consequences of tests driving state built
  on a hierarchy load that never resolved, not independent races. Two narrower, real-but-unproven
  defects found by code audit while isolating the fix were hardened defensively in
  `AgentContextFileBrowseModel.swift` alongside it: `drainMutationQueue`'s `removeFirst()` was one
  statement removed from its emptiness guard (restructured so removal is tied to the element just
  observed), and `normalizedPath`'s `standardizedPaths([path])[0]` could crash on a path that
  normalizes to empty (changed to `.first ?? path`). The whole-class quarantine is removed; the
  full 23-test class is green, run twice.

### 12.4 Not shipped — drift-register items claimed resolved that were not

D-1 (`maxRootCatalogShardPatchLogicalMutationCount` 1 → N), D-2 (entries projected on read rather
than materialized), D-5 (shard shadow-comparison becomes Rust-internal), and D-10 (codemap
graph-index shard built authority-side) were all still unimplemented at the P4-6b cutover point,
verified directly against that running tree rather than assumed from an earlier plan. This is
historical cutover status: D-5 is closed by the post-P5-5 amendment above. See the amended
drift-register table in `WorkspaceInventoryScopeDriftRegisterTests.swift` for the per-item
evidence.

### 12.5 P4-7b Item 0 — a third root-marker-exclusion regression, fixed; two orthogonal ones found and deferred

Found and fixed while reproducing P4-7b's mandated pre-flight baseline check (unmodified HEAD at
`744379b6`). §12.3a fixed two root-marker-exclusion symptoms (the catalog-shard patch decline and
`AgentContextFileBrowseModelTests`'s tree-index seed); this is a third, independent symptom of the
same root cause the two named regressions did not touch.

**Root cause.** `WorkspaceFileContextStore.fetchFileTreePageIndex` pages only Rust-owned records,
and the root's own self-referencing folder marker (`id == rootID`, `standardizedRelativePath ==
""`) is never sent to Rust (root-marker exclusion, matching `rootFolderRecord(rootID:)`'s doc
comment). Pre-P4-6b, `state.folderIDsByRelativePath`'s keys always included that marker under the
`""` key (verified against the `fe14d61e` diff). Three call sites read `fetchFileTreePageIndex`'s
output without restoring the marker Swift used to synthesize for them, undercounting real folders
by one per root:

- `WorkspaceFileContextStore.folder(rootID:relativePath:)` — the general fact accessor: querying
  the root's own path (`relativePath == ""`) always fell through to a Rust lookup that always
  misses (Rust has no fact for a path it was never told about), returning `nil` instead of the
  root's folder record. Broke `lookupDiscoverableCatalogPathForExactAbsoluteSearchScope` for a
  root-folder-exact query (`StoreBackedWorkspaceSearchTests
  .testExactAbsoluteScopeHelperReturnsDeepestDiscoverableFileFolderAndRootFolder`).
- `WorkspaceFileContextStore.buildAuthoritativeCatalogComponents(roots:)` (feeds
  `RootCatalogShard.folders`, `WorkspaceCatalogDiagnostics.folderCount`, and the DEBUG catalog-sort
  instrumentation) — undercounted folders by one per root
  (`StoreBackedWorkspaceSearchTests.testDebugColdScopedPathSearchPhaseAccounting`'s
  `sortFolderInputCount`; `WorkspaceFileContextStoreTests
  .testStaticPathAndSearchSnapshotCachesReuseScopesAndBoundLRU`'s `diagnostics.folderCount`).
- `WorkspaceFileContextStore.folders(inRoot:)` (production; feeds
  `appliedIndexRootSnapshot(rootID:).folders`) and the DEBUG-only
  `debugAuthoritativeCatalogSortProbe`'s `sourceFolders` — same undercount, one per root.
  `GitWorktreeCreationReceiptTests` already `.subtracting([""])`'d this function's result in
  anticipation of the marker's presence, which is independent confirmation the omission was
  unintended.

**Fix.** All four sites now synthesize the marker the same way `rootFolderRecord(rootID:)`
already does elsewhere in this file, restoring the pre-P4-6b count. Verified non-regressing against
`AgentContextFileBrowseModelTests` (23/23 green) — `AgentContextFileBrowseService.currentTreeIndex`
was already written to tolerate the marker's presence or absence in `snapshot.folders`
(`makeTreeIndex`'s `folder.id != rootFolderID` filter keeps the marker out of the
`parentFolderID`-keyed grouping either way, per its own P4-6b-regression doc comment) — and against
`WorkspacePerRootPathSearchIndexTests`, `WorkspaceProjectedPathSearchTests`,
`WorkspaceInventoryScopeDriftRegisterTests`, `WorkspaceCatalogShardTests` (baseline 4 Bucket-B
skips, no new ones), and the full `StoreBackedWorkspaceSearchTests`/`WorkspaceFileContextStoreTests`
suites.

**Two further pre-existing failures found while validating this fix, confirmed present on
unmodified `744379b6` (i.e. independent of this fix, and independent of each other), genuinely
orthogonal to P4-7b's search-facade slice, and deferred rather than fixed here:**

- **Open item OI-1 (new; not drift — a bug, not an accepted deviation).**
  `WorkspaceFileContextStoreTests
  .testBatchedTopologyInvalidationUsesOneSelectiveCycleAndPreservesCatalog`'s
  `testEnsureIndexedFilesUsesOneSelectiveInvalidationCycle` case: `store.ensureIndexedFiles(paths:)`
  is expected to record exactly one new `WorkspaceCatalogDiagnostics` invalidation entry
  (`work.invalidations.count == before + 1`, `evictedScopes == ["all_loaded",
  "visible_workspace"]` on the last entry) but records several more (`5` vs. the expected `3`
  total, and the last entry's `evictedScopes` is `[]`, i.e. an unrelated later invalidation). This is
  a topology-invalidation-cycle-counting defect in `ensureIndexedFiles`'s selective-invalidation
  path, not a root-marker or search-facade issue.
- **Open item OI-2 (new; not drift — a bug, not an accepted deviation).**
  `WorkspaceFileContextStoreTests
  .testWriteAdaptersAndApplyEditsMaterializeCreateOverwriteAndFailurePostconditions`'s
  `testWorkspaceFileMutationServiceCreatesReadsAndOverwritesThroughStore` case:
  `WorkspaceFileMutationService.createFile(userPath: "Created.swift", ...,
  pathResolutionPolicy: .canonicalAliasFirst)` against a single freshly-loaded root throws
  `fileSystemServiceNotFoundWithContext("Could not resolve a destination within the current
  workspace for 'Created.swift'...")` from `WorkspaceFileMutationService.swift:223` —
  `store.resolveCreationPath` returns `nil` for a minimal single-root, unambiguous file-creation
  path. Also reproduces via `GitWorktreeCreationReceiptTests`' five `catalogMismatch` failures
  (`WorkspaceRootReusableSnapshotCoordinator` catalog-currentness classification), which fail
  independently of D-17 but may share a cause in the same read-resolution surface — unconfirmed,
  named separately pending a root-cause investigation neither P4-7b slice touches.

Both are reproducible in isolation on unmodified `744379b6` (verified by `git stash`-ing this
fix and re-running each filtered test), so neither is a regression introduced by this fix or by
P4-7b. Filed as named open items (OI-1, OI-2 — deliberately not `D-`-numbered: they are bugs, not
an accepted, justified deviation the drift register exists to track) per this document's own
convention (§12.3/§12.4) rather than left undiscovered; no P4-7b done-when depends on either.

**P4-7c confirmation and expanded characterization (OI-2).** The full unfiltered suite run at
P4-7c c3 surfaced OI-2's `catalogMismatch` family more broadly than "five": across two runs it
cascaded into 8-16 failing tests beyond `GitWorktreeCreationReceiptTests` itself --
`AgentRunWorktreeStartTests` (3), `WorktreeAPISmokeHarnessTests` (5),
`WorkspaceFileContextStoreExactCapabilityTests` (1), and `WorktreeStartupInstrumentationTests` (1)
all failed with the identical `catalogMismatch` string, directly or via a wrapping error -- one root
cause cascading through every consumer of git-worktree-reuse admission, not several independent new
ones. Confirmed via direct bisection, not assumed: `GitWorktreeCreationReceiptTests
.testLoadedRootAdmissionCurrentnessClassifiesCatalogStaleness` and `AgentRunWorktreeStartTests
.testCoordinatorCreateCarriesReceiptIntoEligibleOwnershipPreparation` were run directly (`swift
test --filter`) against `2f41e59f` -- the commit immediately preceding P4-7c c1, with zero P4-7c
code present -- and both fail identically there. Additionally, `git diff` across every P4-7c c1/c2/c3
change shows **zero lines touched** in `WorkspaceRootReusableSnapshotCoordinator.swift` (the file
that produces every `catalogMismatch` verdict) or in
`loadedRootCatalogBatchEvidence`/`admitReusableSnapshotForLoadedRoot`/
`loadedRootReusableSnapshotCurrentness` (`WorkspaceFileContextStore.swift`'s classification
functions) -- P4-7c's holder #6 port (`WorkspaceSeededRootReplayValidator`, §14.1) lives entirely in
`preparePendingSeededRoot`, a disjoint code path none of these tests exercise. The differing failure
count between runs (8 vs. 18, the delta including OI-1 itself) indicates OI-2's cascade is
timing/ordering-sensitive under full-suite parallelism, not that its scope changed -- still
unconfirmed root cause, still out of P4-7c's scope to fix, still reproducible independent of every
P4-7c change.

### 12.5a Amendment — OI-1/OI-2 root-cause session (2026-08-23, post-P4-7c)

Tasked to root-cause and fix OI-1/OI-2 as "the only remaining red on the tree" at HEAD `5de36ca3`.
The task's own restatement of OI-1/OI-2 names different symptoms than this document's §12.5 literal
definitions above -- recorded here rather than silently reconciled, since a future reader will hit
the same mismatch:

- Task's "OI-1": `StoreBackedWorkspaceSearchTests
  .testExactAbsoluteScopeHelperReturnsDeepestDiscoverableFileFolderAndRootFolder` plus three
  `testDebugColdScopedPathSearchPhaseAccounting` assertions (nested-root folder-record synthesis).
  This document's own §12.5 OI-1 is a different test entirely
  (`testEnsureIndexedFilesUsesOneSelectiveInvalidationCycle`, a topology-invalidation-cycle-count
  defect) -- see below.
- Task's "OI-2": `WorkspaceRootReusableSnapshotCoordinator` catalog-currentness classification
  producing `catalogMismatch`-family failures, cascade including `AgentRunWorktreeStartTests` (3) and
  `GitWorktreeCreationReceiptTests` (5). This matches this document's OI-2 and its P4-7c cascade
  characterization above.

**Task's OI-1 -- did not reproduce, already discharged.** Both named tests, and the full
`StoreBackedWorkspaceSearchTests` suite (48 tests), ran green in isolation
(`FILTER=StoreBackedWorkspaceSearch`, 22:35:06-22:36:06, HEAD `5de36ca3`, before any concurrent
change landed on `dev` this session). `testDebugColdScopedPathSearchPhaseAccounting`'s
`sortFolderInputCount == 2` assertion is exactly the count Item 0's root-marker-exclusion fix
(§12.5 above) restored. No fix was needed or made; task's OI-1 is discharged by work that had
already landed before this session began.

**Task's OI-2 -- root-caused and fixed.** `WorkspaceFileContextStore.loadedRootCatalogBatchEvidence`
classified every committed regular file's discoverability by reading
`RootState.fileIDsByRelativePath[path]`. That Swift dict is dead for any live root state: both
`RootState` initializers construct it `[:]`, its only writer is the `(state:indexes:)` `inout`
staging overload used solely by the seeded-root replay's local (pre-Rust-commit) candidate-set
build, and the ordinary `loadRoot` bulk crawl (`indexFolders(chunk.folders,root:)`/
`indexFiles(chunk.files,root:)`, the async overload) as well as every incremental discovery choke
point (watcher events, worktree creation, `materializeCatalogRegularFile`) route through
`indexFile`/`indexFolder` (singular) straight into the Rust authority without ever touching it.
Every file discovered any way other than the (nonexistent-for-live-roots) seed-replay staging path
therefore read back `discoverable == false` against real git evidence's `.searchableRegularFile`
disposition, tripping `loadedRootCatalogBatchEvidence`'s `(true, _)`/`(false, _)` mismatch branch
unconditionally and surfacing as `WorkspaceRootReusableSnapshotCoordinator
.CatalogBatchEvidenceResult.catalogMismatch` for essentially any committed file on any
loaded-root-reuse admission path -- exactly the P4-7c cascade characterized above.

Fix (commit `3727661b`): `loadedRootCatalogBatchEvidence` now resolves discoverability via
`inventoryPathLookups(in:relativePaths:)`, the same batched Rust-authoritative path-fact lookup
already used by the codemap/B1/bucket-C read sites, instead of the dead table. Verified green in
isolation before any concurrent change landed on `dev` this session (all runs against HEAD
`5de36ca3` + this one-file fix, 22:40-22:45):
`GitWorktreeCreationReceiptTests` 34/34, `AgentRunWorktreeStartTests` 53/53,
`WorktreeAPISmokeHarnessTests` 6/6, `WorktreeStartupInstrumentationTests` 22/22 -- the exact
cascade cluster the task named plus the doc's own broader P4-7c enumeration.

**Two doc-literal residuals confirmed still open, root cause not established.** This document's own
literal OI-1 (`WorkspaceFileContextStoreTests
.testBatchedTopologyInvalidationUsesOneSelectiveCycleAndPreservesCatalog`'s
`testEnsureIndexedFilesUsesOneSelectiveInvalidationCycle` case) and literal OI-2 first half
(`testWriteAdaptersAndApplyEditsMaterializeCreateOverwriteAndFailurePostconditions`'s
`testWorkspaceFileMutationServiceCreatesReadsAndOverwritesThroughStore` case, `resolveCreationPath`
returning nil) both reproduced in a clean `FILTER=WorkspaceFileContextStoreTests` run at 22:54
(HEAD `5de36ca3` + the OI-2 fix above; 135 tests, 3 failures -- these two plus one unrelated to
either open item). Investigation into `resolveCreationPath`'s nil result was in progress
(`buildStaticSnapshot`/`fetchFileTreePageIndex`'s `openSnapshot`-backed page read appeared to
disagree with `inventoryPathLookups`' fact read for the same just-crawled root) when the
discovery below invalidated every probe run after 22:54. Not fixed this session; root cause
unconfirmed. `WorkspaceFileContextStoreExactCapabilityTests
.testContextBuilderExactCandidateResolvesOnlyAuthorizedWorktreeContent` was also observed flaky
(passed some runs, failed others at three different assertion points including one this document's
OI-2 cascade enumeration already names) -- also inside the invalidated window; treat as
observed-but-unconfirmed, not a finding.

**Session-ending discovery: `dev` moved out from under this session.** This task's HEAD was
`5de36ca3`; by 23:13 four more commits had landed on `dev` from a concurrent session
(`16dc1164`, `409dd903`, `d33bf7cd`, `a18c07ac` -- "P6-1" phases a1-a4, Agent-Mode/Claude-provider
work per that session's own commit messages), including a `rust/crates/runtime/Cargo.toml`
dependency-feature change (`409dd903`, "pin nix process/event/signal features") and a regenerated
FFI binding-identity file. This repo checkout is a single shared working tree, not per-agent
worktrees, so both sessions' builds share one `rust/` source state at any instant regardless of
each session's own path-scoped staging discipline. A basic-crawl canary
(`WorkspaceFileContextStoreTests.testRootLoadIndexesFilesFoldersReadsContentAndLooksUpPaths` --
load one root with three files, assert `files(inRoot:)` finds them) was green in the 22:54 run
above and red (all discoverability assertions empty) in every run after 23:00, including a rerun
at quiet-tree HEAD `3727661b` (this fix, no concurrent build in flight) confirming it is not this
session's regression. An isolated `git worktree` re-verification at `5de36ca3` + this fix was
attempted for a clean bisection but blocked on an untracked, non-git-tracked
`Vendor/Sparkle/Sparkle.xcframework/.../dSYMs` local build artifact the fresh worktree checkout
cannot reproduce from git alone -- not pursued further given the timestamped 22:40-22:45 evidence
above already predates the regression window and needs no further defense. The crawl regression's
root cause is unconfirmed but correlates in time with the concurrent session's `rust/` change; fixing
it -- and the two doc-literal residuals above, whose own investigation was already trending toward
the same `openSnapshot`-backed read surface -- is out of this session's stated domain
(`Sources/RepoPrompt/Infrastructure/WorkspaceContext/**`) if it does turn out to require a `rust/`
change, and is not attempted here. The mandated full-suite gate (`make dev-test` expecting zero
failures tree-wide) was not run: it cannot produce a trustworthy zero-failure result while a
concurrent session is landing commits into the same tree and the basic-crawl canary is red for
reasons this session did not introduce and has not root-caused. Reported to the user rather than
run to a false green.

### 12.5b Amendment — session continuation: all residuals fixed, build-fingerprint drift named

Resumed after §12.5a's STOP, tree confirmed quiet at the prior session's end (`a18c07ac`) with full
domain ownership including `rust/` for this continuation.

**Step 1 finding: the crawl regression was never a real bug.** `make dev-cargo-archive` alone
regenerates the Rust archive's *runtime* fingerprint but not the checked-in Swift constant
(`Sources/AgentryUniFFIRaw/Generated/AgentryCoreBindingIdentity.swift`) or
`rust/ffi-contract/generated-manifest.json` -- those are written only by the separate
`cargo run -p xtask -- generate` step. `CoreBridge.initialize()` fail-closes
(`CoreBridgeError.incompatibleBindings`, `invalidate()`) on any handshake mismatch between the two,
and `WorkspaceFileContextStore`'s discovery choke points (`indexFile`/`indexFolder`) swallow that
failure via `try? await inventoryScopeAuthorityInstance()` -- so a fingerprint mismatch presents as
a silently empty crawl, indistinguishable from a real regression without instrumentation. Worse:
the fingerprint is not byte-reproducible across machines from identical committed `rust/` source
(confirmed directly -- `xtask generate --check` failed against the committed identity file on this
machine even after reverting the suspected `nix` feature-flag commit, and `xtask generate` itself
produced a *third*, still-different DEBUG fingerprint each time it was rerun against unchanged
source). `bindingChecksum` (the ABI-surface hash) stayed constant throughout; only `buildFingerprint`
moved, consistent with it incorporating something machine/build-path-specific rather than pure
source content. This is a real, named environment-portability gap in the generated-identity scheme
itself -- worth a follow-up on its own, out of this session's scope to redesign -- but the immediate
unblock is exactly the protocol already in place: `cargo run -p xtask -- generate` (not `archive`
alone) before trusting any test run that touches the workspace-context/inventory-scope surface,
especially after any `rust/` commit lands. Running it here resynced both generated files to this
machine and the crawl canary (`testRootLoadIndexesFilesFoldersReadsContentAndLooksUpPaths`) went
green immediately, with no production code changed. `AgentryCoreBindingIdentity.swift` and
`rust/ffi-contract/generated-manifest.json` ride this session's commit per protocol.

**Doc-literal OI-1, root-caused and fixed.**
`testEnsureIndexedFilesUsesOneSelectiveInvalidationCycle`: `ensureIndexedFiles(paths:)` calls
`indexFile(relativePath:root:)` once per eligible file in a loop; `indexFile` itself unconditionally
fires its own `invalidatePathMatchSnapshot` at the end of its body. Called outside a publication-
invalidation batch (unlike the file-system-watcher path, `applyPreparedIndexDeltaMutations`, which
already wraps its own `indexFile`/`indexFolder` loop in one), each of those per-file invalidations
fired immediately and independently, on top of `ensureIndexedFiles`'s own explicit
`.explicitMaterialization`-reasoned call after the loop -- multiplying one logically-batched request
into several immediate invalidations (5 observed for 2 files) instead of the one callers reasonably
expect. A second, compounding defect in the shared mechanism: `PublicationInvalidationBatch`'s
nested-call branch hardcoded `.insert(.fileSystemPublication)` regardless of the reason actually
passed, which happened to match `applyPreparedIndexDeltaMutations`'s own scenario (so that path's
tests never caught it) but would have silently mislabeled any other batch's reason too.

Fix (this session): `PublicationInvalidationBatch` now takes its reason once at construction
(default `.fileSystemPublication`, preserving the watcher path's existing behavior unchanged);
nested `invalidatePathMatchSnapshot` calls while a batch is active only broaden the affected
roots/kinds and flag the batch dirty, they no longer touch `reasons` at all. `ensureIndexedFiles`
now opens its own batch (`PublicationInvalidationBatch(reason: .explicitMaterialization)`) around
its `indexFile` loop and finalizes it once via `finalizePublicationInvalidations`, exactly mirroring
`applyPreparedIndexDeltaMutations`'s existing pattern. `WorkspaceFileContextStoreTests` (135 tests,
including both this case and the watcher-path case that pins `["file_system_publication"]`) --
135/135 green.

**Doc-literal OI-2 first half, root-caused and fixed.**
`testWorkspaceFileMutationServiceCreatesReadsAndOverwritesThroughStore`'s `resolveCreationPath`
nil result traced to `fetchFileTreePageIndex(rootID:)`: a root that has never had a single discovery
event applied (e.g. a genuinely empty freshly-loaded directory -- `loadRoot`'s crawl found nothing
to index, so no `applyDeltaDiscovery` call ever ran for it) never reaches whatever readiness
threshold `authority.openSnapshot(rootID:)` gates on Rust's side; the open throws, and every caller
of this function (`files(inRoot:)`, `folders(inRoot:)` -- including its own root-marker synthesis
via `rootFolderRecord(rootID:)`, `buildStaticSnapshot`, `descendantFiles`) silently returned nothing
at all, indistinguishable from "unknown root". Confirmed directly: `files(inRoot:)`/`folders(inRoot:)`
both returned `[]` (not even the locally-synthesized root marker) for a freshly-loaded, genuinely
empty root, while the identical scenario with one pre-existing file worked correctly throughout.

Fix: `fetchFileTreePageIndex` now checks `rootStatesByID[rootID] != nil` first (a currently-loaded
root is never truly unknown) and, when `openSnapshot` fails for such a root, returns an empty
`FileTreePageIndex` rather than `nil` -- `nil` stays reserved for a root this store does not know
about at all. This let `folders(inRoot:)`'s existing root-marker synthesis run as designed even
when Rust's snapshot open fails for an empty root.

**ExactCapability cascade member, root-caused and fixed (a real, deterministic bug -- not the flake
it first appeared to be).** `WorkspaceFileContextStoreExactCapabilityTests
.testContextBuilderExactCandidateResolvesOnlyAuthorizedWorktreeContent` looked timing-sensitive
across early probes (passed with extra diagnostic `await`s inserted, failed without) purely because
of §12.5a's build-fingerprint noise still contaminating those runs -- once isolated with a
instrumented, targeted probe against a clean build, the failure was 100% deterministic and had
nothing to do with timing. Root cause: `descendantFiles(in:)` resolves its owning root by asking
Rust's scope-wide id fact lookup (`resolveRecordsScopeWide`) which root a given folder id belongs
to -- but a root's own self-referencing marker folder (`id == rootID`) is deliberately never sent to
Rust (root-marker exclusion, the same convention `rootFolderRecord(rootID:)` and §12.5's Item 0 fix
both document). `fact.exists` was therefore always `false` for that id, and every root-level
folder-expansion call (`resolveContextBuilderSelectionCandidate`'s `selectsAuthorizedRoot` branch,
and any other caller expanding the root folder itself) unconditionally returned an empty descendant
set -- confirmed directly: `scopeWideFact.foldersByID[authRootID] == (record: nil, exists: false)`
while `files(inRoot:)` for the same root correctly listed both files.

Fix: `descendantFiles(in:)` now checks `rootStatesByID[folderID] != nil` first -- a folder id that
matches a currently-loaded root's own id IS that root's marker, and the owning root is already known
without a Rust round trip that structurally cannot succeed for it. Falls through to the existing
scope-wide lookup for every other (real, Rust-registered) folder id, unchanged.
`WorkspaceFileContextStoreExactCapabilityTests` -- 5/5 green across 5 independent repeated runs (0
failures each), where it had failed 100% deterministically before.

**Validation (this session, quiet tree, `xtask generate`-synced build).**

- `FILTER=StoreBackedWorkspaceSearch` -- 9/9 green (task's OI-1 suite; confirms no regression).
- `FILTER=GitWorktreeCreationReceiptTests` -- 34/34 green.
- `FILTER=AgentRunWorktreeStartTests` -- 53/53 green.
- `FILTER=WorkspaceFileContextStoreTests` -- 135/135 green (both doc-literal residuals fixed).
- `FILTER=WorkspaceFileContextStoreExactCapabilityTests` -- 5/5 green, 5 repeated runs.
- `make dev-cargo-codegen-check` -- clean (`xtask generate --check`).
- `make dev-cargo-test CARGO_PACKAGE=all` -- `cargo test --workspace` green.
- `make dev-lint` -- clean (SwiftFormat 0/1547 files need formatting; SwiftLint strict clean).
- `make guardrails` -- clean.
- Full unfiltered `make dev-test` -- run and babysat to completion below.

All four items this session's task named (task-OI-1 discharged pre-session per §12.5a, task-OI-2
fixed per §12.5a's `3727661b`, plus the two doc-literal §12.5 residuals and the ExactCapability
cascade member fixed in this continuation) are closed. No `rust/` production source changed --
only the generated identity/manifest files, resynced via protocol.

### 12.5c Amendment — the full-suite gate's last residual: a real FSEvents startup race, test-side

A full, unfiltered `make dev-test` run against §12.5b's fix (2 independent runs) surfaced exactly
one failure tree-wide, in neither OI-1/OI-2's family nor anything §12.5b touched:
`WorkspaceFileContextStoreTests.testSyntheticPublicationAppliesWithoutAdvancingWatcherAcceptedWatermark`
("2" vs expected "1" for the accepted watcher watermark). Passed reliably in isolation (3/3, ~0.014s
each) both before and after investigation, only failing under the full suite's heavy parallel load
(3.971s that run, vs ~0.014s isolated) -- the signature of a genuine OS-timing race, not a logic
regression from anything else this session touched.

Root cause: the test writes `Synthetic.swift` to disk *before* `loadRoot`/`startWatchingRoot` (the
initial crawl, not the watcher, is what catalogs it -- needed so the later synthetic
`.fileModified` delta has a real file to describe), then captures its "accepted watcher watermark"
baseline immediately after `startWatchingRoot` returns. macOS FSEvents can legitimately deliver a
coalesced historical-catch-up notification for a file written moments before a watch stream starts;
under light load that catch-up settles before the baseline read, under heavy load (many concurrent
FSEvents watchers across a full suite) its delivery can be delayed past the baseline capture,
landing as an extra real accepted-watermark increment that collides with the test's own synthetic
publish. `awaitAppliedIngressForAllRoots`'s own doc comment already names this precisely: "FSEvents
not yet delivered by macOS remain outside this contract." Not a production defect -- confirmed by
comparison against `testBarrierCaptureCutExcludesCallbackAcceptedAfterCaptureUntilNextBarrier`
(same file), which sidesteps the same class of race entirely by never writing a pre-existing file
and using `acceptWatcherPayloadForTesting`'s synthetic payload injection for its watcher-sourced
comparison instead of a real FSEvents write.

Fix (test-only): drain `awaitAppliedIngressForAllRoots()` twice, with a short pause between, before
capturing the baseline -- once for anything already in flight, a 150ms pause to give a delayed OS
catch-up a real chance to arrive, then once more to drain that too. `WorkspaceFileContextStoreTests`
-- 135/135 green; the isolated case re-run twice more, 3/3 total, all green.

With this, every failure surfaced across this session's two full-suite attempts is closed: task-OI-1
(discharged, §12.5a), task-OI-2 (`3727661b`), the two doc-literal §12.5 residuals and the
ExactCapability cascade member (`5da8f0dc`), and this FSEvents startup race (test-only, no
production change). Per this task's own final instruction, the full suite is not re-run a third
time in this session -- the prior full run is the tree-wide evidence, and this fix's own class-scope
validation (135/135) is the proof for the delta.

## 13. Amendment: P4-7b — the search facade cutover (b1–b4)

Promotion of the decided items per design doc `p4-7-pathsearch-production-cutover-v2-2026-08-23.md`
§12, landed across five commits on `dev`: b1 (`744379b6`, tie_break_key wire), Item 0 (`c2c4d240`,
the root-marker-exclusion fix, §12.5 above), b2 (`24304bb3`, read facade + differential), and b3/b4
(this commit). P4-7a (suggestion-service cutover) and P4-7c (the deletion gate) are explicitly out
of this amendment's scope -- neither landed here.

### 13.1 The flip (b3)

`WorkspaceSearchService` no longer builds or holds a Swift C `PathSearchIndex`. It consumes
`WorkspaceFileContextStore.searchRootQueryHandles(rootScope:)` (b2's read facade) instead of
`searchCatalogSnapshot(...).rootPathIndexes`:

- Non-empty queries issue `inventoryQuery(.indexKey)` per root against the retained handle;
  results are reconstructed into `WorkspaceSearchCatalogEntry` values from each candidate's
  already-standardized fields (`standardizedRelativePath`/`standardizedFullPath`, not re-derived)
  plus the handle's `rootName`/`rootPath`, then merged with the **unchanged**
  `WorkspaceInventoryOrdering.compareUTF8Binary(tieBreakKey)` → `searchCatalogEntryPrecedes`
  comparator.
- Empty queries page each root's handle (`inventorySnapshotPage`/`CoreInventorySnapshot.page`) at
  `offset: 0, limit: boundedLimit` -- bounded per root, not a whole-root walk, using the same
  per-root-top-N-then-merge argument the non-empty path already relies on (a true global top-N
  member must be a member of its own root's local top-N) -- then merged with the **unchanged**
  `searchCatalogEntryPrecedes` comparator (§4.2.1's catalog-order requirement).
- `makeRootPathSearchIndex` (`WorkspaceFileContextStore.swift`) is deleted; its two call sites
  (the authoritative shard build and the shard-cache promotion path) now construct
  `pathSearchIndex: nil` unconditionally. `WorkspaceSearchCatalogAccessRequirement.recordsAndPathIndexes`
  is **not** deleted (§4.4 explicitly allows leaving the enum standing) -- ground-truth/differential
  tests that need a populated `rootPathIndexes` for direct comparison still request it explicitly
  against the store -- but `searchCatalogSnapshot`/`searchCatalogAccess`'s *default* requirement is
  now `.recordsOnly`, and nothing in production ever requests `.recordsAndPathIndexes` again.
  `prepareAndPublishRootCatalogShardBatch`'s existing precondition
  (`!requirement.requiresPathIndexes || rootPathIndexes.count == roots.count`) is the fail-closed
  backstop if that ever stops being true.
- `rebuildIndex`/`prepareIndex` gained a `(store:rootScope:)` overload alongside
  `(handles:diagnostics:)`, fetching both from the store in one call -- callers
  (`WorkspaceCheckoutRefreshService`, `WorkspaceManagerViewModel`'s hydration flow, every test) pass
  the store directly rather than pre-fetching a snapshot, which is both simpler at each call site
  and removes the last reason those callers touched `WorkspaceSearchCatalogSnapshot` at all.
- Fallback policy (§4.6) is implemented as designed: `.rootClosed` drops that root's handle from
  the ready set and schedules a rebuild; `.scopeClosed`/`.identityChanged` marks
  `isReadyIndexUsable = false` and schedules a rebuild; any other query error (transport/decode
  failure) does the same -- never silently degrading to an empty result. Because
  `WorkspaceSearchService` is event-driven (`store.appliedIndexEvents()`), not polling, a
  query-time failure with no further catalog mutation would otherwise never self-heal; the actor
  now retains `store`/`rootScope` (set by `startKeepingFresh`/`rebuildIndex(from:rootScope:)`,
  mirroring the strong retention `appliedIndexListenerTask`'s own closure already performs) so its
  error handlers can proactively `scheduleRebuild` against the store's current generation.
- Hold-per-generation retention (§4.5) falls out of `commit(_:)` reassigning `readyHandles` --
  ARC-driven close via `CoreInventorySnapshot`'s own `deinit`, open-then-swap-then-close because
  the replacement `PreparedIndex` is fully built (handles opened, diagnostics fetched) before
  `commit(_:)` ever runs, so there is no window with zero ready handles.

### 13.2 Index accounting and the co-location gate (b4)

`Scripts/source_layout_guardrails.sh`'s new P4-7b §4.1.0 section is the mechanical half: it asserts
`makeRootPathSearchIndex` never returns anywhere in `Sources/RepoPrompt`, and that
`WorkspaceSearchService.swift` never constructs a Swift path index outside the DEBUG-only static
ground-truth reference arm (`authoritativeGlobalResultsForTesting`, kept for P4-7c's deletion gate,
independent of any instance).

The behavioral half took three attempts to land honestly, and the history is worth stating plainly
rather than smoothing over. Draft 1 asserted a dedicated
`WorkspaceSearchService.debugPathIndexConstructionCount` instance counter stayed 0 -- but that
counter had no code path left anywhere in the actor's instance-level surface that could ever
increment it (the whole point of the b3 flip), so the assertion was `0 == 0` by construction and
could not have failed under any regression. Draft 2 switched to the store's `pathIndexBuildCount`/
`overlayPathIndexBuildCount` shard diagnostics, reasoning that `registerPublishedRootCatalogShard`
-- their one live increment site -- funnels every shard publication through it. A live test run
disproved this: `WorkspaceSearchService`'s post-b3 production path (`searchRootQueryHandles` ->
`authority.openSnapshot`) never touches the shard system at all (the store's own comment: "keep
catalog publication fully lazy until a caller requests a catalog capability"), so
`rootCatalogShards.roots` is empty throughout the gate suite's scenarios and the sum is 0 for the
trivial reason -- vacuous again, for a different structural cause than draft 1.

Draft 3, landed here, is the honest conclusion rather than a third counter: §4.7's "zero Swift
path-index constructions" is a *structural* property post-b3, not a runtime quantity. There is no
construction site left in the service's own code to instrument, by design -- any runtime counter
reached for will be either definitionally unreachable (draft 1) or fed by a subsystem the service no
longer calls (draft 2), because that is a property of the architecture, not a gap in the search for
one. `Scripts/source_layout_guardrails.sh`'s grep is the real enforcement here, exercised on every
invocation. `WorkspaceSearchColocationGateTests` adds, honestly: (1) correct results through every
shape a search-driven catalog generation takes (cold rebuild, non-empty query, empty query, live
event-driven rebuild) -- real coverage of the flipped path, not a construction check; (2)
`discardedQueryErrorCount` (§4.6, incremented by `handleQueryInvalidation`/
`handleQueryTransportFailure` on the live query path -- a real, live instrumentation point, unlike
either discarded counter) stays 0 across all four shapes, distinguishing "search returned results"
from "search silently degraded and returned results anyway"; and (3) a blunt backstop, noted rather
than exercised: a regression that made the service request the retired `.recordsAndPathIndexes`
capability again would `preconditionFailure` in `composeSearchCatalogSnapshot` (D-14) -- unmissable,
if not a clean assertion. Together with the mechanical guardrail these discharge §4.7's "index
accounting" and "co-location gate test" done-when items -- the mandated gate that never landed at
P4-6b now exists, with its behavioral half's actual guarantee stated as what it structurally is
rather than as a counter it never needed.

### 13.3 Drift register D-13–D-15

| ID | Drift | Status |
|---|---|---|
| D-13 | `retentionBoundary` rate becomes sensitive to search handle retention (§4.5's hold-per-generation policy: ≤2 handles/root attributable to search). | Registered, not yet re-measured post-flip. b2's baseline (`WorkspaceSearchHandleRetentionBaselineTests`): `retentionBoundary=0` over a 39-patch edit storm on unmodified pre-flip code. §4.5's own done-when ("a behavior test asserting `retentionBoundary` occurrences... are not greater than the... baseline") is **not separately re-run against the post-flip system in this pass** -- named follow-up, tracked in `slo-v1.json`'s `p4SevenBResults.followUpConditions`. |
| D-14 | `WorkspaceSearchCatalogAccessRequirement` keeps `.recordsAndPathIndexes` (not deleted, per §4.4's explicit option) but the capability is unreachable from any production caller; `WorkspaceSearchCatalogSnapshot.rootPathIndexes` is likewise kept, not deleted. | Implemented as the lighter of §4.4's two options -- deletion costs more (touches `WorkspaceSwitchSearchIndexDiagnostics.swift`'s switch and internal shard-capability bookkeeping that assume two cases) than it buys, since the invariant (§4.1.0) is already enforced by `makeRootPathSearchIndex`'s deletion regardless of whether the enum case exists to be requested. "Unreachable" is not merely aspirational: `composeSearchCatalogSnapshot` now `preconditionFailure`s (`shard.pathSearchIndex` is always nil post-deletion) if any caller actually requests `.recordsAndPathIndexes` -- fail loud, not silently under-deliver, mirroring §4.6's read-side fallback discipline. This crashed two of b2's own committed test files that pinned the pre-flip Swift arm by requesting `.recordsAndPathIndexes` directly (`WorkspaceSearchHandleRetentionBaselineTests`, `WorkspaceSearchRustIndexKeyDifferentialTests`) -- both updated in the b3 commit to route through `.recordsOnly` (the shard patch/retention counters these baselines measure are unaffected by the path-index requirement) and, for the ordered-candidate arm specifically, through the sanctioned DEBUG ground-truth helper `WorkspaceSearchService.authoritativeGlobalResultsForTesting` that `WorkspacePerRootPathSearchIndexTests` already used post-flip. No coverage was dropped, but the claims are not byte-for-byte identical: the ordered-candidate
Swift arm went from per-root `WorkspaceSearchRootPathIndex.search` + an explicit re-sort by
`tieBreakKey` to a single global index whose internal ordering is now trusted rather than
re-derived per root. Equivalent claims, narrower Swift arm -- both suites remained green. |
| D-15 | The seeded-root diff-replay self-check (`WorkspacePendingSeededRootTests`) and the search-time projected shadow (`installRootSeedSearchShadow`) both read `snapshot.rootPathIndexes`, now always empty by default -- the projected-reuse-identity assertions those tests made are removed (documented in-place; §4.2.2's accepted gap). | Implemented as designed. The underlying claims (files discoverable/searchable after seeding) remain covered by the surrounding record-level assertions in the same tests, not lost -- only the *index-object*-level redundant re-check is gone. |

### 13.4 Known deferred items (named, not silent)

- **SLO measurement at 100k paths, and at release profile.** §4.7's "Interactive-search latency
  SLO" is registered in `rust/benchmarks/slo-v1.json`'s `p4SevenBResults` with a real 10k-path,
  debug-profile p50/p99 measurement (`WorkspaceSearchInteractiveLatencySLOTests`, gated behind
  `RPCE_RUN_SEARCH_LATENCY_SLO=1`). The 100k tier and a release-profile re-capture are named
  follow-ups, not silently dropped -- see that JSON entry's `followUpConditions`.
- **D-13's post-flip re-measurement.** See §13.3 above.
- **`WorkspaceFileSearchIndexTimeToReadyBenchmarkTests`' `pathIndexBuild`/`overlayPathIndexBuildCount`
  counter assertions are now stale** (they expect nonzero values from Swift index construction,
  which can never happen post-flip). Not fixed in this pass -- the whole suite is gated behind the
  `RPCE_BENCHMARK_TESTS` compile flag and does not run in default builds, so it is not a live gate
  failure, but it is a real regression if that flag is ever enabled. Named follow-up for whichever
  phase next touches that benchmark harness (likely P4-7c, when the harness's whole premise --
  measuring Swift index construction latency -- needs redesigning around what "time to ready" means
  once the index no longer exists to build).
- **E-2's mention-query criterion** stays with P4-7a (contract doc §9b), not this document's scope.
- **§7's full-suite validation row** is deferred to P4-7c per this task's own instruction; the
  broad, non-exhaustive sweeps run during b3/b4 (§13.1/§13.2 above and the commit message) are
  evidence toward it, not a discharge of it.

## 14. Amendment: P4-7c — the deletion gate (c1–c3)

Promotion of the decided items per design doc
`p4-7-pathsearch-production-cutover-v2-2026-08-23.md` §6, landed across two commits on `dev`: c1
(`a2ace1f6`, holder disposition) and c2/c3 (this commit, zero-reference proof + the atomic
deletion). This is P4-7's closing amendment -- P4-7a (`2f41e59f`), P4-7b (§13 above), and P4-7c
(this section) together retire the whole PathSearch production-cutover campaign; no further P4-7
phase remains.

### 14.1 Holder disposition (c1)

Three holders remained after P4-7b b3 made `.recordsAndPathIndexes` unreachable from the search
facade (D-14); §6.2-§6.4 named their dispositions.

- **Holder #4 (`AgentContextFileBrowseService.storeBackedCandidates`).** §6.2's original
  complication -- `AgentContextFileBrowseModelTests` was a whole-class quarantine that could not
  validate a rewire -- no longer applied at c1's HEAD: the root-marker `.missing` fix (§12.5) had
  already taken the class to 23/23 green. The rewire branch was taken outright: rewired onto the
  store-vended `suggestionQuery(rootID:pattern:limit:...)` seam, the same `.suggestion` haystack
  shape `AgentFileTagSuggestionService` cut over to at a3, confirmed byte-identical to the
  pre-rewrite `searchHaystack(for:lookupContext:)` by direct source comparison. Landed with a new
  differential, `AgentContextFileBrowseSearchParityTests`.
- **Holder #5 (`WorkspaceFilesViewModel`'s markdown-link-open fallback).** §6.3's recon-then-decide:
  static call-graph analysis (no live-session measurement was available this slice -- no visible app
  relaunch was authorized, per this slice's own constraint) found exactly one production call site,
  `MarkdownFileLinkOpener` wired as a per-tap SwiftUI environment callback (`AgentModeView.swift`),
  not a per-keystroke or document-wide loop. That frequency profile tolerates rebuilding the whole
  corpus index per call, so branch (a) was taken: ported onto `AgentryCoreBridge`'s stateless
  `pathSearchFindV1(corpusPaths:queries:)` `.find`-mode seam. This is a substitution of static
  call-graph analysis for the design's originally-envisioned live measurement, recorded here rather
  than silently treated as equivalent. `CorePathSearch.swift`'s module doc, previously "DIFFERENTIAL-
  ONLY, no production caller," is corrected: `.find` mode now has a real production caller;
  `.projected` mode remains differential-only with no production caller (its Swift counterpart,
  `WorkspaceProjectedPathSearchIndex.searchProjectedSynchronously`, is deleted at c3).
- **Holder #6 (the seeded-root diff-replay self-check, `WorkspaceProjectedPathSearchIndex.init`).**
  §6.4 said "port the verdict, not the object," and named Rust's `projected.rs` as already carrying
  the projected shape. Direct investigation found this is not quite right: `projected.rs`'s own
  module doc explicitly *defers* the one thing this holder needs -- a seed-plan-record-stream reader
  -- stating it "needs a real seed-plan reader, which belongs beside the rest of the Swift ingress
  layer." A repo-wide sweep for `TargetSeedPlan|plan_handle` in `rust/` returned zero decode
  plumbing. Porting the verdict to Rust as §6.4's literal text suggested was therefore not available
  as written. This is the one place this slice takes a design-doc branch that isn't the doc's own
  literal text, per the task's own explicit allowance ("if a §6 branch condition lands on 'gate ships
  partial rather than silently relaxed', that is a legitimate outcome -- record it precisely").
  Resolution: the verdict logic -- `WorkspaceProjectedPathSearchIndex.init`'s guard chain, faithfully
  ported line-for-line, same order and conditions -- was extracted into a new Swift-only type,
  `WorkspaceSeededRootReplayVerdict.swift` (`WorkspaceSeededRootReplayValidator.evaluate(...)  ->
  WorkspaceSeededRootReplayVerdict`), with **zero `PathSearchIndex` dependency**: the verdict was
  always computed before any C-engine index was constructed, so the two were separable all along.
  This both honors §6.4's "port the verdict, not the object" spirit exactly and respects design
  §4.2's own rule that seed-plan decode stays Swift. `preparePendingSeededRoot` was rewired onto the
  new validator; `WorkspaceSeededRootReplayVerdictTests` pins agreement, corrupted-base-ordinal
  disagreement (RK-8's required corrupted-replay coverage), and snapshot-identity-mismatch
  disagreement. The second holder-#6 consumer, `installRootSeedSearchShadow`, was **not** ported at
  all: D-14's confirmation that `.recordsAndPathIndexes` was unreachable from any production caller
  made its sole reader, `buildAuthoritativeRootPathIndexes`, provably dead code -- deleted outright at
  c1, no verdict-equivalent needed because it never served a production purpose after P4-7b.

### 14.2 Zero-reference proof and guardrail hardening (c2)

A `file_search` sweep for every symbol c3 would delete (`PathSearchIndex`,
`WorkspaceSearchRootPathIndex`, `WorkspaceProjectedPathSearchIndex`,
`WorkspaceProjectedPathSearchShadowControl`, `WorkspacePathSearchOverlayHistory`,
`WorkspaceSearchRelativePathBase`'s `PathSearchIndex` dependency, `rootPathIndexes`,
`.recordsAndPathIndexes`, `requiresPathIndexes`, and the C engine's `path_search_*` symbols) surfaced
one holder not named by §6.5's original enumeration: `WorkspaceSearchRootQueryHandle.identity`
(`WorkspaceSearchRootQueryHandles.swift`) is typed `WorkspaceSearchRootPathIndexIdentity` -- a plain
three-field (`rootID`/`lifetimeID`/`topologyGeneration`) `Equatable, Hashable` struct originally
defined *inside* `PathSearchIndex.swift`. Rather than deleting it (its P4-7b b2 read facade is very
much alive), it was relocated verbatim -- same name, same three fields, same conformances -- into
`WorkspaceSearchRootQueryHandles.swift`, its one surviving production consumer.

`WorkspaceFileSearchIndexTimeToReadyBenchmarkTests.swift` was named by §6.5's original enumeration as
a deletion target; a direct symbol sweep of that file at c2's HEAD found **zero** references to any
symbol c3 deletes. It was left untouched rather than deleted -- the design doc's list predates
whatever later change already decoupled it, and deleting a 1106-line benchmark suite with no actual
dependency on the deleted types would have destroyed real, unrelated coverage for no reason. (One
real, `RPCE_BENCHMARK_TESTS`-flag-gated staleness inside that file *is* a genuine c3 consequence --
see §14.5.)

`Scripts/source_layout_guardrails.sh`'s P4-7b §4.1.0 section (item 10) was hardened from "the search
facade must never construct the type outside one DEBUG exception" to "the type and the C engine no
longer exist, period": the deleted files must never be reintroduced (existence check), the deleted
constructor name must never return (unchanged from P4-7b), and the deleted types'/functions' call
shapes -- constructor calls and C function calls, not bare type names, so that this file's and
`WorkspaceSeededRootReplayVerdict.swift`'s own deliberate doc-comment provenance references do not
trip the check -- must never reappear in `Sources/RepoPrompt`.

### 14.3 The atomic deletion (c3)

One commit (this one), after c1/c2 proved it safe:

- `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift` (1538 lines) --
  `PathSearchIndex`, `WorkspaceSearchRootPathIndexIdentity` (relocated, not lost -- §14.2),
  `WorkspaceProjectedPathSearchShadowControl`, `WorkspaceSearchRootPathIndex`,
  `WorkspacePathSearchOverlayHistory`/`WorkspacePathSearchOverlayHistoryMetrics`,
  `WorkspaceProjectedPathSearchIndex`.
- `Sources/RepoPromptC/src/Utils/path_search.c` (845 lines) and
  `Sources/RepoPromptC/include/path_search.h` (108 lines) -- the C engine `PathSearchIndex.swift`
  called through (`path_search_create`/`path_search_find`/`path_search_projected_find_cancellable`/
  etc.); `RepoPromptC`'s SwiftPM target has no explicit `sources:` list (glob-based), so no
  `Package.swift` edit was needed. The bridging header's `#include "path_search.h"` line was removed.
- `Sources/RepoPromptDomainRuntime/PathSearch/RustPathSearchProbe.swift` (44 lines) -- the
  differential-only Rust-seam probe that existed solely to drive `pathSearchFindV1` against the real
  C-backed `PathSearchIndex`; its parent directory is now empty.
- `WorkspaceSearchRelativePathBase` (`WorkspaceRootSeedModels.swift`) kept as a type, dropped its
  `index: PathSearchIndex` stored property -- confirmed via a repo-wide sweep that nothing ever read
  `.index`, only `.relativePaths`/`.stableOrdinals`/`.filenames`.
- `RootCatalogShard.pathSearchIndex: WorkspaceSearchRootPathIndex?` field deleted, along with every
  construction/consumption site: the shard-cache "promotion" path (`rootsNeedingPromotion`, dead
  since P4-7b b3 made `.recordsAndPathIndexes` unreachable), the patch path's
  `applyingPatch(...)`/`patchedPathSearchIndex`, `buildAuthoritativeRootPathIndexes`, and
  `composeSearchCatalogSnapshot`'s `preconditionFailure`-guarded unwrap.
- `WorkspaceSearchCatalogAccessRequirement` collapsed to a single case (`.recordsOnly`) --
  `.recordsAndPathIndexes` deleted outright (D-14's "unreachable" hardened to "does not compile"),
  `requiresPathIndexes` deleted. `WorkspaceSearchCatalogSnapshot.rootPathIndexes` and
  `recordsOnlyProjection()` deleted.
- `WorkspaceSwitchSearchIndexDiagnostics.swift`'s `snapshotPathIndexes` field and its
  `.recordsAndPathIndexes` switch case deleted (D-14 had named this file's switch as one reason
  deletion "costs more" at b3 -- that cost is paid here).
- `WorkspaceSearchService.authoritativeGlobalResultsForTesting` (the DEBUG-only ground-truth arm, the
  last Swift `PathSearchIndex` construction site) and its sole helper, `orderEntries`, deleted.
- Test files deleted outright (coverage superseded by the type's non-existence or already-landed
  Rust-side parity): `PathSearchIndexRecoveryTests.swift` (134 lines, C-engine test arm),
  `WorkspaceProjectedPathSearchTests.swift` (564 lines), `WorkspacePerRootPathSearchIndexTests.swift`
  (441 lines), `PathSearchRustSwiftDifferentialTests.swift` (372 lines),
  `WorkspaceSearchRustIndexKeyDifferentialTests.swift` (385 lines -- its Swift arm was
  `authoritativeGlobalResultsForTesting`; with no Swift arm left there is nothing to differential
  against).
- Test files split, not deleted wholesale (oracle-driven methods dropped, oracle-independent pins
  kept -- an oracle instantiating a live `PathSearchIndex` cannot survive the type's deletion, but
  the behavioral claims some of those tests carried do not depend on the oracle):
  `AgentFileTagSuggestionParityDifferentialTests.swift` (deleted
  `testResultSetAndOrderMatchesOracleSingleRootNoBindingProjection`,
  `testResultSetAndOrderMatchesPerRootOracleTwoRoots`,
  `testMultiRootFanOutIsASupersetOfThePreCutoverGlobalTruncation`, and the `oracle*` helpers; kept
  the limit-boundary tests, the byte-accounting test, and salvaged the oracle-independent §1.5 Check
  A `displayPath`-reconstruction assertion into a new standalone test,
  `testWorktreeBoundDisplayPathIsReconstructedFromRootName`) and
  `AgentContextFileBrowseSearchParityTests.swift` (c1's own new file -- deleted
  `testSearchResultsMatchPreRewriteOracleForAdmissibleAllRootScope` and its `oracleHaystack`/
  `oracleIndexedSearch` helpers; kept the empty-query and limit-boundary tests). Both deleted
  differentials' evidentiary value (proving the a3/c1 cutovers matched pre-cutover behavior
  result-for-result) was already captured at the time each landed and is preserved in git history and
  the respective commit messages; it is not re-derived here.
- `rootPathIndexes.isEmpty` assertions removed at their call sites (the field no longer exists) in
  `WorkspaceFileContextStoreTests.swift`, `WorkspaceCatalogShardTests.swift`, and
  `StoreBackedWorkspaceSearchTests.swift`; the fetches themselves were retained where they had a
  meaningful side effect (settling rebuild work later assertions inspect).

### 14.4 Drift register D-14/D-15 resolution

| ID | Status at P4-7c |
|---|---|
| D-14 | **Resolved.** `.recordsAndPathIndexes` and `rootPathIndexes` -- kept at b3 as "the lighter of §4.4's two options" because deletion touched `WorkspaceSwitchSearchIndexDiagnostics.swift`'s switch and internal shard-capability bookkeeping -- are both deleted at c3. That bookkeeping (`RootCatalogShard.pathSearchIndex`, the shard-cache promotion path, `composeSearchCatalogSnapshot`'s unwrap) is deleted in the same commit, so the cost b3 deferred is paid in full here, not carried forward. |
| D-15 | **Resolved, mechanically confirmed.** The seeded-root diff-replay self-check's projected-reuse-identity re-check was already removed at b3 (D-15's original entry); this slice replaces the self-check itself with the Swift-only `WorkspaceSeededRootReplayVerdict` (§14.1), which carries strictly more of the original guard chain (all fourteen disagreement reasons, faithfully ported) than the record-level assertions D-15 said remained as the sole coverage. `installRootSeedSearchShadow`, the other §D-15-adjacent projected-shadow consumer, is deleted outright (§14.1) rather than resolved by replacement, having been confirmed provably dead. |

### 14.5 Deferred items carried forward (named, not silent)

- **`WorkspaceFileSearchIndexTimeToReadyBenchmarkTests`'s `RPCE_BENCHMARK_TESTS`-gated
  `pathIndexBuild == 1`/`coldCounterVectorIsValid(counters, pathIndexBuild: 1)` assertions
  (`testLargeRepositoryTimeToReadyBenchmark`, around line 444/447) are now stale** -- they expect a
  full path-index build that can never happen post-c3. §13.4 predicted this exact spot ("likely
  P4-7c, when the harness's whole premise ... needs redesigning around what 'time to ready' means
  once the index no longer exists to build") and that larger redesign is confirmed, again, as out of
  this slice's scope: the flag is off by default (not compiled in `make dev-test`, so this is not a
  live gate failure), and "what does time-to-ready mean with no index to build" is a real design
  question, not a mechanical follow-up. Left as a named, not silently discovered, residual for
  whichever phase next touches that harness.
- **Live smoke deferred.** This slice's task explicitly withheld authorization for a visible app
  relaunch (`make dev-run`/live CE MCP smoke flow); §7's b4/a3/c3 rows all ask for it. Deferred, not
  skipped -- record explicitly rather than silently treated as discharged. The daemon-coordinated
  build/test/lint/guardrail gates below are the substitute evidence this pass provides.
- **SLO 100k tier / release-profile re-capture, D-13's post-flip re-measurement** -- unchanged from
  §13.4, still open, still out of this document's scope.

### 14.6 Validation matrix results (§7's c1/c3 rows)

- `make dev-swift-build PRODUCT=Agentry` -- green.
- `make dev-swift-build PRODUCT=agentry-mcp` -- green (confirms the C link succeeds after
  `path_search.c`'s removal).
- `make dev-lint` (format-check + SwiftLint strict) -- green.
- `make guardrails` -- green, including the hardened P4-7c c3 additions (§14.2).
- Full `make dev-test` -- green modulo the OI-1/OI-2 family, confirmed pre-existing and unrelated to
  every P4-7c change by direct bisection against `2f41e59f` (§12.5's P4-7c confirmation note, above).
  No other new failure surfaced across two independent full-suite runs.
- `make dev-cargo-test CARGO_PACKAGE=all` -- not run: no `rust/` file was touched by any P4-7c c1-c3
  change (holder #6 stayed Swift-only, §14.1), so the task's own conditional gate ("if you touch
  rust/") does not apply. `make guardrails` already confirms no FFI/codegen drift.
- Live CE MCP smoke flow -- deferred (§14.5): no visible app relaunch was authorized this slice.

P4-7's three phases (a: `2f41e59f`; b: §13 above; c: this section) are complete. No further P4-7
phase remains.
