# Headless MCP domain runtime — P13 agent-session identity authority

Status: implemented (2026-08-30).

## Contract

P13 moves the pure Agent session identity and mutation-admission decisions into
`RepoPromptDomainRuntime`. `DomainAgentSessionLifecycleDecisionAuthority` is a stateless,
UI-neutral value authority shared by the App and headless compositions. It owns the immutable
identity shape, protection facts, mutation target, admission decision, and typed rejection reasons.
The existing `AgentSessionLifecycleAuthority` remains an App-facing compatibility facade only.

Every mutation target is fenced by workspace ID, tab ID, optional session ID, persistent binding
generation, and binding-transition generation. A missing tab, changed session, changed binding, or
changed transition returns a deterministic typed rejection. Admission first requires an accepted
persistence fact, then an exact target workspace match, then a still-current binding; adapters do
not reorder or duplicate these predicates.

Protection facts are also domain-neutral. A tab is protected when it is live or pinned; active/run
flags remain evidence carried by the fact and are not interpreted independently by presentation
callers. Persistence crosses the boundary as `DomainAgentSessionPersistenceFact`, so the Domain
never imports `WorkspacePersistenceOutcome`, `WorkspaceModel`, SwiftUI, AppKit, or `@MainActor`.

## Compatibility and ownership

- App call sites keep the existing nested `AgentSessionLifecycleAuthority` type names through
  typealiases and continue to receive the same raw values, errors, and admission outcomes.
- App-only projection reconciliation still owns `WorkspaceModel` merge/ordering behavior and
  event logging. It consumes Domain-derived protection state and cannot redefine admission.
- The existing `DomainAgentSessionAuthority` actor remains the durable registration, epoch,
  waiter, terminal-settlement, metadata, and event authority from P12. P13 does not introduce a
  second durable session store or alter transcript serialization, provider wire messages, MCP
  schemas, routing, or persistence bytes.
- Headless compositions can use the decision authority directly without constructing App objects.

## Retirement and guards

- No production lifecycle predicate may compare session/binding/transition identity outside the
  Domain decision authority and its compatibility facade.
- `RepoPromptDomainRuntime` must remain free of UI imports and `@MainActor` declarations.
- The source-layout guard requires the Domain authority and verifies that the App facade delegates
  mutation validation and admission to it.

## Verification gates

- `DomainAgentSessionLifecycleAuthorityTests` covers protection facts, successful validation,
  every identity fence, and persistence/workspace/binding admission ordering.
- Existing App background-compose admission tests continue to exercise compatibility aliases and
  projection behavior.
- Focused Domain tests, product builds, SwiftFormat/SwiftLint, and source guardrails remain
  required before commit or push.
