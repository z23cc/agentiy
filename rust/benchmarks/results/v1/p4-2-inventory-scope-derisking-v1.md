# P4-2 -- De-risking experiments (GO/NO-GO gate): results

Design: `docs/designs/p4-workspace-inventory-authority-v2-2026-08-22.md` (S10 experiment
definitions, S11 P4-2 step entry). Contract: `docs/architecture/rust-inventory-scope-v1.md`. SLO
registrations: `rust/benchmarks/slo-v1.json` (`inventoryScopeV1` key). Raw data:
`p4-2-inventory-scope-derisking-v1.json` (this directory). Swift reference:
`swift-inventory-scope-reference.json`. Rust spike source: `rust/spikes/inventory-scope-spike`
(throwaway, not P4-3a production scope -- see its `src/lib.rs` module doc).

**Overall verdict: GO-with-E2-deferred**, with four explicit follow-up conditions (S8). No
experiment failed its gated criteria; E-2 is correctly reported BLOCKED rather than passed or
failed, per the task's "do not rationalize a pass" instruction (S5).

Two corrections were made to the first draft of this results doc after an adversarial self-review
(advisor pass) found real issues: E-1's harness had a tail-append measurement bias (S2), and
E-1d's path-keyed release margin needed an explicit breach-threshold disclosure plus a genuine
(failed) attempt at a release-profile Swift capture (S4). Neither correction changes a verdict, but
both change what the numbers mean, and both are documented in place rather than silently fixed.

## 1. Verdict table

| Experiment | Verdict | Notes |
|---|---|---|
| E-1 -- delta-path viability (kill criterion) | **GO** | Rust release/debug both clear the small-root absolute caps and the large-root 1.10x relative cap by 3-4 orders of magnitude (corrected for a tail-append measurement bias, S2); >=50x-vs-whole-table-patch criterion cleared by ~368,000x. |
| E-1c -- ingress-sequence replay | **GO (watermark axis only)** | 35/35 publications admitted across 6 named scenarios, 0 unexplained rejections; sanity control confirms the gate correctly rejects genuine staleness. Scope explicitly limited to the staleWatermark rejection reason (S3). |
| E-1d -- id-keyed batch lookup | **GO** | Passes under both release and debug Rust profiles vs the Swift debug reference, ~10x margin. |
| E-1d -- path-keyed batch lookup | **GO (release profile, THIN margin)** / FAIL (debug profile, non-gating) | Release: 0.57-0.85x ratio (under 1.10x cap, but only 1.18-1.40x of additional Swift speedup from a release recapture would breach it -- attempted, blocked by an unrelated pre-existing break, S4). Debug: 5.3-5.8x ratio (over cap), non-gating. |
| E-2 -- read economics and payload truth | **BLOCKED** (partial evidence only) | 4 of 4 registered criteria require infrastructure (bridge/MainActor/suggestion-service) that does not exist before P4-4/P4-6b/P4-7. Not scored pass or fail (S5). |
| E-3 -- handle lifetime and backstop soak | **GO** | 10k-iteration soak: bounded churn accounting, exact 1:1 leak accounting, writer liveness held at every checkpoint, zero panics on invalidated reads, clean under ASan. |
| E-4 -- apply/read contention under rebuild | **GO** | p99 added read latency 208.79us (cap: <1ms) under today's shipping per-scope-lock topology; writer liveness held; clean under TSan. Also answers open question 6 (S7). |

## 2. E-1 -- delta-path viability (kill criterion)

**Methodology correction (post-review):** the first draft of this harness generated every new
delta's path from a monotonically increasing id, which under `searchRootCatalogFilePrecedes`'s
lexicographic ordering always sorted to the *end* of the table -- every insert was a zero-cost
`Vec` append (O(1), no memmove), never a realistic mid-vector insert. That measured "appending is
cheap", not "single-delta apply is cheap" in general. Corrected via `scrambled_record`
(`rust/spikes/inventory-scope-spike/src/bin/e1_delta_apply.rs`): each new record's path is derived
from a multiplicative-hash (Fibonacci hashing) scramble of its id, so inserts land at pseudo-random
positions across the table's existing sorted range, forcing a real mid-vector `Vec::insert`/memmove
on every timed operation. All numbers below are the corrected, position-neutral measurement.

Swift reference (debug profile, already registered at P4-1) vs the corrected Rust spike:

