# ADR-0002: Hard Fork of Upstream, Baseline Freeze, and Agentry Identity Reset

**Status:** Accepted (user ruling, Gate −1, 2026-08-20)
**Date:** 2026-08-20
**Decision owner:** User

## Context

`repoprompt-ce` is a GitHub fork of `repoprompt/repoprompt-ce`. Before any Rust-core work could begin, the rewrite charter (`docs/architecture/agentry-rewrite-charter.md`, "Gate −1") required a ruling on the relationship to upstream: upstream was averaging ~16 commits/day at ruling time (1481 commits / 90 days), concentrated in exactly the directories the rewrite targets (`Infrastructure`, `AgentMode`, `RepoPromptDomainRuntime`, `RepoPromptMCP`, CodeMap, `CSwiftPCRE2`, `Search`). Treating "stay mergeable with upstream" as a design constraint would have made every Rust cutover a merge-conflict generator against a fast-moving upstream.

## Decision

1. **Hard fork.** The project no longer treats upstream mergeability as a constraint on migration boundaries. Upstream is a reference/borrowing source only, not a merge partner, once a domain has cut over to Rust.
2. **Baseline freeze.** Behavioral parity, goldens, and the ~270k-line Swift test corpus are frozen to the last full upstream sync commit (`8136f50d`, 2026-08-20 upstream/main→dev merge; fork point before that was `ae557a59`). Parity work targets this static snapshot, not upstream's moving HEAD.
3. **Two-era sync/borrow protocol.**
   - *Before the first production Rust cutover:* periodic full-repo syncs from upstream remain allowed, each an explicit action; every sync must be immediately followed by an identity-regression checklist (identity guard sweep including upstream's original `com.pvncher.repoprompt` namespace, release-tooling tests, focused tests for touched domains). Regressions the sync reintroduces (old identity strings, old storage paths, architecture regressions) must be fixed in the same batch before further work lands.
   - *From the first production cutover onward:* merge/rebase from upstream stops permanently. Borrowing becomes read-diff-then-reimplement: read the upstream diff, reimplement on the repo's own canonical-authority side (Rust if the domain has cut over, Swift if it has not). Upstream Swift patches must never be pasted directly into a domain already owned by Rust. Borrowed changes bring their own tests; the project does not backfill upstream's full test suite or promise to track upstream's feature roadmap. Security-relevant upstream fixes must be evaluated on discovery; other functional changes are evaluated on a roughly monthly cadence.
4. **Cost accepted explicitly.** Once a domain cuts over, upstream's future changes to that domain permanently lose direct mergeability. The value of the hard fork (Rust core, arm64-only, maintainability) is judged to outweigh feature-stream parity with upstream; no domain gets a completeness guarantee against upstream's roadmap.
5. **Product identity reset (Milestone 0).** As the first executable milestone — independent of any Rust work, bundled with the arm64-only release convergence (ADR-0006) into a single release action — the product took a full identity reset: app/executable name and bundle identifier changed (`RepoPrompt.app` → `Agentry.app`), a new canonical storage root (`~/Library/Application Support/Agentry/`) with no import or migration of the old `RepoPrompt CE` root, a new Sparkle feed URL with a freshly generated EdDSA keypair split into stable/beta channels, a new Sentry project/DSN, and matching CLI/MCP binary renames (`agentry-cli-debug`, `agentry-mcp`). Internal Swift module/target names were explicitly *not* renamed; new Rust crates and bridge targets were born with `Agentry`/`agentry-*` names.

## Consequences

- Domain cutovers are a one-way door with respect to upstream mergeability; this is accepted risk, not an oversight.
- A discovered mid-flight upstream sync (`8136f50d`) after the ruling required a full identity-regression sweep and moved the frozen baseline forward once; the sync-then-checklist protocol was exercised for real, not just specified (see the session log entry for 2026-08-20 in `agentry-implementation-tracker.md`).
- No first-run migration path exists from the old `RepoPrompt CE` install; users install fresh.
- Release identity artifacts (Sparkle keys, signing identity, Sentry DSN) are release-gating and remain user-provided blockers independent of Rust migration progress.

## Evidence

- Identity reset milestone: `e2ca06f1`.
- Upstream sync discovery and identity-regression repair: session `F015F35B` (tracker log, 2026-08-20).
- Charter: `docs/architecture/agentry-rewrite-charter.md` §1 (decisions 10, 13), §3.3, §13.5.
