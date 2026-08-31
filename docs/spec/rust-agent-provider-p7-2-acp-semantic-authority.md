# Rust Agent Provider P7-2 — ACP Semantic Authority

Status: whole-stage implementation (2026-08-31).

## Contract

P7-1 made Codex app-server JSON-RPC semantics Rust-owned. P7-2 applies the same
boundary to ACP. For a Rust-backed ACP scope, Rust is the sole authority for
request identifiers, pending correlation, timeout and cancellation settlement,
response validation, inbound ordering, and protocol-error classification. Swift
retains ACP provider policy, permission decisions, session-update normalization,
UI events, and injected legacy fixtures.

ACP request identifiers preserve JSON-RPC type and wire spelling. Requests,
notifications, and server responses are emitted through typed FFI operations;
the generic `sendLine` operation rejects ACP scopes. A response with a remote
`error` settles the exact pending method as a typed error, while malformed
JSON-RPC objects, invalid IDs, unmatched responses, and missing result/error
produce bounded `protocolError` events and never execute a fallback parser.

## Events and lifecycle

Rust publishes `notification` and `serverRequest` events with the original
method, params, request ID, exact encoded ID (`id_json`), and a monotonic
inbound sequence. Matching responses are consumed by the pending reducer and
are not re-emitted as opaque `providerMessage` payloads. Process lifecycle
observations retain the existing scope sequence and terminal shutdown behavior.

`initialize` success marks the ACP lifecycle `initialized`; all other running
scopes report `running`. Scope identity, process exit, shutdown, and close are
fail-closed. Closing or exiting settles every pending request with the typed
terminal error and leaves no pending state behind. Cancellation is token-scoped,
removes only the matching pending request, and is idempotent for unknown tokens.

## FFI and Swift cutover

UniFFI exposes typed ACP request/cancel/notify/respond/respond-error/state
operations and typed ACP error cases. `CoreAgentProviderSession` and
`AcpRuntimeSession` forward those operations without rebuilding JSON-RPC
semantics. The ACP controller consumes Rust `notification`, `serverRequest`,
and `protocolError` events; its Swift JSON parser remains only for explicitly
injected non-Rust test sessions.

The production ACP factories (OpenCode, Cursor, GrokBuild, Agent Mode, and
headless/model polling paths) continue to use the shared Rust runtime transport.
No ACP wire method, provider policy, permission outcome, session-update
normalization, or external event behavior changes.

## Verification gates

- Rust runtime tests cover typed request settlement, remote error, timeout,
  cancellation boundary, notification/server-request events, malformed input,
  and rejection of opaque writes.
- Bridge tests cover typed ACP events, exact encoded request IDs, typed request
  and lifecycle state, cancellation, and malformed-line diagnostics.
- Generated UniFFI bindings are deterministic and drift-free; both products,
  formatting, lint, source guardrails, and focused ACP tests pass.
