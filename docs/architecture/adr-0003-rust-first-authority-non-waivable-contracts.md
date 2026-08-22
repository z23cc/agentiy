# ADR-0003: Rust-First Authority Principle and the Three Non-Waivable Contracts

**Status:** Accepted (charter decision 12, 2026-08-20)
**Date:** 2026-08-20
**Decision owner:** User

## Context

The rewrite runs in-process rather than over RPC/XPC by default (charter decision 1); ADR-0001 accepts UniFFI 0.32.0 as the raw binder for that in-process boundary. Decision 1 itself is not re-litigated here — this ADR covers a separate, later ruling: once a domain has cut over, which side owns behavior, and what must never change regardless of which side owns it.

Without an explicit rule, migration risks two failure modes: (a) Rust cutovers quietly inheriting Swift's legacy quirks as permanent compatibility debt, and (b) Rust cutovers silently breaking behavior that external clients or correctness depends on.

## Decision

1. **Rust-first authority.** For any domain that has cut over, and for any newly built capability, Rust is authoritative and Swift adapts. Cutovers do not carry compatibility baggage for upstream data formats, legacy formats, or pre-existing Swift presentational behavior merely because it existed before.
2. **Three non-waivable contracts.** Regardless of Rust-first authority, the following must not drift without a dedicated ADR and full gate revalidation:
   - **External MCP wire and tool semantics** — third-party MCP clients depend on this surface.
   - **Domain correctness semantics** — edits, path resolution, revision/CAS, and recovery behavior.
   - **macOS platform contract** — signing, notarization, TCC, and process lifecycle.
3. **Performative behavior may change.** Sort order, estimated/heuristic numbers, and UI-visible detail may be redefined by Rust, but any such drift must be knowingly recorded and covered by a new behavior test (see ADR-0004 for the first exercised instance of this rule, the natural-sort ruling).

## Consequences

- A Rust cutover that changes correctness semantics, MCP wire behavior, or the macOS platform contract is treated as a regression, not an acceptable drift, and blocks the domain's cutover gate (charter §15.3 item 2).
- A Rust cutover that changes presentational behavior (e.g. sort order, estimate numbers) is acceptable but requires an explicit, reviewable "known drift" entry plus a test asserting the new behavior — silent drift is not permitted either way.
- This principle is the interpretive backstop every subsequent domain-specific ADR (ADR-0004, ADR-0005) applies when deciding what counts as an acceptable behavior change versus a banned one.

## Evidence

- Charter: `docs/architecture/agentry-rewrite-charter.md` §1 (decision 12), §3.4 (contract framing preceding items 1–4).
- ADR-0001 (`adr-0001-uniffi-raw-binder.md`) — the accepted in-process/UniFFI boundary this authority principle operates within.
