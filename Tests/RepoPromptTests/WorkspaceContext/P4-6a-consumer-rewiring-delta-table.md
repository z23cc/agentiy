# P4-6a — Consumer rewiring onto the read surface: per-site delta table

Scope: `Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift`
only. No FFI, no cutover — Swift tables remain authoritative. Reference doc:
`docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` §4.3.1.1/§4.3.1.2;
`docs/architecture/rust-inventory-scope-v1.md` §5.3.

Gate: each rewired site's composed clause set is **identical** to its pre-refactor
form — same clauses, same order, same short-circuit, same per-clause failure
attribution. No site gains a clause it lacked; none of the six discoverability gaps
(PC-1..PC-6) is closed here.

## New read-surface primitives added

- `inventoryRecordFacts(fileIDs:folderIDs:)` — id-keyed, one call for both files and
  folders, live `rootStatesByID[record.rootID]` resolution. Facade for
  `appliedIndexRecordLookup`; also called directly by B1 sites 1, 2, 3, 5, 6, 7 and
  bucket A's whole-root scans.
- `inventoryFileRecordFacts(in:fileIDs:)` — id-keyed, state-scoped (caller-held
  `RootState` snapshot, not a live re-fetch). Used where the pre-refactor site
  validated against a `state` captured before an earlier `await` (site 4).
- `inventoryPathLookups(rootID:relativePaths:)` / `inventoryPathLookups(in:relativePaths:)`
  — path-keyed, one call for both file and folder path→ID resolution. Used by B3
  sites, path-keyed B1 sites (8, 9, 10, 11), and bucket C's manifest loop.
- `discoverableFileCount(in:)` / `discoverableFolderCount(in:)` — bucket C's O(1)-shaped
  aggregate call sites (see deviation below — call shape only, not incremental
  maintenance).
- `appliedIndexRecordLookup` is now a thin facade: unchanged signature, unchanged
  external behavior for its two non-B1 consumers (`AgentContextFileBrowseService`,
  `WorkspaceFilesViewModel`). DEBUG counters increment exactly once per call on every
  path (moved into the primitive; the facade's early-return branch increments
  directly so the "once per call" invariant survives the split).

## B1 sites (→ `inventoryRecordFacts` / `inventoryFileRecordFacts`, id-keyed)

