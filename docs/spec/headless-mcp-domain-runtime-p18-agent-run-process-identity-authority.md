# Headless MCP domain runtime P18 — Agent run process identity authority

Status: implemented (2026-08-31).

## Contract

P17 made `DomainAgentRunTerminalOutcome` the sole semantic terminal input to the App commit
barrier. P18 completes the remaining run-identity seam: the provider process UUID and terminal
drain generation are now owned by `DomainAgentRunProcessIdentityState`, embedded in the shared
`DomainAgentRunLifecycleTracker`.

The process UUID is a correlation and stale-cleanup fence, not proof that a provider process is
alive. Installing a successor replaces the prior UUID explicitly. Run-scoped cleanup can clear an
identity only when the exact UUID is still current; force-clear remains reserved for transitions
whose contract is that no process may survive. Terminal-drain generation is monotonic within an
attempt and invalidates callbacks captured before a drain. Beginning a new logical attempt resets
the drain generation while preserving an intentionally reused process UUID.

## Ownership and compatibility

- `RepoPromptDomainRuntime` owns process UUID installation, exact-match clearing, force clearing,
and terminal-drain generation mutation as value-state operations.
- `DomainAgentRunLifecycleTracker` exposes the process identity projection and resets only the
  attempt-scoped drain generation during `begin`.
- `AgentRunAttemptLifecycle` is now a compatibility facade: it delegates process identity and
drain-generation operations to the Domain tracker and retains only App-owned terminal revision,
provider teardown resources, and adapter-facing projections.
- `AgentModeProcessRunIdentity` remains an App adapter for transcript span retention and process-ID
  lookup, but it no longer owns mutable identity state.
- No provider wire protocol, transcript schema, persistence bytes, routing behavior, cleanup
  ordering, terminal publication envelope, or user-visible lifecycle behavior changes.

## Failure and retry rules

A cleanup callback carrying an old process UUID cannot clear a successor UUID. Force clearing does
not alter the terminal-drain generation, so callers that require a hard transition must continue to
bump the generation through the named lifecycle operation. A new attempt cannot inherit a previous
attempt's drain generation, while ending an attempt leaves the process identity and settled terminal
projection available for existing retry and transcript correlation behavior.

## Retirement and guards

- App production code may not declare independent mutable `currentRunID` or
  `providerTerminalDrainGeneration` storage in `AgentRunAttemptLifecycle`.
- The M5 authority fixture records `DomainAgentRunProcessIdentityState` as the canonical owner.
- The Domain package remains free of App/UI/provider imports and `@MainActor` declarations.

## Verification gates

- Domain lifecycle tests cover exact UUID fences, successor replacement, force-clear semantics,
  generation bumping, and new-attempt reset/preservation behavior.
- Existing App lifecycle tests continue to exercise the compatibility facade and transcript
  process-ID behavior.
- Source-layout guardrails, SwiftFormat/SwiftLint, focused Domain tests, product builds, and
  `git diff --check` remain required before commit or push.
