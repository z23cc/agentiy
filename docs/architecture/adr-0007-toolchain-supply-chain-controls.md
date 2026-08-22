# ADR-0007: Toolchain and Supply-Chain Controls — Content-Digest Build Fingerprint, cargo-deny, Deterministic Codegen

**Status:** Accepted; implemented incrementally P0–P0-5a/G8-tail
**Date:** 2026-08-20 (ruling), 2026-08-21 (fingerprint fix), through P0-5a/G8-tail (deny/audit enforcement)
**Decision owner:** User (ruling); orchestrator (implementation, gate evidence in `rust-ffi.md`)

## Context

Bringing Rust into the build graph required three supply-chain guarantees that had no precedent in the pure-Swift toolchain: a build-artifact identity strong enough to reject a stale or mismatched Rust archive even when its exported API checksum matches, deterministic regeneration of committed UniFFI bindings, and dependency/license/advisory scanning for the new Cargo dependency tree.

## Decision

1. **Two-layer artifact identity.** UniFFI's own API checksum only detects binding/ABI-contract drift. A project-owned `CoreBuildFingerprint` additionally covers ABI epoch, payload schema set, Rust source revision, `Cargo.lock` digest, toolchain, feature set, and build profile — catching the "same API, wrong implementation" case UniFFI's checksum cannot see.
2. **`rustSourceRevision` is a content digest of build inputs, not `git:<HEAD>`.** The initial implementation used the clean-tree HEAD SHA as a fast path; because HEAD moves on every commit even when no Rust build input changed, this rotated the fingerprint on every commit and could fail-closed the just-landed binding identity immediately after a commit landed (`incompatibleBindings` across seam-dependent suites). The fix makes `rustSourceRevision` always the build-input content digest — deterministic for identical inputs regardless of git state, and rotating exactly when a build input actually changes.
3. **Committed, byte-identical generated code.** Generated Swift/header/module-map artifacts are committed for review; regeneration on a clean environment must produce zero diff (`xtask generate --check`).
4. **Exact toolchain and dependency pins.** `uniffi = "=0.32.0"`, matching `uniffi_bindgen`, and a committed `rust/Cargo.lock` as the sole authoritative lockfile — no floating ranges, no git-revision dependencies, no mixed generator/runtime versions.
5. **`cargo deny` and `cargo audit` are fail-closed CI gates**, covering license, advisory, and dependency-ban policy for the Rust dependency tree; release artifacts aggregate Rust dependency license/NOTICE information. `cargo-vet` was explicitly declined as not worth the maintenance cost at current project scale.
6. **Secret scanning and CI selection extend to `rust/`.** The `rpce-contribution-check` staged/outgoing secret scan covers `Cargo.lock` and vendored content; PR-ready path selection accounts for Rust-tree changes.

## Consequences

- A fingerprint bug that surfaces only across the dirty→committed git-state transition is now a known, regression-tested failure class (`fa28c1ca`); any future fingerprint field must be re-derived from build inputs, never from ambient git state.
- Any UniFFI version upgrade must re-pass byte-identical regeneration and rerun all G1–G8 gate evidence (per ADR-0001's version-lock procedure) before it can be accepted — the pin is not a soft default.
- Rust dependency additions are subject to `cargo deny`/`cargo audit` the same way Swift dependencies are subject to existing guardrails; there is no separate lower bar for the Rust side of the supply chain.

## Evidence

- Content-digest fingerprint fix (the "fa28c1ca lesson"): `fa28c1ca2a80ec379b70e3865113615a42eb9220`.
- Initial workspace/contract freeze (`abi-v1.json`, `exports.txt`, `slo-v1.json`, G1–G8 matrix): P0-1, tracker 2026-08-20.
- Deterministic codegen + `CoreBuildFingerprint` (nine fields) landed: P0-3, tracker 2026-08-20.
- `cargo deny`/`cargo audit` fail-closed CI + PR-ready selection (G8-tail): tracker P0-5a / G8-tail entries.
- Gate detail and current status: `docs/architecture/rust-ffi.md` (G1 Contract, G6 Reproducible Artifacts, G8 Governance).
- Charter: `docs/architecture/agentry-rewrite-charter.md` §13.1, §13.4.
