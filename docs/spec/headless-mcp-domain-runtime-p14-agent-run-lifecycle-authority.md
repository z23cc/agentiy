# Headless MCP domain runtime — P14 Agent run lifecycle authority

Status: implemented (2026-08-30).

## Contract

P14 moves the provider-neutral Agent run-attempt ownership and liveness reducer into
`RepoPromptDomainRuntime`. `DomainAgentRunLifecycleTracker` is the sole semantic owner of a run's
binding identity, attempt ownership token, progress sequence, stage, retry intent, heartbeat time,
and real-progress time. App and headless hosts use the same reducer through immutable Sendable DTOs.

A run attempt captures tab ID, optional persistent session ID, persistent binding generation,
binding-transition generation, and an ephemeral activation generation. Every progress signal is
accepted only for the active ownership token, a strictly increasing sequence, and a non-decreasing
uptime timestamp. Stale ownership, duplicate/out-of-order sequence, and non-monotonic timestamp
signals are rejected deterministically. Heartbeats advance signal time but never manufacture real
progress. Ending an attempt requires the current ownership and resets the reducer for the next
attempt.

## Compatibility and ownership

- `AgentRunLifecycleContracts.swift` keeps the existing App names as typealiases to the Domain
  contracts. Existing Agent Mode, Context Builder, provider, and test call sites retain their
  source and wire behavior.
- `AgentRunAttemptLifecycle` remains an App facade for transient terminal-commit bookkeeping and
  App-only teardown resources. It delegates ownership/liveness state to the Domain reducer and does
  not publish transcript, persistence, provider, or UI state.
- `AgentRunAttemptTerminalResources` remains App-owned because its preparation closure captures
  `AgentSessionRunState` and presentation/provider cleanup. This is an adapter boundary, not a
  second lifecycle reducer.
- P14 does not change provider process transport, terminal publication, transcript serialization,
  MCP schemas, routing, persistence bytes, or cancellation wire behavior.

## Retirement and guards

- No production App source may re-declare `AgentRunLifecycleTracker`, ownership, progress, stage,
  retry, or liveness DTOs; the App file contains compatibility aliases only.
- `RepoPromptDomainRuntime` remains free of App/UI imports and `@MainActor` declarations.
- Source-layout guardrails require the Domain lifecycle contract and verify the compatibility alias
  surface, while allowing only the App terminal teardown resource class to remain local.

## Verification gates

- `DomainAgentRunLifecycleContractsTests` covers immutable epoch ownership, stale ownership,
  sequence/timestamp fences, heartbeat semantics, retry state, and exact-current end/reset.
- Existing `AgentRunLifecycleContractsTests` and `AgentRunAttemptLifecycleTests` continue to
  exercise the App compatibility aliases and terminal facade behavior.
- Focused Domain/App tests, product builds, SwiftFormat/SwiftLint, and source guardrails remain
  required before commit or push.
