# TD-4 — slice-2 economics gate (GO/NO-GO): results

Design: `docs/designs/textdecode-policy-v2-2026-08-22.md` (§10 X-3 experiment definition, §11 TD-4
step entry). ADR: `docs/architecture/adr-0008-migration-economics-benchmark-gate.md`. Raw data:
`td4-textdecode-slice2-gate-v1.json` (this directory). Harnesses: cargo-side
`rust/crates/runtime/src/textdecode/td4_benchmark_probe.rs`, Swift-side
`Tests/RepoPromptTests/WorkspaceContext/TextDecodeCutoverBenchmarkTests.swift`.

**Overall verdict: DEFER.** Not a finding that the port is slow — the cleanest single number this
run produced (release-profile pure decode compute) is favorable. DEFER reflects that no
release-profile, apples-to-apples-enough measurement of the actual FFI seam was completed this
session, for reasons recorded below, and ADR-0008 treats a clearly-reasoned DEFER as a legitimate
gate-closing outcome, same as P3-2c's precedent.

## 1. The seam problem, stated up front

No standalone Rust decode FFI export exists. `textdecode()` is reachable only embedded inside the
codemap and apply-edits FFI handlers (design §6.1). This benchmark measures the candidate through
`RustApplyEditsComputer`'s real, shipped `.raw` source-kind path — genuinely production code, but
one that does substantially more than decode alone (full apply-edits diff/chunk/envelope
construction for a `.rewrite(replacement: "")` operation). The task's own scope pre-authorizes this
"differential-shaped, not production-shape" fallback when no dedicated entry exists; it is called
out here rather than silently presented as an isolated decode number, and it is expected to
OVERSTATE what TD-5's real candidate (a lean content-read path with no apply-edits envelope) would
actually cost.

## 2. What was measured, and why the numbers are debug-profile

