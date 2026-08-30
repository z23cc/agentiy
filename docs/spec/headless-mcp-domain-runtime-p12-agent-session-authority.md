# Headless MCP domain runtime — P12 agent-session authority

Status: implemented (2026-08-30).

## Contract

P12 names the existing runtime lifecycle store by its actual ownership: **`DomainAgentSessionAuthority`**
is the single domain authority for agent-session registration, turn epochs, parked waiters,
terminal settlement, resumability metadata, cancellation and shutdown. The former
`DomainAgentRunSessionStore` name remains a source-compatible typealias for app/MCP adapters;
it is not a second store and must not be instantiated as an independent authority.

The authority owns the runtime identity and generation fences. Every registration and epoch is
bound to those fences plus the session ID. A stale registration, stale runtime, stale epoch or
post-shutdown operation is rejected without changing durable state. Terminal publication is
exactly-once per epoch: the same commit ID is idempotent, while a different commit ID is a typed
conflict. Waiter continuations keep their existing timeout, cancellation and wake dispositions;
P12 does not replace them with polling or a shared stream.

## Canonical event projection

Each accepted lifecycle transition emits one ordered `DomainAgentSessionEvent` with a monotonic
runtime-local sequence, typed kind, optional registration/epoch and optional terminal commit ID.
The bounded tail is capped at 256 events, and `sessionEventHistory` provides a deterministic
session filter plus an exclusive `afterSequence` cursor. Pagination returns `nextSequence` only
when the bounded page is truncated. The `sessionEvents()` stream uses `bufferingNewest(1)`;
consumers replay by sequence and cannot turn observability into an unbounded queue.

Events are emitted only after the owning state transition has passed its existing fences:
registration, resume, epoch begin, accepted snapshot, terminal publication, cleanup, expiry and
shutdown begin/completion. Rejected or duplicate terminal attempts do not create a second accepted
event. Event delivery is diagnostic/projection evidence; provider wire messages and MCP wait
responses remain unchanged.

## Durable boundary and compatibility

Resumability metadata continues to use the existing profile-scoped `DomainPersistenceCoordinator`
document, advisory locking, digest CAS, bounded retention and degraded read-only behavior. The
metadata is never interpreted as proof that a provider process is alive. Legacy metadata remains
byte-preserved on corrupt, future-version, wrong-profile and ownership-conflict input. P12 changes
the authority name and adds the event projection; it does not change the durable metadata schema,
transcript serialization v7, provider cleanup, workspace routing or MCP wire format.

`DomainRuntimeSnapshot` exposes the authority event sequence and bounded-tail count alongside the
existing persistence-health and activity fields. The event tail is runtime-local evidence and is
replayable only within its bounded lifetime; durable resumability remains the existing metadata
CAS document. Runtime startup/bootstrap and shutdown use the same authority instance. App
`AgentRunSessionStore` and direct/headless MCP adapters continue to compile through the
compatibility alias while new domain code should name the authority directly.

## Retirement and guards

- No production code may create a second agent-session lifecycle store.
- `DomainAgentRunSessionStore` is compatibility vocabulary only; authority implementation and
  event projection live in `RepoPromptDomainRuntime`.
- Event history is bounded and cursor-based; no caller may retain or mutate authority internals.
- Existing `DomainActivityCenter` remains the live activity stream; P12 session events are the
  canonical runtime lifecycle projection and are intentionally separate from activity publication
  sequence.

## Verification gates

- `DomainAgentRunSessionStoreTests` covers ordered event history, session filtering, pagination,
  duplicate terminal fencing, stale registration and shutdown races.
- Domain runtime builds with the compatibility alias and reports event counters in snapshots.
- M5 contract fixture names `DomainAgentSessionAuthority` as the canonical session store.
- Rust archive/codegen, focused Domain tests, SwiftFormat/SwiftLint, product builds and source
  guardrails remain required before commit or push.
