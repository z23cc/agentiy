# Headless MCP domain runtime P17 — Agent run terminal outcome authority

Status: implemented (2026-08-31).

## Contract

P16 moved terminal successor and teardown settlement fences into
`DomainAgentRunTerminalSettlementCoordinator`. P17 completes the provider-neutral terminal
command boundary: `AgentRunTerminalCommitBarrier.Request` now carries one
`DomainAgentRunTerminalOutcome` instead of independently supplied App terminal state and failure
classification fields.

The outcome kind (`completed`, `cancelled`, or `failed`) is produced by the Domain execution
contract and is the sole semantic terminal input to the commit barrier. An explicitly classified
failure remains attached to the outcome. The shared execution core exposes an explicit
`deferFailureClassification` mode for hosts whose existing compatibility contract classifies from
settled transcript text. A failed outcome may then intentionally defer classification with
`failedWithoutClassification`; in that case the existing settled-transcript classifier runs once at
publication, preserving timeout/process/error diagnosis without making display text the
terminal-kind authority.

## Ownership and compatibility

- `DomainAgentRunTerminalOutcome` owns terminal kind, assistant text, and optional failure reason.
- `AgentRunTerminalCommitBarrier` derives `AgentSessionRunState` only for App transcript, teardown,
  and UI hooks; it no longer stores or accepts a parallel terminal state/failure-reason pair.
- Provider runners forward the Domain outcome returned by `DomainAgentRunExecutionCore`; startup,
  cancellation, and Codex terminal paths construct the same Domain outcome contract.
- `AgentRunTerminalCommitRevision` remains an App projection because it carries App-owned counters,
  publication envelopes, and adapter callbacks. Its projected terminal state is derived from the
  committed Domain outcome.
- No provider protocol, transcript schema, persistence bytes, publication envelope shape, routing,
  attachment disposition, or user-visible lifecycle behavior changes.

## Failure and retry rules

An outcome with an explicit failure reason is never reclassified from later transcript text.
Unclassified failures retain the prior one-time settled-text classification. Cancellation always
projects the canonical cancelled reason, and completion never carries a failure reason. Duplicate
terminal commit retries reuse the staged App revision and publication receipt exactly as before.

## Retirement and guards

- Production terminal commit requests must contain `DomainAgentRunTerminalOutcome` and may not
  reintroduce independent `terminalState` or `failureReason` request fields.
- The M5 authority fixture records `DomainAgentRunTerminalOutcome` as the terminal semantic owner.
- `RepoPromptDomainRuntime` remains free of App/UI/provider imports and `@MainActor` declarations.

## Verification gates

- Domain execution contract tests cover explicit, cancelled, completed, and deferred failure
  outcomes.
- Agent Mode lifecycle tests cover outcome-based commit construction, explicit failure preservation,
  deferred text classification, duplicate retries, provider successor delivery, and teardown.
- Source-layout guardrails, SwiftFormat/SwiftLint, product builds, focused tests, and
  `git diff --check` remain required before commit.
