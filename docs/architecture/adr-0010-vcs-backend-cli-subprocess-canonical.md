# ADR-0010: VCS Backend — CLI Subprocess Canonical, In-Process Library as End-State Goal, git2/libgit2 Banned

**Status:** Accepted (charter §18 item 5)
**Date:** 2026-08-20
**Decision owner:** User

## Context

The Rust VCS domain needed a starting implementation strategy and a stance on the long-term target, without which the workspace domain's Git/JJ integration work would default to whatever library happened to be easiest to bind first — historically `libgit2` via `git2`, which the project wants to avoid as a dependency regardless of short-term convenience.

## Decision

1. **CLI subprocess (git/jj) is canonical to start.** This matches the existing CLI-backend model already in production (zero behavioral parity drift) and begins as an internal module of `agentry-domain-workspace` rather than its own crate.
2. **In-process library integration (`gitoxide`/`jj-lib`) is the end-state goal, not merely an option to consider later.** It is adopted per-domain as behavior and performance benchmarks justify the switch — the same benchmark-gated cutover discipline as any other domain (ADR-0008), applied here specifically to the VCS backend.
3. **`git2`/`libgit2` are explicitly banned.** No VCS work may introduce this dependency, at any phase, regardless of expedience.

## Consequences

- Early VCS/workspace work correctly stays on CLI subprocess semantics; reaching for `git2`/`libgit2` as a quick win is a banned shortcut, not a judgment call left to the implementing agent.
- A future in-process VCS migration is expected and pre-approved in principle (`gitoxide`/`jj-lib`), but still has to clear its own behavior/performance benchmark gate per domain before cutover — this ADR pre-approves the *direction*, not an unconditional cutover.
- Any dependency-audit tooling (`cargo deny`, ADR-0007) should treat `git2`/`libgit2` as a banned dependency for this project, not merely an unreviewed one.

## Evidence

- Charter: `docs/architecture/agentry-rewrite-charter.md` §18 item 5.
- ADR-0007 (`adr-0007-toolchain-supply-chain-controls.md`) — the `cargo deny` supply-chain gate this ban should be enforced through.
- ADR-0008 (`adr-0008-migration-economics-benchmark-gate.md`) — the benchmark-gated cutover discipline this ADR applies to the VCS backend's own end-state migration.