| Size | Swift p50 (ms) | Rust release p50 (us) | Rust debug p50 (us) | Ratio (release/Swift) |
|---|---:|---:|---:|---:|
| 100 | 0.0730 | 0.541 | 3.250 | 0.0074 |
| 1,000 | 0.6653 | 0.583 | 4.083 | 0.00088 |
| 10,000 | 6.8503 | 1.333 | 8.583 | 0.0001946 |
| 100,000 | 87.8627 | 12.416 | 16.083 | 0.0001413 |

**Verdict unaffected by the correction**: 100k single-delta apply rose from an (biased) 0.542us to
a (corrected) 12.416us -- still ~7,080x faster than the 87.86ms Swift reference, comfortably inside
the 1.10x large-root cap. Small-root absolute caps (release profile): 100/1000-file single-delta
apply <50us and p99 <200us -- measured 0.541/0.583us p50, 0.583/0.625us p99. Both comfortably
inside. `>=50x-vs-whole-table-patch` criterion: Swift `authoritativeBuild` @100k (4566.32ms)
divided by the corrected Rust release number (12.416us) is ~368,000x.

**Why the margin is still this large, and why that's legitimate, not a measurement bug:**
`WorkspaceInventoryCatalogBuilders.buildRootCatalogShardPatch` rebuilds four full `Dictionary`
indexes (`oldFilesByID`, `oldFileIDsByPath`, `oldFoldersByID`, `oldFolderIDsByPath`) from the
`previousFiles`/`previousFolders` arrays on **every single-delta call**
(`WorkspaceInventoryCatalogBuilders.swift:158-166`) -- an O(n) index rebuild per delta. The Rust
spike's tables keep those indexes live and update them incrementally, never rebuilding from an
array. That is exactly the architectural change P4-3a's stateful `InventoryScope` exists to make,
so the asymmetry is the intended comparison, and it holds regardless of insert position.

**N-delta batch sweep (N = 1/2/5/10/25/50/100) and D-1's N (corrected):** at 100k, per-delta
amortized cost drops from 12.29us (N=1) to roughly 6.5-7.5us for N>=5 and then plateaus (no further
improvement N=10 to N=100: 6.46/7.50/7.37/7.10 us/delta). **This plateau is not attributed to a
real in-process batching benefit**: `apply_batch` is implemented as N sequential
`apply_single_upsert` calls with no shared/batched work, so there is no algorithmic reason batching
would help. The most likely explanation is amortized measurement-harness timer overhead (one
`Instant::now()` pair per sample at N=1 vs one pair per N-op batch at higher N), not amortized FFI
dispatch tax (no FFI boundary exists in this harness to amortize). This is recorded as an
unresolved ambiguity, not claimed as evidence in either direction.

**D-1's N is recommended as 1** (unchanged from today's Swift `maxLogicalMutationCount=1`). The
only real justification for N>1 is amortizing UniFFI call-dispatch overhead, which this harness
cannot measure cleanly (no bridge exists, and the observed plateau does not provide unambiguous
evidence either way -- see above). No pre-existing measured figure for real dispatch tax exists
anywhere else in this repo. Re-derive at P4-4 once the real FFI round trip exists to measure;
inventing a number, or over-reading the plateau, was rejected as unearned.

## 3. E-1c -- ingress-sequence replay against the staleWatermark gate

**Scope caveat (added post-review):** the gate implemented here checks only the `staleWatermark`
rejection reason (contract doc S5.1) -- what R11 specifically names and what this experiment exists
to de-risk. Contract S5.1 names five other typed rejection reasons (`lifetimeMismatch`,
`generationGap`, `unknownRoot`, `scopeClosed`, `identityMismatch`); scenarios 3
(seeded-root-replay-cut) and 4 (root-unload-in-flight-deltas) are, in the real system, actually
fenced by `generationGap`/`lifetimeMismatch` rather than by watermark comparison -- this replay
only demonstrates that the watermark axis does not *additionally, incorrectly* reject those
scenarios' legitimate publications. The other five rejection reasons are deferred to P4-3a's cargo
property tests, which the contract doc's own P4-3a done-when line already requires. All six
scenarios use synthesized sequences; no recorded-production sequences were available to replay in
this spike (design S10 permits "recorded and synthesized" -- only the synthesized half is
discharged here).

