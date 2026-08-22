# ADR-0005: PCRE2 + JIT as the Rust Regex Engine

**Status:** Accepted (charter §3.4 item 3); production cutover landed P1-2 (2026-08-20/21)
**Date:** 2026-08-20 (ruling), 2026-08-21 (cutover)
**Decision owner:** User (ruling), orchestrator (implementation)

## Context

Regex is one of the first small, deterministic leaf domains scheduled for migration (charter Phase 1). The existing Swift implementation used `NSRegularExpression`/vendored `CSwiftPCRE2`. A concrete engine choice was needed before the leaf-domain cutover could proceed, including a stance on JIT and the associated hardened-runtime entitlement.

## Decision

1. **Rust `pcre2` crate with JIT enabled** is the regex engine once the domain cuts over. The `com.apple.security.cs.allow-jit` entitlement is retained to support it.
2. **Performance baselines and SLOs must state JIT status explicitly** — a non-JIT comparison is not a valid substitute for the accepted baseline.
3. **Entitlement changes are separately audited.** Any addition or removal to the entitlement set is not bundled silently into a regex or unrelated change; it goes through guardrails review on its own (per the non-waivable macOS platform contract, ADR-0003).
4. **Vendored `CSwiftPCRE2` is deleted once this domain cuts over** — no permanent dual implementation.

## Consequences

- Regex behavior after cutover is defined by `pcre2`'s semantics, not `NSRegularExpression`'s; any divergence in regex feature support or matching semantics is a correctness-contract concern (ADR-0003) and must be parity-tested, not treated as acceptable performative drift.
- The vendored C library and its ~110k lines were fully removed at cutover (see evidence), eliminating that supply-chain surface.
- Static-bundled `pcre2 = "0.2.11"` with strict JIT is the pinned, production dependency; any future engine change (e.g. dropping JIT, swapping libraries) requires a new ADR.

## Evidence

- P1-2 cutover (Rust regex/JIT/path leaf + UniFFI/Bridge API, 63 cargo tests, strict JIT): tracker session `8DF4E54F`/`32C136A1`.
- Old Swift `RegexCore` + `CSwiftPCRE2` deletion (~110k lines): `84e0a54f`.
- Charter: `docs/architecture/agentry-rewrite-charter.md` §3.4 item 3.