All Swift-side numbers here are DEBUG profile on both sides of the FFI boundary. A release rebuild
was not attempted this session: `rust/benchmarks/slo-v1.json`'s `performanceIterationPolicy` names a
~15-minute cost and explicitly instructs leading with cargo-side evidence before paying it; on top
of that, an initial attempt at this exact Swift benchmark (5 measured iterations, matching other
harnesses' convention) coincided with the coordinated daemon's control socket becoming briefly
unresponsive while sharing this checkout with another agent's concurrent heavy build activity.
Iteration count was reduced to 3 and a release attempt was not layered on top, in keeping with this
session's explicit machine-light framing. This is recorded as a real limitation, not smoothed over.

Two more real (non-profile) blockers were hit and resolved in sequence before any Swift number could
be captured, both worth recording since they're evidence of genuine shared-checkout hazards, not
flaws in this benchmark's design:

1. **Transient unrelated compile break.** `WorkspaceInventoryScopeShadowSoakTests.swift` (untracked,
   another agent's concurrent in-progress file) referenced an unqualified type name mid-edit.
   Resolved itself once that agent's edit completed — matches the exact hazard class
   `slo-v1.json`'s existing `inventoryScopeV1.swiftBaseline.referenceReport.note` already documents
   from a prior session.
2. **Binding-identity mismatch (`incompatibleBindings`).** Adding this task's new Rust test modules
   changed `rustSourceRevision`'s content digest without the generated Swift bindings being
   regenerated. Resolved via `make dev-cargo-codegen` (the task's own validation note pre-authorizes
   this: "no identity churn unless you add rust code — then regen protocol"). Diff was
   identity-only, zero FFI-surface change, confirming the new test code has no production effect.

## 3. Results

### 3.1 Cargo-side, release profile (cleanest number, no FFI, no envelope)

| Files | per-file µs (p50) |
|---:|---:|
| 100 | 2.308 |
| 1,000 | 2.312 |
| 10,000 | 2.330 |
| 100,000 | 2.382 |

Flat across four orders of magnitude — pure `O(n)` decode cost, no batching artifact. This is the
strongest evidence in this run and it's favorable.

### 3.2 Cargo-side, debug profile (isolates the decode-only debug/release ratio)

| Files | per-file µs (p50) |
|---:|---:|
| 100 | 33.081 (cold-start noise) |
| 1,000 | 22.422 |
| 10,000 | 22.437 |
| 100,000 | 22.617 |

Debug/release ratio ≈ 9.5–9.8× at N≥1,000 — used below to reason about what the FFI+envelope number
might look like under release, without asserting a number that wasn't actually measured.

### 3.3 Swift decode-only, debug profile (today's live chain, `decodeWorkspaceAutomaticV1`)

| Files | per-file µs (p50) |
|---:|---:|
| 100 | 15.964 |
| 1,000 | 15.190 |
| 10,000 | 15.109 |
| 100,000 | 15.051 |

Also flat. **Decode-only debug-vs-debug ratio (Rust 22.4–22.6 / Swift 15.05–15.19): ≈1.48–1.49×** —
over the 1.10× bound but far closer than the headline batched number below, and both sides are at
the same (debug) profile here so this specific sub-comparison isn't profile-confounded.

### 3.4 Rust candidate, batched FFI + apply-edits envelope, debug profile (the X-3 headline number)

| Files | Rust µs/file (p50) | Ratio vs Swift decode-only (p50) | Ratio (p99) |
|---:|---:|---:|---:|
| 100 | 168.335 | 10.545× | 10.192× |
| 1,000 | 168.899 | 11.119× | 10.980× |
| 10,000 | 171.572 | 11.356× | 11.348× |
| 100,000 | 173.705 | 11.541× | 11.428× |

**Flat across scale — no cliff at 10k/100k.** This is structurally reassuring: it rules out the
specific pathology P3-2c found for inventory (whole-table-round-trip cost exploding with size). The
overhead here is a fixed per-item tax, not a batching failure.

**Decomposition:** subtracting §3.2's debug decode-only number (~22.4–22.6µs) from this row
(~168–174µs) leaves **~146–151µs/file of non-decode cost** — apply-edits diff/chunk construction for
the `.rewrite(replacement: "")` operation, wire marshaling, and per-item share of the FFI crossing.
This is the part of the number that's least representative of TD-5's actual candidate (a lean
content-read path needs none of it), and also the part most likely to shrink substantially under
release optimization — by an amount this session did not measure.

### 3.5 Unbatched per-call latency, debug profile (evidence only, unscored)

n=30 individual (non-batched) round trips: **p50 = 198.0µs, p99 = 398.8µs** — higher than the
batched per-file number, as expected (each call pays its own FFI crossing rather than amortizing one
crossing across many subjects). Directionally confirms batching matters for TD-5, consistent with
the design's own assumption (§11 TD-5: "batched where the existing chunked-read loop already groups
work"). **Unscored**: TD-1 never registered a floor for X-3's absolute-latency-floor side (100/1k) —
TD-1 landed deletion-only (`3cc2d098`), not the full contract-freeze/fixture-dump/floor-registration
step the design's §11 describes. Registering a floor now, after seeing this number, would invert
ADR-0008's explicit ordering requirement.

## 4. Verdict and reasoning

**DEFER**, with three concrete, independent preconditions to retry (any one closes the gap):

1. Re-run this exact Swift harness under release profile for both the Rust archive and the Swift
   binary. Not attempted this session (policy-recommended ~15 min cost, plus this session's own
   observed daemon-socket sensitivity to heavy concurrent load in a shared checkout).
2. Build a dedicated decode-only FFI entry point, eliminating the apply-edits-envelope confound
   entirely rather than needing to reason around ~146–151µs of irrelevant overhead.
3. Land TD-1's still-missing SLO-floor registration (X-3's absolute-latency-floor side) before
   re-running the gate, per ADR-0008's ordering requirement.

This DEFER does **not** imply the port is uneconomical. The cleanest number measured — release-
profile pure decode compute, no FFI, no envelope — is clearly favorable (~2.3µs/file, flat across
scale, vs Swift's own debug decode-only chain at ~15µs/file: decode itself is not what's putting
this over the bound). What's unresolved is whether the *envelope* cost this differential-shaped seam
necessarily carries — which TD-5's real candidate won't carry — would still clear the bound under a
fair, same-profile, decode-focused comparison. Nothing in this run answers that with confidence in
either direction, and inventing an answer from a debug-profile, envelope-confounded number is
exactly the SLO-shopping ADR-0008 exists to prevent.

Per design §10 open question 1's existing pattern for a slice-2 DEFER: TD-3 (slice 1: codemap +
headless apply-edits) is already landed and unaffected. TD-5 (general content-read path + GUI
apply-edits) remains an explicitly named, charter-visible follow-up gated on one of the three
preconditions above — not a silent "done" and not an abandoned port.
