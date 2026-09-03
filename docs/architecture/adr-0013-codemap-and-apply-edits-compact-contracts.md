# ADR-0013: Pure Offline Computation Contracts — CodeMap Extraction and Apply-Edits Diffing (Charter Phase 2 Final Acceptance)

**Status:** Accepted (charter §16 Phase 2, §15.3, §18 item 2; User ruling 2026-09-03)
**Date:** 2026-09-03
**Decision owner:** User
**Governing decisions:** Charter §16 Phase 2, §15.3, §18 item 2; ADR-0001, ADR-0003, ADR-0004, ADR-0008
**Related specifications:** `docs/architecture/rust-codemap-compact-v1.md`, `docs/architecture/rust-apply-edits-compact-v1.md`

---

## Context

Phase 2 of the Agentry rewrite charter (`docs/architecture/agentry-rewrite-charter.md` §16) governs the migration of pure, offline-replayable computation domains:
1. **Tree-sitter / CodeMap Extraction (P2-2)**: Parsing syntax trees across polyglot codebases to produce semantic outlines, captures, and symbol maps.
2. **Diff & Apply-Edits Preview Computation (P2-3)**: Myers diffing, chunk generation, exact/high-precision/fuzzy matching, ambiguity detection, indentation adjustment, and preview reconstruction.

During early implementation, both domains were specified via compact wire contracts:
- `docs/architecture/rust-codemap-compact-v1.md` (P2-2)
- `docs/architecture/rust-apply-edits-compact-v1.md` (P2-3)

The code was successfully implemented in `agentry-runtime` and wired through `AgentryCoreBridge` to Swift. Furthermore:
- In P2 Step 13, the legacy Swift CodeMap extractor was completely deleted from the codebase, and `CodeMapRustGoldenTests` was established as the authoritative golden test harness.
- In Apply-Edits, `RustApplyEditsComputer` and `CoreApplyEditsTests` became the production preview pipeline.

However, both specifications were left in `Status: draft for implementation and differential validation`, and no formal Architecture Decision Record existed to permanently codify the authority boundaries, memory budget invariants, and fail-closed contracts for Charter Phase 2.

---

## Decision

1. **Rust as Sole Authority for Pure Offline Computation**:
   - **CodeMap**: Rust owns decoded-source validation, Tree-sitter parse and query execution, capture extraction, normalization, and compact binary encoding across all 13 stable wire languages (Swift, JavaScript, C#, Python, C, Rust, C++, Go, Java, TypeScript, TSX, PHP, Ruby).
   - **Apply-Edits**: Rust owns literal and escape sequence fallback, exact/high-precision/fuzzy matching, multi-match ambiguity detection, `replace_all`, indentation correction, chunk synthesis, and unified diff rendering.
   - **Swift Authority Boundary**: Swift remains authoritative for workspace/path resolution, source decoding policy, approval orchestration, file read/write permissions, stale-write detection, persistence, and UI presentation.

2. **Strictly Path-Free Core Invariant**:
   - The Rust core never reads, writes, inspects, or validates filesystem paths.
   - Any `pathLabel` passed into core is strictly an opaque presentation token used exclusively for unified diff headers and extension-based indentation heuristics.

3. **Deterministic Memory Bounds (Myers 64MB Trace Limit)**:
   - Diffing and preview generation must operate within strictly bounded memory budgets.
   - The Rust Myers diff algorithm enforces a hard ceiling of $\le 64\text{ MB}$ for edit trace allocation.
   - Inputs exceeding this trace limit or exhibiting catastrophic combinatorial complexity are rejected deterministically with typed error codes (`.traceExhausted`) rather than risking process memory exhaustion.

4. **Fail-Closed, Zero-Fallback Rule**:
   - A core computation failure (parsing error, syntax error, diff trace exhaustion, or malformed UTF-8) must **never** silently fall back to legacy Swift implementations.
   - Core failures must **never** publish or expose partial artifacts or partial previews.
   - All errors cross the FFI boundary as strongly-typed, non-throwing domain outcomes.

5. **Wire Value Invariants**:
   - Contract versions (`contractVersion = 1`) and stable language IDs (1 through 13) are permanent wire integers, decoupled from Swift language enum strings.

6. **Golden Test Authority**:
   - Golden fixture tests (`Tests/RepoPromptTests/CodeMap/CodeMapRustGoldenTests.swift` against `Tests/RepoPromptCodeMapCoreTests/Goldens` and `AgentryCoreBridgeTests/CoreApplyEditsTests.swift`) serve as the non-negotiable regression gates for Phase 2 contracts.

---

## Consequences

- **Phase 2 Formally Certified and Closed**: Charter Phase 2 exit criteria (§16 Phase 2: §15.3 compliance, goldens, SLOs) are fully met and sealed.
- **Specification Status Promoted**: `rust-codemap-compact-v1.md` and `rust-apply-edits-compact-v1.md` are officially promoted from `draft` to `Accepted`.
- **Memory Safety Guaranteed**: Bounded trace memory (64MB) prevents memory amplification attacks or runaway diff calculations when processing massive machine-generated files.
- **No Path Coupling**: Pure computation logic remains completely detached from host filesystem semantics, facilitating portable cross-platform testing and future wasm/headless extraction.
