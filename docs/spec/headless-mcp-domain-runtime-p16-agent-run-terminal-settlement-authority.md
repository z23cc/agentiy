# Headless MCP domain runtime P16 — Agent run terminal settlement authority

Status: implemented (2026-08-31).

## Contract

P15 moved terminal commit phase and publication-result fencing into
`RepoPromptDomainRuntime`. P16 completes the remaining provider-neutral settlement
boundary: successor delivery tombstones and teardown registration/completion tokens
are now owned by `DomainAgentRunTerminalSettlementCoordinator`.

The coordinator contains no provider, transcript, UI, or task objects. It records a
bounded FIFO of successfully delivered provider-successor IDs (512 entries) and an
ownership-to-token map for terminal teardown obligations. A successor callback is
tombstoned only after the bound callback reports success, so a rejected publication
or failed callback remains retryable. Duplicate IDs are ignored until deterministic
FIFO eviction.

Teardown registration is idempotent for an ownership while its token is pending.
Completion requires the exact registered token; a late completion from an older
App task cannot clear a newer obligation. The App terminal barrier continues to
execute the actual async teardown task and provider/UI callbacks, but delegates all
successor and teardown identity decisions to the Domain coordinator.

## Compatibility and lifecycle

No provider wire protocol, transcript schema, persistence format, publication
envelope, or user-visible lifecycle changes. Generic queued follow-up consumption
remains an App presentation adapter because it owns the queue and starts the next
run. The existing terminal commit phase and publication receipt fences remain
unchanged. The coordinator is scoped to one terminal barrier, matching the prior
barrier-local tombstone and teardown-task lifetime.

Reset is an explicit barrier-lifecycle operation for tests or host teardown; normal
run-attempt transitions do not clear successor tombstones implicitly. This preserves
exactly-once behavior across retries and successor attempts while keeping stale
teardown completions fenced by ownership and token.

## Verification gates

- Domain settlement tests cover exactly-once delivery, failed-delivery retryability,
  bounded FIFO eviction, independent ownership tokens, stale completion rejection,
  idempotent registration, and reset.
- Agent run lifecycle and terminal commit focused tests remain green.
- Source-layout guardrails assert the Domain coordinator and reject the retired App
  successor tombstone fields.
- Swift formatting/linting, focused Domain tests, product builds, and `git diff
  --check` remain required before commit.
