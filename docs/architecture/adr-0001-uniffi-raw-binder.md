# ADR-0001: UniFFI as the Raw Binder for the Rust Core Boundary

**Status:** Draft（待用户裁决 Accept/Reject）
**Date:** 2026-08-20
**Decision owner:** User

## Context

The rewrite charter, `docs/designs/rust-core-swiftui-shell-rewrite-2026-08-20.md` §5, requires a narrow Rust-core/SwiftUI-shell boundary rather than a second product/runtime authority. Section 15.4 makes the binding choice conditional on evidence: accept the candidate only within the capabilities actually proven by the §15.2 gates, and reject it when a required boundary behavior is unsupported or a gate fails.

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
