# ADR-0004: UTF-8 Text Contract and Deterministic Natural-Sort Ordering

**Status:** Accepted (charter §3.4 items 1–2, second-round ruling)
**Date:** 2026-08-20
**Decision owner:** User

## Context

Two related low-level semantic contracts needed to be pinned before any Rust text-handling or ordering domain could cut over: how text is decoded and offset once Rust owns it, and how user-visible ordering is computed once Rust owns it. Both are covered by the Rust-first authority principle (ADR-0003) but needed their own concrete ruling because they touch every downstream text/list-rendering consumer.

## Decision

### Text encoding and offsets

1. **Full-chain UTF-8.** Rust is the sole decoder. Charset detection and invalid-byte replacement (U+FFFD) policy live in Rust and produce canonical UTF-8 text with byte offsets.
2. **Swift holds the same UTF-8 text and byte offsets end-to-end.** No second text view of the same file may be built (no re-decoding through `NSString`/Foundation). Only AppKit/Foundation rendering leaves (`NSRange`/`NSAttributedString`/`NSTextView`) perform local UTF-8→UTF-16 conversion at snippet granularity; `NSRegularExpression` and other UTF-16 consumption points disappear as the regex domain migrates (ADR-0005).
3. **Offsets must land on scalar boundaries.** Invalid UTF-8, non-UTF-8 charsets, CRLF, and non-BMP characters are required golden-corpus inputs.
4. **Inventory obligation.** The ~105 existing `utf16` call sites must each be classified as "disappears with regex migration," "rendering-leaf conversion," or "needs rework" before/during the relevant cutovers.

### Ordering

5. **Rust owns user-visible sort order and delivers pre-ordered results; Swift adapts.** The algorithm is deterministic natural sort: Unicode simple case-fold + numeric-aware comparison (`第2章` < `第10章`) + code-point tie-break. Zero locale dependence, zero data tables — GUI, headless, and CLI produce identical order under every locale.
6. **Known, accepted drift (pinyin tradeoff).** `localizedStandardCompare` and other locale-aware sorting are no longer the behavioral baseline. Chinese filenames no longer sort in pinyin order (this matches VS Code and other code-point-based tools; Finder's pinyin ordering is the outlier, not the norm). This is recorded as a knowing, intentional drift under the ADR-0003 performative-drift rule, not an oversight.
7. **Reversible upgrade path.** If pinyin ordering is needed later, it is added behind the same sort API using `icu4x` plus Chinese collation data, as a separately versioned, explicitly reversible behavior change — not folded into this ruling.

## Consequences

- Any Rust text-domain cutover must ship the UTF-8/byte-offset invariants and the required golden inputs (invalid UTF-8, CRLF, non-BMP) as part of its gate, not as a follow-up.
- Any Rust sort-domain cutover ships the natural-sort algorithm exactly as specified (no locale tables); the pinyin-order regression is expected and does not block cutover — it is the accepted drift this ADR pre-approved.
- A future pinyin/collation upgrade is scoped as its own versioned change and does not require reopening this ADR's core ruling, only an amendment noting the API version bump.

## Evidence

- Charter: `docs/architecture/agentry-rewrite-charter.md` §3.4 items 1–2.
- ADR-0003 (`adr-0003-rust-first-authority-non-waivable-contracts.md`) — the drift-recording rule this ADR exercises.
