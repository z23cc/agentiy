# Rust Agent Provider Runtime Authority v1

Status: P7-3 whole-stage implementation baseline (Codex/ACP semantic and ACP lifecycle authority; Claude headless remains on the P6 translator contract)

## 1. Scope

P6 moved provider process and byte transport ownership behind one Rust runtime
boundary. P7-1 completed the Codex app-server semantic handoff; P7-2 completes
the equivalent ACP handoff without changing either wire protocol. Rust owns
JSON-RPC request IDs, pending response settlement, bounded deadlines,
response/error decoding, notification and server-request classification, and the
ACP lifecycle/control receipts needed by controllers. ACP session and prompt
identity are generation-fenced by Rust; Swift cannot acknowledge an outbound
control write until the Rust serialized writer returns its receipt. Claude headless remains translator-
owned because its stream-json output is not JSON-RPC.

The production path is:

```
Swift provider policy/controller
  -> AgentProviderRuntimeTransport
  -> AgentryCoreBridge / UniFFI
  -> runtime::agent_provider::ScopeRegistry
  -> provider JSON-RPC reducer (Codex or ACP)
  -> child process, line framing, stdin serialization, reaper
```

Swift retains launch policy, model pagination, permission decisions, normalized
UI events, persistence, and presentation mapping. It no longer allocates or
settles requests for a Rust-backed Codex or ACP scope.

## 2. Rust ownership contract

For each Codex or ACP scope Rust owns:

- command/environment/working-directory launch configuration and process group;
- stdout line framing, bounded stderr-tail capture, serialized stdin writes;
- request IDs starting at one, a bounded pending map, response/error settlement,
  duplicate/unknown response suppression, optional per-request timeout, and
  token-scoped cancellation;
- JSON-RPC identifier type preservation (`1` and `"1"` are distinct), structured
  remote error data, notification/server-request classification, and malformed
  message diagnostics;
- protocol-specific lifecycle facts and immutable state snapshots;
- ACP authenticated/session/prompt lifecycle, monotonic session and prompt
  generations, and typed receipts for every notification/server response;
- one monotonic scope sequence plus monotonic inbound JSON-RPC sequence;
- identity validation, cancellation-safe terminal shutdown, and process reaping.

Swift must not create a second process, install a second stdout reader, allocate
Codex/ACP request IDs, or write directly to provider stdin when a Rust-backed
session is supplied. The generic `sendLine` API rejects both Codex and ACP
scopes; Claude headless keeps its one-shot start-with-stdin operation.

## 3. Event envelope

Every published provider observation is a UTF-8 JSON object:

```json
{
  "v": 1,
  "provider": "codexAppServer" | "acp" | "claudeHeadless",
  "scope_id": "32 lowercase hexadecimal characters",
  "sequence": 1,
  "kind": "processStarted" | "notification" | "serverRequest" |
           "protocolError" | "streamResult" | "outbound" | "stderr" |
           "stderrTail" | "processExited" | "scopeClosed",
  "payload": {}
}
```

Codex and ACP responses matching a Rust pending request are settled internally
and are not re-emitted as opaque `providerMessage` observations. Notifications
carry `{ method, params, inbound_sequence }`; server requests additionally carry
the original JSON-RPC `id` and ACP carries its exact encoded `id_json`.
Malformed or structurally invalid lines produce a bounded `protocolError`
observation. Claude headless keeps its translator-owned `streamResult`
projection.

`sequence` is strictly monotonic within a scope. Terminal kinds are lossless;
queue gaps and rejected payload markers retain their existing generic-subscription
meaning and are never reinterpreted as provider protocol messages.

## 4. FFI and lifetime rules

`agent_provider_open_scope` returns both the opaque provider scope ID and the
Rust-computed generic subscription scope ID. Codex and ACP expose typed
request/cancel/notify/respond/respond-error/state operations. ACP notify/respond
operations return a lifecycle receipt carrying the Rust outbound sequence,
current lifecycle, session generation, and active prompt generation. Response IDs cross
FFI as encoded JSON values so numeric/string identity is preserved. Blocking
Rust requests are invoked from Swift through a detached bridge operation so the
bridge actor continues draining notifications and server requests. A nil
deadline is unbounded; Swift passes its configured default explicitly when
requested.

Every call carries runtime identity and is fail-closed on mismatch, scope close,
invalid JSON, timeout, cancellation, remote error, or invalid response. Natural
process exit and shutdown settle all matching pending requests before returning;
shutdown is idempotent and reaps the process. The generic subscription is closed
by the Swift session owner.

## 5. Provider cutover

Every production Codex and ACP factory (Agent Mode, model polling, auth recovery,
conversation cleanup, OpenCode, Cursor, and GrokBuild) supplies
`CoreAgentProviderRuntimeTransport`. Rust-backed sessions expose the
`CodexAppServerRuntimeSession` or `AcpRuntimeSession` capability. that capability for request, cancellation, notification, and server-request
response paths; runtime ACP control writes are awaited and write failures are
reported to the initiating actor turn. The old Swift pending/correlation/parser
path remains only for explicitly injected legacy test clients.

Swift translates only Rust `notification`, `serverRequest`, `protocolError`,
`stderr`, and terminal observations into existing controller events. No Codex or
ACP semantic result is synthesized by the generic transport facade.

## 6. Done-when for P7

- Codex and ACP production sessions use Rust semantic request/response authority.
- No Rust-backed Codex or ACP call uses opaque `providerMessage`, generic
  `sendLine`, or Swift request-ID/pending settlement.
- Runtime, FFI, bridge, and provider tests cover identity, request settlement,
  timeout/error handling (including structured remote error data), notification/
  server-request events, ACP lifecycle/session/prompt generations and typed
  receipts, malformed input, ID-type separation, cancellation, and terminal
  shutdown.
- Generated UniFFI bindings are deterministic and drift-free.
- External Codex/ACP wire behavior, provider policy, normalized events,
  permissions, and Claude headless compatibility remain unchanged.
