# ADR-0008: Migration-Economics Gate — Benchmark-Gated Production Cutover

**Status:** Accepted as a standing gate (charter §15.3 item 3); first exercised P3-2c (2026-08-22), verdict DEFER; **stateful-handle precondition discharged and re-exercised P4-6b (2026-08-22/23), verdict GO** — see Update below.

**Date:** 2026-08-20 (gate ruling), 2026-08-22 (first exercised verdict), 2026-08-23 (P4-8 update: precondition discharge, predecessor retirement)
**Decision owner:** Charter (standing rule); orchestrator applies per-domain, user retains override

## Context

Charter §15.3 requires every domain to clear a performance SLO gate before production cutover: freeze the existing Swift baseline on a fixture, then register an absolute SLO and allowed delta *before* looking at the Rust candidate's results — the ordering exists specifically to prevent post-hoc SLO-shopping once a disappointing number is in hand. This ADR records that this is a real, load-bearing gate: a domain can be fully ported, fully parity-tested, and still be correctly *rejected* for production cutover on economics alone.

## Decision

1. **The benchmark gate can veto cutover independent of correctness.** A domain that passes every parity/correctness test can still be deferred from production cutover if it fails its registered performance SLO. Passing parity is necessary but not sufficient.
2. **First exercised instance: P3-2c inventory cutover, verdict DEFER.** An env-gated benchmark (`RP_RUN_INVENTORY_CUTOVER_BENCHMARK`) compared the Swift `WorkspaceInventoryCatalogBuilders` against the Rust seam at realistic scale (1k–100k files). Authoritative (full-table) builds: Rust 1.2–1.5× slower — inside tolerance. **Incremental patch paths: Rust 50–80× slower at 10k–100k scale** (merge path 22× slower); whole-table encode + FFI round-trip + decode dominates the cost of a single mutation. The charter's benchmark gate triggered decisively: production cutover was deferred, not the port abandoned.
3. **Stateful-handle precondition for retrying the gate.** ~~The verdict is not "Rust inventory is too slow, full stop" — it identifies the specific structural cause (per-call whole-table round-trip) and names the precondition for revisiting cutover: the workspace-authority migration (Phase 4/5) must put the tables on the Rust side of the boundary so incremental mutations no longer round-trip the full table across FFI on every call. Until that stateful-handle precondition exists, re-running the same benchmark would predictably fail the same way.~~ **DISCHARGED (P4-6b, `fe14d61e`) — see Update below.**
4. ~~**The differential/parity test suite is retained as a standing contract regardless of the DEFER verdict.** The 17-test hard-assertion differential built for P3-2c stays in the suite; a deferred cutover does not mean the Rust port work or its tests are discarded.~~ **SUPERSEDED (P4-8) — see Update below.**
5. **The precedent generalizes.** A later domain (P3-3 slice 2b phase 2, path-search) explicitly deferred its own production wiring and old-implementation deletion to the same P4 stateful-handle milestone, citing this economics ruling rather than re-deriving it — establishing that "defer production wiring until the stateful-handle precondition lands" is the expected response pattern, not a one-off decision specific to inventory. **P4-7 (the path-search production-wiring + `path_search.c` deletion step this item names) has not landed as of this update — this item's precedent still stands but its own discharge is a separate, not-yet-reached event.**

## Update (P4-8, 2026-08-23): precondition discharged, predecessor retired

