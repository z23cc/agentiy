# ADR-0009: Data-Plane Payload Schema Default and MCP/Tool-Catalog Authority Handoff

**Status:** Accepted (charter §18 items 1 and 8)
**Date:** 2026-08-20
**Decision owner:** User

## Context

Two related "which schema governs, and who owns it" rulings needed to be pinned so that Phase 0 benchmarking and the eventual Phase 4 protocol cutover would not each improvise their own answer: what format the versioned data plane (large file-tree/codemap/search/transcript payloads, charter §10.2) defaults to, and — separately — which side owns the canonical MCP/tool-catalog schema before versus after Phase 4.

## Decision

### Data-plane payload schema default (§18 item 1)

1. **Protobuf + SwiftProtobuf is the default candidate** for the versioned byte-envelope data plane, subject to Phase 0 benchmark verification against the typed-DTO baseline (charter §15.2 gate 4).
2. **`postcard` is explicitly rejected** for lacking a mature Swift-side implementation — not evaluated further regardless of its Rust-side merits.
3. **FlatBuffers or a project-owned byte layout are the fallback candidates**, evaluated only if Protobuf fails to meet the registered SLO.
4. **Runtime transport, durable journal, and external MCP wire each define their own compatibility period** even where they share payload types — a schema choice for one does not imply a shared version/compatibility promise across all three.

### MCP/tool-catalog canonical authority (§18 item 8)

5. **Before Phase 4:** the existing Swift schema remains the sole canonical MCP/tool-catalog source. A second, hand-written Rust catalog is forbidden during this period — maintaining two canonical catalogs in parallel is explicitly the failure mode this rule exists to prevent.
6. **From Phase 4 onward:** canonical ownership moves to `agentry-proto` (Rust types plus an exported, language-neutral schema); Swift consumes the generated artifact rather than hand-authoring its own.

## Consequences

- A Phase 0 (or later) benchmark that shows Protobuf missing its registered SLO triggers evaluation of FlatBuffers/own-layout, not silent adoption of `postcard` regardless of any Rust-side convenience it might offer.
- Any domain or PR proposing a hand-written Rust MCP/tool-catalog type before Phase 4 lands is a guardrail violation against this ruling, independent of whether the Swift and Rust catalogs happen to agree at that moment — drift risk is the reason for the ban, not current correctness.
- The Phase 4 handoff is a one-way authority transfer: once `agentry-proto` is canonical, Swift's hand-written schema becomes the generated-artifact consumer, not a parallel source of truth (consistent with the ADR-0003 single-canonical-authority principle applied to protocol schema specifically).

## Evidence

- Charter: `docs/architecture/agentry-rewrite-charter.md` §10.2 (data-plane framing), §15.2 gate 4 (benchmark gate), §16 Phase 4, §18 items 1 and 8.
- ADR-0003 (`adr-0003-rust-first-authority-non-waivable-contracts.md`) — the single-canonical-authority principle this ruling applies to the protocol/schema layer specifically.