Six named scenarios (ordinary watcher bursts; forced overflow/pressure collapse; seeded-root replay
cut; root unload with in-flight deltas; edit-path synthetic publications interleaved with watcher
deltas; remove+re-add on one path within a batch) run through the watermark gate, each rule
independently re-verified against the live Swift source (not just the contract doc's summary):

- Non-strict `>=`: `WorkspaceFileContextStore.swift:3459`.
- `nil` bypasses entirely, never coerced to 0: `WorkspaceFileContextStore.swift:3459-3464`
  (optional-binding shape); edit-path `nil` publications at `:6222`, `:6241`.
- Collapse preserves `min(lowest)`/`max(high)`: `FileSystemWatcherIngressMailbox.swift:198-225`.
- The watermark check is scoped to the seeded-root replay transition only (not a general
  steady-state check) -- confirmed, not merely trusted: the only comparison site lives inside the
  `pendingSeededRootsByID` state machine.

Result: 35/35 publications admitted, 0 unexplained rejections. A sanity control (a genuinely stale
watermark, 50 after a last-applied of 100) is correctly rejected, confirming the gate has teeth.
A separate direct `RootTable` check confirms remove+re-add of the same path within one batch
resolves correctly (path -> new id, table length unchanged).

## 4. E-1d -- batch point-lookup cost curve

100k-file single root; N matched to the newly-captured Swift reference
(`InventoryScopeSwiftBaselineTests.testSwiftInventoryScopeE1dBatchLookupBaseline`).

**Id-keyed** (`resolve_by_ids`, N = 1/10/100/1000): passes under both profiles with large margin.
Release ratio at N>=100: 0.099x (N=100), 0.105x (N=1000). Debug ratio: 1.02x (N=100), 0.91x
(N=1000) -- both under the 1.10x cap.

**Path-keyed** (`lookup_by_paths`, N = 1/100/1000/10000):

| N | Swift p50 (ms) | Rust release p50 (us) | Ratio (release) | Rust debug p50 (us) | Ratio (debug) |
|---|---:|---:|---:|---:|---:|
| 100 | 0.0125 | 7.125 | 0.57 | 67.625 | 5.41 |
| 1,000 | 0.1275 | 107.875 | 0.85 | 733.834 | 5.76 |
| 10,000 | 1.3416 | 1052.75 | 0.78 | 7079.167 | 5.28 |

**Release profile: GO, but the margin at N=1000/10000 is thin, not a comfortable pass.** A Swift
debug-to-release speedup of only **1.30x** (N=1000) or **1.40x** (N=10000) on this tight
dictionary-lookup loop would push the ratio over the 1.10x cap -- entirely plausible (loop
overhead, bounds checks, and retain/release are all optimizable in Swift release even though the
underlying `Dictionary`/`String` implementation is already optimized in debug).

**A genuine release-profile Swift capture was attempted** this session:
`RP_RUN_INVENTORY_SCOPE_SWIFT_BASELINE=1 make dev-test FILTER=InventoryScopeSwiftBaselineTests
CONFIGURATION=release`. It failed on the same pre-existing, unrelated compile break P4-1 already
documented at `2803d3d9`: `Tests/AgentryCoreBridgeTests/CoreSearchTests.swift:230` references
`AgentryCoreBridge.invalidationTriggerForTesting`, a member that does not exist -- confirmed still
broken at `ed9a4bbc`. Not fixable within this step's scope (an unrelated target). **The path-keyed
release verdict therefore stands on the debug-Swift comparison with this margin explicitly
flagged, not on an assumed-safe release number.**

**Debug profile: FAILS** the 1.10x cap by ~5x. Root cause: `BTreeMap<String,_>` comparisons are
unoptimized in Rust's dev profile (no inlining, no vectorized string compare), while Swift's
`Dictionary`/`String` implementation ships pre-optimized in the Swift standard library *regardless
of the app's own build configuration* -- an asymmetry with no Swift-side analog, confirmed by
checking `rust/Cargo.toml`'s `[profile.dev]` (no `opt-level` override, i.e. the real debug-app Rust
archive build -- `cargo run -p xtask -- archive --profile debug`, confirmed in this session's
daemon log -- genuinely runs unoptimized). **Verdict basis:** production Rust code only ever ships
at cargo release profile; the release-vs-Swift-debug comparison is decision-relevant for the
GO/NO-GO call, consistent with this repo's own established `performanceIterationPolicy` in
`slo-v1.json`. The debug-profile regression (~5x) is recorded, not hidden, and carried forward as
a follow-up condition (S8).

