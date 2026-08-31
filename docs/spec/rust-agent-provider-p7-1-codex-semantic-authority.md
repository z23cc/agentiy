# P7-1 Codex App Server Semantic Authority

Status: implemented (2026-08-31)

## Contract

P6 owns provider process lifetime and byte transport. P7-1 moves the Codex
app-server JSON-RPC semantic boundary into the same Rust scope. Rust allocates
request IDs, records pending requests before writing, settles responses exactly
once, applies an optional request deadline, supports token-scoped cancellation,
and classifies notifications and server requests. ACP was intentionally not
changed by P7-1; it is completed by the follow-on P7-2 contract.

A Codex request is admitted only after runtime identity and scope checks. Method,
params, response, and server-request IDs are validated at the Rust boundary. Numeric and string
JSON-RPC IDs remain distinct across the bridge, and remote error `data` is preserved as bounded
JSON bytes. Unknown or duplicate response IDs are ignored, malformed lines produce a bounded
`protocolError` event, remote JSON-RPC errors remain typed failures, and timeout
removes the pending entry before returning. A cancellation token removes only its
matching pending request and wakes that waiter; cancellation raced before
admission is remembered in a bounded tombstone set. Closing a scope resolves
every pending waiter with the terminal scope error.

## Dispatch

The FFI surface exposes `codexRequest`, `codexCancel`, `codexNotify`,
`codexRespond`, `codexRespondError`, and `codexState`. Response IDs cross the bridge as encoded
JSON values rather than strings, preserving the JSON-RPC ID type. A nil timeout means no
Rust deadline; callers that need the client default pass that value explicitly. The potentially blocking request call is
performed from a detached Swift bridge operation; Rust reader threads continue
publishing notifications and server requests through the existing subscription.
Request responses are consumed by Rust and are never emitted as
`providerMessage`. Swift maps only the typed event payloads into existing Codex
controller streams.

The generic provider `sendLine` operation rejects Codex scopes. P7-2 applies the
same rejection and typed semantic capability to ACP; see
`rust-agent-provider-p7-2-acp-semantic-authority.md`. Swift's old request
correlation and JSON recovery remain available only to explicitly injected
legacy test doubles, not to a Rust-backed production Codex or ACP session.

## Lifecycle and compatibility

Rust state records `created`, `initialized`, `threadReady`, and `turnStarted`
facts, with optional thread and turn identifiers and a bounded pending count.
Process-start, stderr, process-exit, and scope-close events retain their P6
ordering and sequence semantics. No Codex wire method, request shape, permission
policy, model pagination behavior, persistence format, or ACP behavior changes
as part of P7-1; ACP compatibility is covered by the P7-2 contract.

## Verification gates

- Rust provider runtime tests cover opaque-send rejection, real JSON-RPC response
  settlement, typed remote errors/timeouts, natural-exit settlement, and lifecycle
  state; Bridge tests additionally cover token-scoped cancellation.
- Bridge tests cover notification classification, Codex request settlement, cancellation, and
  state projection; Rust tests also cover ID-type separation and structured remote error data.
  ACP malformed payload and Claude translation regressions stay
  green.
- UniFFI generation/check, Agentry and agentry-mcp builds, formatting, lint,
  source guardrails, and `git diff --check` are required before commit.
