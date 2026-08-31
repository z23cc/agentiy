# Rust Agent Provider Runtime Authority v1

Status: P7-1 whole-stage implementation baseline (Codex semantic authority; ACP and Claude headless remain on their P6 contracts)

## 1. Scope

P6 moved provider process and byte transport ownership behind one Rust runtime
boundary. P7-1 completes the Codex app-server semantic handoff without changing
its wire protocol: Rust now owns JSON-RPC request IDs, pending response
settlement, bounded deadlines, response/error decoding, notification and server
request classification, and the small lifecycle state needed by controllers.
ACP remains opaque and is intentionally excluded from this phase.

The production path is:

```
Swift provider policy/controller
  -> AgentProviderRuntimeTransport
  -> AgentryCoreBridge / UniFFI
  -> runtime::agent_provider::ScopeRegistry
  -> Codex semantic reducer (request/response + events)
  -> child process, line framing, stdin serialization, reaper
```

Swift retains launch policy, model pagination, permission decisions, normalized
UI events, persistence, and presentation mapping. It no longer allocates or
settles requests for a Rust-backed Codex scope.

## 2. Rust ownership contract

For each Codex scope Rust owns:

- command/environment/working-directory launch configuration and process group;
- stdout line framing, bounded stderr-tail capture, serialized stdin writes;
- request IDs starting at one, a bounded pending map, response/error settlement,
  duplicate/unknown response suppression, optional per-request timeout, and token-scoped cancellation;
  numeric and string JSON-RPC IDs are distinct, and remote error `data` remains structured JSON bytes;
- JSON-RPC notification and server-request classification;
- initialize/thread/turn lifecycle facts and an immutable state snapshot;
- one monotonic sequence for outbound and inbound observations;
- identity validation, cancellation-safe terminal shutdown, and process reaping.

Swift must not create a second process, install a second stdout reader, allocate
Codex request IDs, or write directly to provider stdin when a Rust-backed session
is supplied. The generic `sendLine` API rejects Codex scopes; ACP retains it.

## 3. Event envelope

Every published provider observation is a UTF-8 JSON object:

```json
{
  "v": 1,
  "provider": "codexAppServer" | "acp" | "claudeHeadless",
  "scope_id": "32 lowercase hexadecimal characters",
  "sequence": 1,
  "kind": "processStarted" | "notification" | "serverRequest" |
           "protocolError" | "providerMessage" | "streamResult" |
           "outbound" | "stderr" | "stderrTail" | "processExited" | "scopeClosed",
  "payload": {}
}
```

Codex responses matching a Rust pending request are settled internally and are
not re-emitted as opaque provider messages. Notifications carry `{ method,
params }`; server requests additionally carry the original JSON-RPC `id`.
Malformed or structurally invalid lines produce a bounded `protocolError`
observation. ACP still preserves malformed payloads as `providerMessage`, while
Claude headless keeps its translator-owned `streamResult` projection.

`sequence` is strictly monotonic within a scope. Terminal kinds are lossless;
queue gaps and rejected payload markers retain their existing generic-subscription
meaning and are never reinterpreted as provider protocol messages.

## 4. FFI and lifetime rules

`agent_provider_open_scope` returns both the opaque provider scope ID and the
Rust-computed generic subscription scope ID. Codex additionally exposes typed
request/cancel/notify/respond/respond-error/state operations. Response IDs cross FFI as encoded JSON
values so numeric/string identity is preserved. The blocking Rust request is invoked from Swift through a detached bridge operation so the bridge
actor continues draining notifications and server requests. A nil deadline is
unbounded; the Swift client passes its configured default explicitly when requested.

Every call carries runtime identity and is fail-closed on mismatch, scope close,
invalid JSON, timeout, cancellation, remote error, or invalid response. Natural
process exit and shutdown settle all matching pending requests before returning;
shutdown is idempotent and reaps the process. The generic subscription is closed
by the Swift session owner.

## 5. Provider cutover

Every production Codex factory (Agent Mode, model polling, auth recovery, and
conversation cleanup) supplies `CoreAgentProviderRuntimeTransport`. A
Rust-backed Codex session is returned as the `CodexAppServerRuntimeSession`
capability. The client uses that capability for request, cancellation, notify, and
server request response paths; the old Swift pending/correlation/parser path remains
only for explicitly injected legacy test clients. ACP and Claude headless
continue to use their existing P6 adapters.

Swift translates only Rust `notification`, `serverRequest`, `stderr`, and
terminal observations into existing controller events. No Codex semantic result
is synthesized by the generic transport facade.

## 6. Done-when for P7-1

- Codex production factories use Rust semantic request/response authority.
- No Rust-backed Codex call uses opaque `providerMessage`, generic `sendLine`, or
  Swift request-ID/pending settlement.
- Runtime, FFI, bridge, and Codex tests cover identity, request settlement,
  timeout/error handling (including structured remote error data), notification/server-request events,
  lifecycle state, malformed input, ID-type separation, and terminal shutdown.
- Generated UniFFI bindings are deterministic and drift-free.
- External Codex wire behavior, provider policy, normalized events, and ACP
  compatibility remain unchanged.