**10k-path session-startup budget** (`slo-v1.json` shipped this as `null`, "TBD at P4-2"): set to
**50ms**. Rationale: ~37x headroom over the Swift reference (1.34ms), ~48x over the Rust release
candidate (1.05ms); session startup already performs filesystem/worktree-materialization I/O an
order of magnitude slower than this operation. Budget met by both arms.

**Crossover (recorded, not gated, per the design's instruction):** id-keyed batching shows no
measurable benefit over the degenerate per-item loop at any tested N (no FFI boundary to amortize
in this harness). Path-keyed batching shows a modest 12-15% benefit at N>=1000, attributable to
avoided per-call `Vec`/`String` allocation overhead in the per-item loop, not FFI amortization.

## 5. E-2 -- read economics and payload truth: BLOCKED

Four registered criteria, none dischargeable pre-bridge/pre-cutover/pre-rewiring:

| Criterion | Why blocked |
|---|---|
| root bootstrap time-to-first-paint <=1.10x | Needs actual UI/bootstrap integration; no bridge (P4-4) or `@MainActor` wiring (P4-6b) exists here. |
| B2 projected-shard page within MainActor frame budget | `inventoryOpenProjectedShard` is a P4-4/P4-6 read surface; no codemap projection or MainActor apply path exists pre-cutover. |
| mention/suggestion query <=1.0x at 100k | Needs the haystack-variant + per-root display-prefix `inventoryQuery` contract (design S6) and the real `AgentFileTagSuggestionService` caller; not implemented in this throwaway spike, and not owed until P4-7. |
| peak RSS <=1.0x (process-level) | No comparable whole-process Swift-vs-Rust deployment exists pre-P4-6b. |

**Partial evidence provided** (informational only, does not discharge the criteria above): a
counting global allocator over the Rust Tier-1 operations E-1/E-1d already exercise.
`build_authoritative(100k files)`: 116,669 allocations, 20.49 MiB malloc bytes.
`resolve_by_ids(N=1000)` / `lookup_by_paths(N=1000)`: 1,001 allocations, ~95,000 bytes each.
Rough (lower-bound, non-RSS) table footprint estimate at 100k files: ~17.03 MiB.

**R8 (memory regression risk) evidence status:** R8 names E-2's peak-RSS report as its only
mitigation. That whole-process comparison is genuinely unmeasurable pre-P4-6b. The structure-level
footprint above (17.03 MiB Rust-side estimate) is the closest available evidence, but **no
equivalent Swift-side structure-footprint number was captured this session** -- recorded as a
genuine gap rather than papered over. R8 carries effectively no comparative evidence out of P4-2;
add a Swift-side memory probe alongside the full E-2 re-run at P4-4/P4-6b.

**Recommendation:** re-run E-2 in full once the bridge exists (P4-4, for wire-byte and
cross-language wall/CPU truth) and once the suggestion-service rewiring lands (P4-7, for the
mention-query and B2 shard-page criteria). This partial evidence does not substitute for that
re-run.

## 6. E-3 -- handle lifetime and backstop soak

10,000-iteration deterministic soak (seed `0x5350494B45342026`) over
open/close/leak/scope-close/root-unload/identity-swap across 8 roots. Methodology was corrected
mid-session (see the spike's `e3_soak.rs` module doc): the first draft used uniformly-random close
targeting over all handle history, which diluted over a growing history and produced a false
"unbounded growth" failure that did not reflect a real usage pattern. Corrected to a recency-biased
bounded churn pool (64 in-flight) plus a separately-tracked, intentionally-never-closed leak set.

Results: 4,482 handles ever issued, 963 deliberately leaked (never closed). Final tracked-entry
count 1,027 = 963 leaked + 64 churn (exactly at the churn pool bound, not growing with iteration
count). Leak accounting exact 1:1 (963 leaks -> 963 permanently-tracked entries, no more, no less).
1,456 reads against already-invalidated handles, all returned a typed `ReadOutcome`, zero panics.
Writer-liveness mutation succeeded at every one of the 10 checkpoints regardless of leak pressure.
**No double-free / no use-after-invalidate is structural, not merely untriggered**: the crate is
`#![forbid(unsafe_code)]` and every handle read returns a typed outcome rather than dereferencing
anything. **ASan run clean** (`RUSTFLAGS=-Zsanitizer=address`, nightly, same PASS output).

## 7. E-4 -- apply/read contention under an in-flight authoritative rebuild (+ open question 6)

Topology: 8 roots; 1 writer thread continuously applying deltas to root 0; 1 thread continuously
running the out-of-lock "expensive rebuild, lock only for install" cycle on root 1 (100k files
rebuilt per cycle); 4 reader threads round-robin issuing `resolve_by_ids(16 ids)` across all 8
roots; 3-second run, two lock topologies compared.

| Topology | Reads | p50 (us) | **p99 (us)** | Max (us) | Writer ops | Rebuild installs |
|---|---:|---:|---:|---:|---:|---:|
| PerScopeLock (today's S5.2.1 default) | 808,483 | 1.917 | **208.792** | 5,247.875 | 638,594 | 181 |
| PerRootLock | 3,089,686 | 0.333 | **62.417** | 10,492.916 | 1,492,604 | 179 |

Pass bound: p99 added read latency <1ms. **PerScopeLock (the shipping default) passes at
208.79us**, ~4.8x headroom under the cap. Writer liveness held under both topologies (hundreds of
thousands of ops completed, never stalled). **Qualitative note:** the criterion is p99 by design
and both topologies pass it, but max reader latency was 5.25ms (per-scope) / 10.49ms (per-root) --
an occasional visible hitch under sustained contention that a p99-only summary hides. This does not
change the verdict; it is worth carrying into a future topology decision as qualitative
information. **TSan run clean** (`RUSTFLAGS=-Zsanitizer=thread`, nightly `-Z build-std`, no race
diagnostics) -- the TSan-instrumented run's *absolute* latencies are not used for the perf verdict
or the open-question-6 comparison (10-100x sanitizer overhead distorts relative timing under heavy
contention badly enough that it inverts the per-root-vs-per-scope ordering; that inversion is a
sanitizer artifact).

**Open question 6 answered:** at 8 roots, per-root locking measurably reduces p99 contention
latency by ~3.35x in the native run (208.79us -> 62.42us). Both topologies comfortably clear the
cap under today's default, so this is evidence for future headroom, not a mandate to switch now.
**Recommendation: keep the per-scope S5.2.1 default for P4-3a**; revisit if a later real-world
measurement (post P4-6b, actual UI window-count contention) approaches the 1ms cap.

## 8. Overall verdict and follow-up conditions

**GO-with-E2-deferred.** E-1 (kill criterion) passes by 3-4 orders of magnitude under both profile
pairings (corrected for a tail-append measurement bias that inflated the margin further in the
first draft -- see S2; the verdict is unchanged). E-1c passes with a validated gate, explicitly
scoped to the watermark axis (S3). E-1d passes in full under the only profile Rust ships in
(release/production), with the path-keyed margin at N=1000/10000 explicitly flagged as thin rather
than presented as a comfortable pass (S4); the debug-profile path-keyed regression is real and
tracked, not gating. E-3 and E-4 pass their pre-registered criteria; E-4 additionally answers open
question 6 with measured evidence. E-2's criteria are correctly BLOCKED (not passed, not failed)
pending infrastructure this step is not permitted to build; R8's memory-regression risk carries
effectively no comparative evidence out of this step, a gap recorded rather than hidden (S5).

Conditions carried forward, none of which block P4-3a from starting:

1. Track the E-1d path-keyed debug-profile regression (~5x) through P4-3a/P4-4 as a named watch
   item for local debug-app iteration experience, AND track the release-profile margin's thinness
   (S4) -- re-attempt the release-profile Swift capture once `CoreSearchTests.swift`'s unrelated
   compile break clears, and treat a re-derived ratio above 1.10x as a real regression to fix, not
   a result to explain away.
2. E-2's blocked criteria must be re-run in full at P4-4 (bridge) and P4-7 (suggestion-service
   rewiring) before they can be called passed -- this is required, not optional. Add a Swift-side
   memory-footprint probe at the same time to give R8 real comparative evidence.
3. D-1's N=1 is provisional. This step could not cleanly distinguish "real batching benefit" from
   "measurement-harness timer-overhead amortization" in the N-delta sweep (S2); re-derive N once
   P4-4's real FFI round trip exists to measure the actual dispatch tax.
4. Keep the per-scope locking default for P4-3a; the per-root evidence informs a future headroom
   decision, not an immediate topology change.
