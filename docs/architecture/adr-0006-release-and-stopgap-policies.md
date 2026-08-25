# ADR-0006: Release and Stopgap Policies — arm64-Only, Beta-Soak Forward-Fix, Fail-Closed Schema Downgrade, Single-Writer Lease

**Status:** Accepted (charter decision 9, §7.3, §15.3 items 10–11); arm64-only landed at Milestone 0
**Date:** 2026-08-20
**Decision owner:** User

## Context

Four related operational rulings bound how the project ships and recovers once Rust domains are live in production: what architectures are supported, how a bad cutover gets fixed, how storage schema mismatches are handled, and how two runtimes sharing one canonical storage root avoid corrupting it. Each is a stopgap/release-safety policy rather than a feature design, and each is a precondition some domain's production cutover gate depends on (charter §15.3).

## Decision

1. **arm64-only.** Rust-enabled builds target `aarch64-apple-darwin` exclusively. No `x86_64-apple-darwin` archive, no `lipo`, no Rosetta fallback path for Rust domains. This was pulled forward to ship at the identity-reset milestone (ADR-0002) rather than waiting for the first Rust cutover, to avoid a window where arm64 runs Rust authority while x86_64 keeps writing the old Swift authority against the same storage.
2. **Beta-soak, forward-fix only (no per-domain rollback).** A domain's cutover build ships to the beta Sparkle channel (established at the identity reset, ADR-0002) first and soaks there before promotion to stable. There is no per-domain feature flag to revert to the old implementation, and no rollback path is promised — the old Swift implementation is deleted at cutover (§15.3 item 10). Production issues are fixed forward, quickly, not rolled back.
3. **Fail-closed schema downgrade.** Every durable store carries a schema-version stamp. An older runtime reading a newer schema fails closed — it refuses to load and reports the mismatch explicitly rather than risk silent corruption. Only journal-class stores take a one-time automatic backup before the first write under a new schema; no store commits to permanent backward-compatible writes (§15.3 item 11).
4. **Single-writer lease for canonical storage.** Where App and headless processes may reach the same canonical storage root, exactly one runtime holds mutation rights over it at any moment. While the GUI is active, headless writers to that storage either proxy through GUI authority or fail closed. Two independent in-memory authorities are never allowed to write the same journal/storage concurrently without a lease/lock/CAS/reload mechanism in place. Lease acquisition, renewal, staleness detection, and stale-lease preemption are implemented and validated as part of Phase 4 (Host broker / topology / storage preconditions) — this is a blocking gate for that phase, not a post-launch optimization. Fallback mechanisms (cross-process file lock + durable CAS + external reload, or explicit fail-closed) are used only if the lease design is falsified by Phase 4 evidence.

## Consequences

- Any Rust cutover ships beta-first with no revert switch; the bar for shipping a cutover to beta is correspondingly higher because forward-fix is the only recovery path.
- Storage-format changes are one-way: an old app build cannot silently open a store written by a newer schema.
- Domains touching canonical storage (workspace authority, MCP, Phase 4/5 in the roadmap) are blocked from production cutover until the single-writer lease exists and is validated — this is an explicit dependency, not an implementation detail left to the implementing agent's discretion.
- The x86_64/lipo/Rosetta release-tooling paths (`build_swiftpm_release_products.sh`, `validate_app_architectures.sh`, `compare_swiftpm_release_resources.py`, and related CI workflows) were converted to arm64-only assertions rather than kept as a parallel path.

## Implementation status — P5-0b Swift single-writer gate complete (2026-08-25)

[`headless-mcp-domain-runtime-p5-0-storage-lease.md`](../spec/headless-mcp-domain-runtime-p5-0-storage-lease.md)
freezes the language-neutral lease path, owner metadata schema, kernel-lock semantics, and persistence
writer inventory. `MCPDomainRuntime` now owns one process-wide lease/access actor; startup performs
fresh durable reconciliation before writable health, every canonical workspace writer and lazy
migration requires an active epoch-bound permit, and shutdown drains permits before releasing.
Contenders keep reads available under degraded read-only health and rejected commands are not entered
into deduplication state. Focused tests cover handoff/retry, failed reconciliation, scope enforcement,
orderly drain, metadata defenses, and real cross-process `SIGKILL` release.

This completes the Swift Phase-4 single-writer prerequisite, not a Rust authority cutover. Production
Rust workspace mutation/persistence still requires the domain parity, soak, schema, and cutover gates.
Mixed-version simultaneous access is unsupported because binaries older than P5-0b do not honor the
lease.

## Implementation status — P5-1a read-only Rust projection substrate (2026-08-25)

[`rust-workspace-document-projection-v1.md`](../spec/rust-workspace-document-projection-v1.md)
freezes and implements a side-effect-free Rust projection of the canonical workspace document's
workspace/context/prompt/selection read shape. The typed UniFFI and Swift bridge path validates runtime
identity and projection contract version; real-core differentials compare it to the existing Swift
decoder and direct-headless fallback semantics. This is parity substrate only: Swift remains the
production read/mutation/persistence authority and the Rust projector does not acquire the lease,
retain document bytes, publish state, or touch storage.

## Evidence

- arm64-only + identity-reset milestone commit: `e2ca06f1`.
- Charter: `docs/architecture/agentry-rewrite-charter.md` §1 (decision 9), §7.3, §13.2, §13.5, §15.3 items 10–11.
- Lease protocol and current writer audit: `docs/spec/headless-mcp-domain-runtime-p5-0-storage-lease.md`.
- Swift lease primitive: `Sources/RepoPromptDomainRuntime/DomainWorkspaceAuthorityLease.swift`.
- Focused owner tests: `Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceAuthorityLeaseTests.swift`.
- Rust read-projection contract: `docs/spec/rust-workspace-document-projection-v1.md`.
- Real-core differential: `Tests/RepoPromptDomainRuntimeTests/DomainWorkspaceRustProjectionTests.swift`.