| # | Site | Shape | R1 | R2 | R3 | R4 | R5 | Delta / notes | Named test |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `codemapAutomaticSelectionSourceIdentities` | sync | present (fact.record) | present (allowedRootIDs, unchanged, still a call-site read) | present (fact.pathRoundTripsToSelf) | present (fact.isDiscoverable) | n/a (never present) | Empty delta: one batched call before the `compactMap`, same clause order (R1,R2,R4,`state`-bind,R3,extra). | `testCodemapAutomaticSelectionSourceIdentitiesSkipsManagedOnlyFiles` |
| 2 | `codemapOperationPresentationCandidates` | sync, per-clause attribution | present | present | present | present | n/a | Empty delta across 2 occurrences (per-file guard + `includeCompleteRootCatalogs` whole-root scan, both hoisted to one batched call each). Per-clause issue attribution (`.fileNotCataloged` vs `.fileOutsideRootScope`) preserved verbatim. | `testCodemapOperationPresentationCandidatesServesManagedOnlyFile` |
| 3 | `resolveAutomaticCodemapSelection` | async, D-8 | present | present | present | present | n/a | Empty delta. Hoisted per-root, entirely before this iteration's first `await`; the pre-existing post-await recheck (`currentSession.engine === engine`, `currentSession.authority == session.authority`, root lifetime) is untouched — no new staleness window. | `testResolveAutomaticCodemapSelectionServesManagedOnlyFile` |
| 4 | `revalidateAutomaticCodemapSelection` | async, D-8, PC-1 gap | present | present | present | absent — preserved | n/a | Two occurrences (seed loop, target loop), both after this function's awaits, both against the same captured `state` the pre-refactor code used — state-scoped `inventoryFileRecordFacts(in:fileIDs:)`, not a live re-fetch. R4 stays absent (PC-1: managed-only files still served on re-selection). | `testRevalidateAutomaticCodemapSelectionServesManagedOnlyFile` |
| 5 | `requestCodemapArtifactWithOwnership` | async, no D-8 anchor, PC-2 gap | present (own `.rootNotLoaded` outcome, distinct from `.fileNotCataloged`) | via `rootStatesByID[file.rootID]` (own guard) | present | absent — preserved | dropped (tautological, same live read, no `await` between bind/compare — §4.3.1.1 result 2) | Two independent batch-of-one calls (no hoist across the `await resolveCodemapEligibility` in between) — matches the pre-refactor re-read-after-await shape. Second call's `currentFile == file` is the captured-operand form and is preserved, not dropped (`file` bound before the `await`). | `testRequestCodemapArtifactWithOwnershipServesManagedOnlyFile` |
| 6 | `queryCodemapStructureGraphs` | async, no D-8 anchor | present | present (allowedRootIDs) | present | present | n/a | Two occurrences: main seed-resolution loop (fully synchronous, hoisted safely) and an unguarded display read (`filesByID[$0]?.standardizedRelativePath` inside a later `.map`) — kept unguarded, routed through a fresh per-iteration batch call, no discoverability/round-trip filter added. | `testQueryCodemapStructureGraphsServesManagedOnlyFile` |
| 7 | `revalidateCodemapOperationPresentationForPublication` | async, D-8 | present | present | present | present | n/a | Two occurrences (`completeRootCatalogs` whole-root scan per catalog, `candidates` loop), both entirely before this function's only `await` (the trailing `revalidateAutomaticCodemapSelection` call) — no new staleness window. | covered by the non-gap negative test list below |

Path-keyed B1 sites (→ `inventoryPathLookups`, per §4.3.1.1 result 3 — these are
B3-mechanism sites wearing B1 clothing):

