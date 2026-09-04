# ADR-0001: UniFFI as the Raw Binder for the Rust Core Boundary

**Status:** Accepted（用户裁决，2026-08-20）
**Accepted scope:** raw binder only — capabilities proven by the §15.2 gates. G4 and G7 are closed; G8's originally registered blockers are closed with one caveat recorded in the 2026-09-01 update below. Closing a gate does not expand this acceptance: the verified capability boundary and the prohibited-capability list further down remain exactly as ruled on 2026-08-20.
**Date:** 2026-08-20
**Decision owner:** User

## Context

The rewrite charter, `docs/architecture/agentry-rewrite-charter.md` §5 (tracked snapshot of `docs/designs/rust-core-swiftui-shell-rewrite-2026-08-20.md`, which remains the living, gitignored working copy), requires a narrow Rust-core/SwiftUI-shell boundary rather than a second product/runtime authority. Section 15.4 makes the binding choice conditional on evidence: accept the candidate only within the capabilities actually proven by the §15.2 gates, and reject it when a required boundary behavior is unsupported or a gate fails.

Phase 0 evaluates UniFFI 0.32.0 only as a generated raw binder beneath a project-owned Swift bridge. It does not authorize UniFFI to own runtime lifecycle, cancellation, streaming, payload delivery, or the product API. The authoritative project gate definitions, evidence, and gaps are in [`rust-ffi.md`](rust-ffi.md#g1g8-final-status-summary).

## Gate summary

The project gate IDs remain the primary keys; the charter mapping is the same mapping recorded in `rust-ffi.md`.

| Project gate | Charter §15.2 item | Conclusion | Decisive condition |
|---|---|---|---|
| G1 Contract | 1 binding/contract; 8 decoder bounds | Pass | ABI, envelope, errors, limits, fixtures, and SLO caps are frozen and machine-checked. |
| G2 Rust Foundation | 1 binding/toolchain; 6 architecture | Pass | Exact toolchain/dependency pins, one product UniFFI owner, unwind profiles, lockfile, and arm64 target are enforced. |
| G3 Runtime Lifecycle | 2 admission/cancel; 3 lifecycle | Pass | Admission/cancel soak, shutdown, tombstone, deadline, and first-terminal-wins evidence is complete for P0. |
| G4 Subscription/Wake | 3 queue/wake/lifecycle; 4 representative payload benchmark | Conditional pass | Synthetic queue/wake evidence passes; a real redacted Swift baseline and SLO comparison remain a P1 prerequisite. |
| G5 FFI Safety/Identity | 1 binding boundary; 2 identity/admission | Pass | Typed synchronous results, identity fencing, panic poison, and idempotent close/shutdown are verified. |
| G6 Reproducible Artifacts | 6 deterministic generation/arm64 | Pass | Byte-identical regeneration, zero-diff check, fingerprint sensitivity, hashes, and arm64-only archives are verified. |
| G7 Swift/Link/Xcode | 5 debug/release/race bridge; 7 Swift concurrency | Conditional pass | Debug/release/ThreadSanitizer and strict-concurrency evidence passes; standalone dead-strip/link-map and dSYM Rust-frame evidence is not registered. |
| G8 Governance | 8 fuzz/security; cross-gate authority | Conditional pass | Conductor/Make authority, Rust CI, fuzz smoke, and guardrails exist; Rust PR-ready selection and fail-closed CI security/fuzz coverage remain open. |

This ADR does not convert conditional gates into passes. Accept/Reject remains a user decision after reviewing the open conditions.

## Update (2026-09-01): G4/G7/G8 follow-ups closed; capability boundary unchanged

**Decision owner:** User (ruling); orchestrator (verification). Recorded as an amendment rather than an
edit to the table above, following the ADR-0008 precedent — the 2026-08-20 gate conclusions stay
readable as what was known at ruling time.

1. **G4 closed.** The representative same-semantics measurement the original row called a P1
   prerequisite was satisfied by the cargo-first authoritative harness; the superseded
   `swift-search-reference` was firstMatch-semantics and not comparable. No SLO cap or ratio was
   relaxed. Evidence: `rust/benchmarks/results/v1/rust-search-cargo-floors-v1.json`.
2. **G7 closed 2026-08-21.** The missing standalone dead-strip/link-map and dSYM Rust-frame evidence
   is registered: 1268 Rust symbols survive dead-strip in the release test bundle, and `atos`
   resolves a Rust frame to `types.rs:1124` through the `.dSYM`.
3. **G8's three registered blockers are closed.** Verified against the workflow and preflight script
   rather than against the neighbouring documentation rows: Rust PR-ready path selection exists
   (`preflight.sh:229,269,332-351`); `cargo deny`/`cargo audit` are pinned, `--locked`, and invoked
   unconditionally; bounded fuzz and the bridge debug/release/TSan matrix are all wired.

**Caveat that keeps G8 short of an unqualified pass.** Two facts are recorded rather than smoothed over:

- Until 2026-09-01 the `rust-ffi` job died at `cargo fmt --all -- --check`, so every step after it —
  workspace tests, `xtask generate --check`, `cargo deny`, `cargo audit`, all fuzz targets, and the
  bridge matrix — had **never executed**. The gate was configured, not running. That is precisely how
  the G1 export inventory drifted to 48 declared against 148 actual exports, and how a declared fuzz
  target went unrun for eight days. The formatting blocker is fixed and both drifts are now guarded by
  `Scripts/rust_ffi_guardrails.py`, but "configured" and "executing" are now understood to be
  different claims, and only the latter is evidence.
- As of 2026-09-01 the macOS jobs run on `workflow_dispatch` only, for cost reasons recorded in
  `ci.yml`. Advisory coverage — the part of ADR-0007 that degrades with time rather than with changes
  — is preserved by a weekly Linux `dependency-audit` job. Per-change coverage moved to local
  `preflight.sh pr-ready`. Anyone re-reading G8 as "fail-closed in CI on every change" should read it
  instead as "fail-closed locally on every change, and in CI on demand."
- As of 2026-09-04 hosted `CI` is Linux secret-scan only (1x billing). The macOS laundry list was
  removed rather than left as an accidental 10x `workflow_dispatch`. Weekly `cargo audit` moved to
  `dependency-audit.yml` so a scheduled success cannot complete the `CI` workflow on `main` and wake
  `main-beta.yml`. Default local `cargo-test` is `--lib`; `CARGO_TEST_KIND=full` restores integration
  coverage. Hosted fuzz is optional; `check_fuzz_target_coverage` fail-closes only when CI runs a
  partial target list.

**Unchanged by this update.** The verified capability boundary and the prohibited-capability list below
are untouched. Closing evidence gaps does not authorize UniFFI async exports, foreign callbacks,
blocking exports, raw generated types escaping the bridge, or any other listed prohibition; those still
require a new ADR and full gate revalidation.

## Proposed decision

Accept `uniffi = "=0.32.0"` as the P0 raw binder **only** for the capability boundary below, subject to the user changing this ADR from Draft to Accepted. Keep the handwritten `AgentryCoreBridge` as the product-facing boundary and keep the Rust runtime authoritative for operation and subscription lifecycle.

## Verified capability boundary

The candidate has been validated only for:

- proc-macro-only UniFFI generation using `setup_scaffolding!()`; no `.udl`;
- synchronous, bounded exports returning typed records/enums and typed `Result` errors;
- a Rust-owned Tokio runtime behind fast admission, cancellation, control, drain, close, and shutdown calls;
- explicit caller-owned operation IDs, cancellation, deadlines, and runtime identity fencing;
- bounded byte-envelope payloads drained by the caller rather than delivered through callbacks;
- a duplicated nonblocking file descriptor for empty-to-non-empty wake notification, with Swift `DispatchSourceRead` draining and explicit rearm;
- project-owned panic catching/poisoning and first-terminal-wins semantics;
- generated Swift/header artifacts hidden behind a handwritten Swift 6 actor bridge.

## Known limitations and prohibited capabilities

The following are unsupported for this decision and must not be introduced without a new ADR and full gate revalidation:

- UniFFI async exports or a UniFFI-owned Tokio runtime;
- async foreign traits, foreign callback interfaces, or payload callbacks;
- blocking exports, sleeping exports, waiting for queue capacity, or awaiting runtime work across the FFI call;
- raw generated objects, records, or errors escaping the handwritten bridge API;
- unversioned JSON as a raw control or payload boundary;
- implicit cancellation based only on Swift task destruction;
- unbounded queues, unbounded drain batches, or silent loss of terminal/control events;
- `.udl` as a second binding source of truth;
- x86_64 or universal Rust archives in P0;
- product-domain migration, `RepoPromptApp` wiring, UI integration, XPC, or release distribution under this decision;
- treating synthetic representative-payload fixtures as a substitute for the missing real Swift baseline.

If a future feature requires any prohibited capability, UniFFI has not been accepted for that feature.

## Fallback: handwritten narrow C ABI

The fallback is a project-owned, handwritten narrow C ABI that preserves the same ABI epoch, identity, typed error inventory, versioned byte envelopes, explicit cancellation, bounded drain semantics, FD wake/rearm protocol, panic containment, and Swift actor bridge. The fallback must not broaden the boundary merely to imitate generated APIs.

Trigger the fallback when any of the following occurs:

1. the user records **Reject** under the charter §15.4 decision;
2. a required P0/P1 boundary operation cannot be expressed within the verified synchronous capability set;
3. UniFFI requires async foreign traits, payload callbacks, blocking exports, or runtime ownership;
4. regeneration ceases to be byte-identical or `generate --check`/`regen --check` produces a diff;
5. ABI/checksum/build-fingerprint or stale-runtime identity rejection cannot remain fail-closed;
6. panic containment permits unwinding across the C ABI;
7. debug, release, ThreadSanitizer, arm64 link, or required symbolication validation fails;
8. the representative real Swift payload/SLO evidence rejects the boundary shape;
9. an upgrade cannot pass the version-lock procedure below.

Fallback adoption requires its own generated/header inventory update and rerunning all eight gates; it is not an emergency bypass around failed evidence.

## Version lock and upgrades

- Product binding dependency: `uniffi = "=0.32.0"`.
- Tooling dependency: version-matched `uniffi_bindgen = "=0.32.0"`.
- `rust/Cargo.lock` is committed and authoritative; floating ranges, Git revisions, and mixed UniFFI generator/runtime versions are prohibited.
- An upgrade must be proposed in a new ADR or an explicit amendment to this ADR.
- Before an upgrade may be accepted, generation must be byte-identical across two clean runs, the checked-in regeneration check must produce zero diff, and **all G1–G8 evidence must be rerun and re-registered**, including the then-required real representative-payload/SLO baseline.
- Any generated API, symbol inventory, checksum, warning, concurrency, link, or lifecycle drift is a failed upgrade until explicitly reviewed and resolved.

## Decision recording

The user must replace Draft with exactly one terminal status:

- **Accepted** — UniFFI 0.32.0 is approved only within the verified capability boundary and with the listed prerequisite/follow-up conditions acknowledged.
- **Rejected** — the handwritten narrow C ABI fallback becomes the selected binder, and all gates must be rerun against it.
