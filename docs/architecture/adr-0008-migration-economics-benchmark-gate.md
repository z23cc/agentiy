# ADR-0008: Migration-Economics Gate — Benchmark-Gated Production Cutover

**Status:** Accepted as a standing gate (charter §15.3 item 3); first exercised P3-2c (2026-08-22), verdict DEFER

**Date:** 2026-08-20 (gate ruling), 2026-08-22 (first exercised verdict)
**Decision owner:** Charter (standing rule); orchestrator applies per-domain, user retains override

## Context

Charter §15.3 requires every domain to clear a performance SLO gate before production cutover: freeze the existing Swift baseline on a fixture, then register an absolute SLO and allowed delta *before* looking at the Rust candidate's results — the ordering exists specifically to prevent post-hoc SLO-shopping once a disappointing number is in hand. This ADR records that this is a real, load-bearing gate: a domain can be fully ported, fully parity-tested, and still be correctly *rejected* for production cutover on economics alone.

## Decision

1. **The benchmark gate can veto cutover independent of correctness.** A domain that passes every parity/correctness test can still be deferred from production cutover if it fails its registered performance SLO. Passing parity is necessary but not sufficient.
2. **First exercised instance: P3-2c inventory cutover, verdict DEFER.** An env-gated benchmark (`RP_RUN_INVENTORY_CUTOVER_BENCHMARK`) compared the Swift `WorkspaceInventoryCatalogBuilders` against the Rust seam at realistic scale (1k–100k files). Authoritative (full-table) builds: Rust 1.2–1.5× slower — inside tolerance. **Incremental patch paths: Rust 50–80× slower at 10k–100k scale** (merge path 22× slower); whole-table encode + FFI round-trip + decode dominates the cost of a single mutation. The charter's benchmark gate triggered decisively: production cutover was deferred, not the port abandoned.
3. **Stateful-handle precondition for retrying the gate.** The verdict is not "Rust inventory is too slow, full stop" — it identifies the specific structural cause (per-call whole-table round-trip) and names the precondition for revisiting cutover: the workspace-authority migration (Phase 4/5) must put the tables on the Rust side of the boundary so incremental mutations no longer round-trip the full table across FFI on every call. Until that stateful-handle precondition exists, re-running the same benchmark would predictably fail the same way.
4. **The differential/parity test suite is retained as a standing contract regardless of the DEFER verdict.** The 17-test hard-assertion differential built for P3-2c stays in the suite; a deferred cutover does not mean the Rust port work or its tests are discarded.
5. **The precedent generalizes.** A later domain (P3-3 slice 2b phase 2, path-search) explicitly deferred its own production wiring and old-implementation deletion to the same P4 stateful-handle milestone, citing this economics ruling rather than re-deriving it — establishing that "defer production wiring until the stateful-handle precondition lands" is the expected response pattern, not a one-off decision specific to inventory.

## Consequences

- Domains with hot incremental-mutation paths (workspace inventory, path search, and likely others touching the same per-call round-trip shape) should expect to defer production cutover until Phase 4/5 lands a stateful Rust-side handle, and should plan benchmark gates accordingly rather than being surprised by a late DEFER.
- A DEFER verdict is not a rollback signal under ADR-0006 (no per-domain cutover has happened yet at that point) — it is a pre-cutover gate result, and the Swift implementation remains authoritative and untouched until the precondition is met and the gate is re-run.
- Future domains citing this ADR to defer their own cutover must still register their own fixture/SLO pair per charter §15.3 item 3 — this ADR establishes the *pattern* (benchmark before commit, structural-cause diagnosis over blanket rejection, named precondition to retry), not a blanket exemption.

## Evidence

- P3-2c benchmark verdict (DEFER, 1.2–1.5× authoritative / 50–80× incremental / 22× merge): `57545bfa7a0c86106531e9cf37a00d51d93a7419`.
- Precedent cited for deferred production wiring in path-search (P3-3 slice 2b phase 2): `a756190d` (tracker log, 2026-08-22).
- Charter: `docs/architecture/agentry-rewrite-charter.md` §15.3 item 3.
