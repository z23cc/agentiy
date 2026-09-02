# Headless MCP domain runtime — P15 Agent run terminal-commit authority

> **Historical milestone record.** Named XCTest FILTER commands in this document may refer to suites retired in the 2026-09 test-suite slimdown. Use remaining focused suites listed in `docs/testing.md` and `AGENTS.md`.


Status: implemented (2026-08-30).

## Contract

P15 moves the semantic terminal-commit phase from the App run facade into
`RepoPromptDomainRuntime`. `DomainAgentRunTerminalCommitState` is the sole owner of the
exclusive commit phase, staged commit identity, publication-result receipt, and reset/invalidation
rules. It is embedded in `DomainAgentRunLifecycleTracker`, so ownership, liveness, and terminal
settlement use one reducer for every App or headless host.

Entering the phase is exclusive and returns a typed `acquired`, `alreadyInProgress`, or
`staleOwnership` result. A staged receipt binds the commit ID to the current run ownership and
clears any previous publication result. Stale ownership cannot begin or stage a receipt. Publication results remain recordable after the
phase completes or after a binding transition clears the staged receipt; this preserves the
existing exactly-once retry ordering without reopening the commit phase. A new run attempt resets
all terminal-commit state, while binding invalidation clears only the staged receipt and result.

## Compatibility and ownership

- `AgentRunAttemptLifecycle` delegates begin, stage, result, abort, complete, invalidate, and reset
  operations to the Domain reducer.
- `AgentRunTerminalCommitRevision` remains an App projection because it carries App-owned source
  counters and publication adapters. Its commit ID and ownership must match the Domain staged
  receipt before duplicate settlement is handled.
- `AgentRunTerminalCommitBarrier` remains an App capability adapter for transcript flushing,
  provider teardown, attachment disposition, and publication callbacks. It does not own the
  terminal phase or decide duplicate ownership.
- Existing Agent Mode and MCP wait call sites retain their source behavior, terminal ordering,
  persistence bytes, provider wire messages, routing, and cancellation semantics.

## Retirement and guards

- App production code may not store an independent terminal-commit phase flag or publication
  result; those values are projected from `DomainAgentRunLifecycleTracker`.
- `RepoPromptDomainRuntime` remains free of App/UI/provider imports and `@MainActor` declarations.
- Source-layout guardrails require the Domain terminal-commit contract, the App delegation calls,
  and the M5 authority fixture entry for `DomainAgentRunTerminalCommitState`.

## Verification gates

- `DomainAgentRunTerminalCommitContractsTests` covers exclusive admission, typed owner rejection,
  ownership-bound staging, result-after-completion, stale-stage rejection, successor reset, and
  binding invalidation semantics.
- Existing `AgentRunAttemptLifecycleTests`, terminal barrier tests, Agent Mode lifecycle tests,
  product builds, SwiftFormat/SwiftLint, and source guardrails remain required.