1. **Item 3's stateful-handle precondition is discharged.** P4-6b (`fe14d61e`, "THE SWAP: Rust InventoryScope becomes sole workspace inventory authority") put the workspace-inventory tables on the Rust side of the FFI boundary via the stateful `InventoryScope` primitive (`docs/architecture/rust-inventory-scope-v1.md`), exactly the precondition item 3 named. Incremental mutations no longer round-trip the full table across FFI per call.
2. **The gate has been re-run in the form the precondition predicted: a registered-before-candidate-existed SLO (`rust/benchmarks/slo-v1.json`'s `inventoryScopeV1` block, registered at P4-1) with a GO verdict (`p4TwoResults`: E-1's kill criterion, E-1c, E-1d, E-3, E-4 pass; `p4FourResults`: P4-4's partial E-2 re-run).** This is the re-run item 3 anticipated, not a fresh unrelated gate.
3. **Item 4 is superseded, not merely retained-then-dropped.** The 17-test differential's retention rationale in 2026-08-22 was "the Rust port may still cut over through this whole-table seam, so keep its parity contract live." That premise no longer holds: the seam itself (`inventory-compute-v1`) is retired, superseded by `inventory-scope-v1`, so a differential exercising it would be testing a bridge that no longer exists. Retired in the same step:
   - `Sources/RepoPromptDomainRuntime/Inventory/RustInventoryComputer.swift` (the Swift FFI scaffold)
   - `Sources/AgentryCoreBridge/CoreInventory.swift`'s `CoreComputeClient` extension, `CoreRuntimeTransport.inventoryComputeV1` default, and the `inventory-compute-v1` compact-wire mirrors (types shared with `inventory-scope-v1`, e.g. `CoreInventoryFileRecordV1` and the UUID<->word helpers, were kept)
   - `Sources/AgentryCoreBridge/CoreBridge.swift`'s `inventoryComputeV1` protocol requirement and implementation
   - `rust/crates/ffi/src/api.rs`'s `inventory_compute_v1` export and `inventory_service` field; `rust/crates/ffi/src/types.rs`'s `CoreInventoryComputeRequestV1`/`ResultV1`/`CoreInventoryTableRangeV1`; `rust/crates/ffi/src/errors.rs`'s `InventoryComputeError` mapping (the three `CoreError::Inventory*` wire variants are left in place, unconstructed, as an ABI-epoch decision rather than pruned incidentally)
   - `rust/crates/runtime/src/inventory/compact.rs` and `contract.rs` (the whole-table wire codec; `builders.rs`/`ordering.rs` remain, reused verbatim by `InventoryScope`)
   - `Tests/RepoPromptTests/WorkspaceContext/InventoryRustSwiftDifferentialTests.swift` (the 17-assertion differential) and its paired `InventoryCutoverBenchmarkTests.swift` (this ADR's own `RP_RUN_INVENTORY_CUTOVER_BENCHMARK` harness, item 2's evidence source)

   One documented behavioral boundary from that differential — `folder_order`'s raw-UTF-8-byte vs. Swift-Unicode-canonical-equivalence divergence on precomposed/decomposed folder names — had no other test pinning it, since the functions it exercises (`build_authoritative_catalog_components`, `ordering::folder_order`) remain live. It is re-pinned Rust-side as `inventory::ordering::tests::folder_order_diverges_from_swift_unicode_canonical_equivalence`, converting that one assertion into a Rust-side golden per this design's own P4-8 done-when framing, rather than being dropped when the Swift differential was deleted.
4. **Not discharged by this update, and not claimed to be:** `WorkspaceInventoryCatalogBuilders` (the Swift reference implementation) remains production-authoritative and undeleted; the remaining 16 of the 17 differential assertions were not individually converted to Rust-side goldens (only the one boundary with no other coverage was); the Tier-3 (`inventoryExportCompactV1`) zero-call-site assertion is gated on P4-7, which has not landed. These remain open P4-8 done-when items for a later step.

## Consequences

- Domains with hot incremental-mutation paths (workspace inventory, path search, and likely others touching the same per-call round-trip shape) should expect to defer production cutover until Phase 4/5 lands a stateful Rust-side handle, and should plan benchmark gates accordingly rather than being surprised by a late DEFER.
- A DEFER verdict is not a rollback signal under ADR-0006 (no per-domain cutover has happened yet at that point) — it is a pre-cutover gate result, and the Swift implementation remains authoritative and untouched until the precondition is met and the gate is re-run. Once the precondition is met and the gate re-run GO, as here, the predecessor seam and its differential/benchmark apparatus are the right things to retire, not indefinitely-retained parallel machinery.
- Future domains citing this ADR to defer their own cutover must still register their own fixture/SLO pair per charter §15.3 item 3 — this ADR establishes the *pattern* (benchmark before commit, structural-cause diagnosis over blanket rejection, named precondition to retry), not a blanket exemption.

## Evidence

- P3-2c benchmark verdict (DEFER, 1.2–1.5× authoritative / 50–80× incremental / 22× merge): `57545bfa7a0c86106531e9cf37a00d51d93a7419`.
- Precedent cited for deferred production wiring in path-search (P3-3 slice 2b phase 2): `a756190d` (tracker log, 2026-08-22).
- Precondition discharge: P4-6b cutover, `fe14d61e` ("THE SWAP: Rust InventoryScope becomes sole workspace inventory authority").
- Re-run gate evidence: `rust/benchmarks/slo-v1.json`'s `inventoryScopeV1`, `p4TwoResults`, and `p4FourResults` blocks; `rust/benchmarks/results/v1/p4-2-inventory-scope-derisking-v1.{md,json}`.
- Predecessor retirement: this update (P4-8, 2026-08-23).
- Charter: `docs/architecture/agentry-rewrite-charter.md` §15.3 item 3.