| # | Site | Shape | R4 | Delta / notes | Named test |
|---|---|---|---|---|---|
| 8 | `codemapManifestCandidate` | sync, PC-3 gap | absent — preserved | `rootStatesByID[rootEpoch.rootID]` existence dropped from the first guard: provably redundant, not just observationally equivalent — `codemapAuthorityIsCurrent(authority)` (already checked earlier in the same guard) implies `codemapAuthorityMatchesLoadedRoot`, which already requires that exact root state to exist, and `rootEpoch == authority.rootEpoch` is checked first. | `testCodemapManifestCandidateReturnsCandidateForManagedOnlyFile` |
| 9 | `acceptCodemapMarkerReadinessUpdate` | async, D-8, PC-4 gap | absent — preserved | Two occurrences (`securityExcludedPaths` compactMap, `for change in update.changes` loop), separated by an `await` (`engine.selectionGraph`/`graph.fenceFiles`). Two independent batched `inventoryPathLookups` calls, one per occurrence — the second is a fresh re-read after the `await`, matching the pre-refactor re-read-after-await shape exactly (this is the site's D-8 anchor: `requestGeneration == pathGeneration`). | `testAcceptCodemapMarkerReadinessUpdateAppliesManagedOnlyFileChange` |
| 10 | `readCodemapSource` | async, D-8, PC-5 gap | absent — preserved | Two occurrences (pre-await, post-await), both via `inventoryPathLookups(in:...)` against the `state`/`currentState` already bound at each point (unchanged — `state.service`/`.root` still needed there). Post-await pass is the pre-existing re-check this site already had. | `testReadCodemapSourceServesManagedOnlyFile` |
| 11 | `codemapDemandIsCurrent` | sync, PC-6 gap | absent — preserved | Empty delta. Split into two guards (path-shape/session checks, then one path-keyed batch-of-one call) — same short-circuit order, same Bool-only return (no attribution to lose). | `testCodemapDemandIsCurrentTrueForManagedOnlyFile` |

## B2 — whole-root projection (→ projected-shard pair + paged read)

| Site | Delta / notes |
|---|---|
| `codemapGraphIndexCatalogShardBuildSnapshot` (actor-isolated) + `buildCodemapGraphIndexCatalogShard` (`nonisolated static`, run inside `Task.detached` by `ensureCodemapGraphIndexCatalogShard`) | Not merged into one Swift function. Merging would collapse the actor-isolated/off-actor split the design calls out as essential (§4.3.1: "the sort/filter/projection work happens off the actor"; §5.2: this read "must not be serialized behind an in-flight authoritative rebuild"). Left as-is: a whole-root materialization with no per-item guard chain to route through a fact primitive. Documented together as this step's B2 read-shape boundary and the future `inventoryOpenProjectedShard` delegation point. Behavior unchanged. |
| `readCodemapGraphIndexCatalogPage` (async, D-8/D-11) | One batched `inventoryRecordFacts` call per page, hoisted before the `while` loop (fully synchronous to the end of the function — the earlier `await ensureCodemapGraphIndexCatalogShard` is strictly before this hoist point). `fact.record == file` preserves the D-11 captured-operand comparison (`file` is frozen into the shard behind that earlier `await`) — not dropped. `state.fileIDsByRelativePath[file.standardizedRelativePath] == file.id` (R3, checked against the captured file's own path) stays a direct read; the fact primitive's `pathRoundTripsToSelf` is keyed off the live record's path and is not a substitute for this specific clause. |

## B3 — path→ID fan-in (→ `inventoryPathLookups`)

| Site | Delta / notes |
|---|---|
| `destructiveCodemapGraphFence` | Empty delta. `rootStatesByID[rootID]` existence guard removed as a standalone early return; `inventoryPathLookups` returns empty fact maps for a missing root, every path then resolves to `fileID == nil`, `fileIDs` stays empty, function returns `nil` exactly as before — same output, reached via the shared empty-facts path rather than a dedicated guard (no discoverability filter added — this site never had one). |
| `retainCodemapRootStatusCoverageAcrossPathInvalidation` | Empty delta. Sync, no D-8 concern. `state` still read directly for the unrelated `lifetimeID` gate. |
| `codemapWatcherInvalidationCommands` | Not rewired — deviation, not an oversight. Its one tracked-table occurrence (`.folderRemoved` case) is `rootStatesByID[rootID]?.fileIDsByRelativePath.keys.filter { $0 == folderPath || $0.hasPrefix(folderPath + "/") }` — a prefix scan producing paths, not a point lookup producing an ID. `inventoryLookupPaths`'s fact contract (design §5.3) takes an explicit path list and returns per-path facts; it cannot express a "find all keys under this prefix" query without inventing new contract surface outside this step's remit. Left unchanged. Flagged for the reviewer/PC follow-up process, not silently absorbed into "B3 is 3 functions, 2 rewired." |

## Bucket C — `prepareSessionWorktreeOwnership` (§4.3.1.2)

| Occurrence | Delta / notes |
|---|---|
| Two whole-root aggregates (`authoritativeFileCount`, `authoritativeFolderCount`) | Call shape rewired to `discoverableFileCount(in: state)` / `discoverableFolderCount(in: state)`, called with the same captured `state` the pre-refactor code used (no live re-fetch — this branch runs after two `await`s, and using a fresh `rootStatesByID` lookup here would be an observable behavior change in what is deliberately a shadow/observation-only comparison). Deviation: these are **not** the O(1) incrementally-maintained counters §4.3.1.2 specifies. The Rust side maintains them at all 16 A2 mutation scopes with a counter-equals-traversal differential (P4-3a done-when); building the equivalent Swift-side incremental maintenance in this step, across 16 mutation sites, without that differential harness, trades a correctness risk (a missed decrement silently diverging the counter) for an optimization this step does not require (Swift already computes the traversal cheaply). What's rewired is the call shape only — `prepareSessionWorktreeOwnership` no longer inlines the traversal, so P4-6b's cutover replaces these two functions' bodies with a field read and touches no call site. O(1) incremental maintenance across the 16 A2 scopes plus its differential is explicitly outstanding, not done. |
| Per-record manifest loop (5 occurrences: `.ordinaryFile`, `.ordinaryDirectory`, `.policyIgnoredTrackedFile` cases) | Empty delta. The manifest reader is materialized into an array first (`manifestRecords`, `queriedPaths`), then one batched `inventoryPathLookups(in: state, ...)` call resolves the whole scan (one call per scan, not one call per record) — same disposition dispatch, same `matches` accumulation, same `state` (not a live rootID re-fetch, for the same shadow-comparison-freshness reason as the aggregates). | `testPrepareSessionWorktreeOwnershipShadowComparisonMatchesManifestAgainstBatchedLookup` |

## Non-gap negative tests (managed-only file must NOT be served — pins the reference predicate's R4 clause is still applied)

Sites 1, 2, 3, 6, 7 all still apply R4 (discoverability) unchanged. One negative test per
site confirms a managed-only file is excluded exactly as before:

- `testCodemapAutomaticSelectionSourceIdentitiesSkipsManagedOnlyFiles` (site 1)
- `testCodemapOperationPresentationCandidatesExcludesManagedOnlyFile` (site 2)
- `testResolveAutomaticCodemapSelectionExcludesManagedOnlyFile` (site 3)
- `testQueryCodemapStructureGraphsExcludesManagedOnlyFile` (site 6)
- `testRevalidateCodemapOperationPresentationForPublicationDetectsStaleManagedOnlyCatalog` (site 7)

## D-8 finding

Across all 8 async sites reachable through this rewiring (7 B1 + B2's
`readCodemapGraphIndexCatalogPage`), no site's hoist opens a new staleness window:

- Sites 3, 7: every table read is strictly before the function's only `await`.
- Sites 5, 6: no hoist across an `await` at all — batch-of-one / fresh-per-iteration
  calls exactly where the pre-refactor code read the tables.
- Sites 4, 9, 10, and B2's page read: the hoisted call is re-issued fresh on each
  side of the relevant `await`(s), piggybacking on each site's own pre-existing
  post-await re-check (session/engine identity, root lifetime, `requestGeneration ==
  pathGeneration`, or the D-11 captured-record comparison) — none of which this step
  altered.

Every D-8 "test" is therefore pinning a pre-existing re-check, not a new one this
step introduces. Test coverage for the two gap sites among these (4, 9, 10) is
supplied by their gap tests above, which exercise the full path including the
post-await re-check.

## Diagnostics instrumentation (`appliedIndexRecordLookupDiagnosticsForTesting`)

Counters moved from `appliedIndexRecordLookup` into the shared primitives
(`inventoryRecordFacts`, `inventoryFileRecordFacts`, `inventoryPathLookups`), so the
diagnostic now reflects every fact-returning call, not just facade calls — the
per-scan call shape this step's done-when asks the four consumer test files to
observe. Empirically verified before and after rewiring (baseline captured prior to
any edit):

| Test file | Before | After |
|---|---|---|
| `WorkspaceFileContextStoreTests` | 135 tests | 135 tests, identical assertions |
| `AgentContextFileBrowseServiceTests` | 12/12 | 12/12, identical counts |
| `AgentContextFileBrowseModelTests` | 23/23 | 23/23, identical counts |
| `WorkspaceFilesAppliedIndexProjectionTests` | 16/16 | 16/16, identical counts |

None of these four files' test scenarios exercise the rewired codemap B1/B3 sites
(no codemap session is ever established in their fixtures), so no asserted count
moved. All four files were still touched — a doc comment was added at each
`appliedIndexRecordLookupDiagnosticsForTesting` call site recording that the counters
now aggregate across all fact-returning call sites, not only `appliedIndexRecordLookup`,
and that this was verified empirically rather than assumed.
