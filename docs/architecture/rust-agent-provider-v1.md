# Rust Agent Provider Runtime Authority v1

Status: P6 whole-stage implementation baseline (Codex app-server, ACP, and Claude headless one-shot)

## 1. Scope

P6 moves the provider **process and byte transport data plane** behind one Rust
runtime authority. The authority is shared by the native Codex app-server, ACP
provider families, and Claude Code's headless one-shot mode. Codex/ACP remain
opaque at this boundary; the Claude headless protocol tag opts into the
already-reviewed Rust Claude NDJSON translator.

The production path is:

```
Swift provider policy/controller
  -> AgentProviderRuntimeTransport
  -> AgentryCoreBridge / UniFFI
  -> runtime::agent_provider::ScopeRegistry
  -> child process, line framing, stdin serialization, reaper
  (Claude headless additionally -> Claude NDJSON translator)
```

Codex and ACP still own their protocol-specific request/response correlation,
permission policy, model/configuration policy, normalized events, persistence,
and user-facing diagnostics. They receive the same ordered provider payloads
that their legacy readers handled. Claude headless receives a complete,
translator-owned stream-result projection and only maps it into the existing
provider-neutral DTO.

## 2. Rust ownership contract

For each provider scope Rust owns:

- command/environment/working-directory launch configuration;
- process-group spawn and registration with the shared reaper;
- stdout line framing and stderr bounded-tail capture;
- serialized stdin writes: `sendLine` appends exactly one newline for Codex/ACP, while Claude headless `start_with_stdin` writes the exact prompt bytes and closes stdin for EOF-driven one-shot execution;
- one monotonic sequence for outbound and inbound observations;
- cancellation, idempotent shutdown, and process reaping;
- runtime-identity validation and scope lifetime;
- exactly two per-scope reader threads (stdout/stderr) plus the existing one shared
  reaper thread; reaping does not add an exit-watcher thread per process.

Swift must not create a second process, install a second stdout/stderr reader,
or write directly to the provider stdin when a Rust-backed session is supplied.

## 3. Event envelope

Every published provider observation is a UTF-8 JSON object:

```json
{
  "v": 1,
  "provider": "codexAppServer" | "acp" | "claudeHeadless",
  "scope_id": "32 lowercase hexadecimal characters",
  "sequence": 1,
  "kind": "processStarted" | "providerMessage" | "streamResult" |
           "outbound" | "stderr" | "stderrTail" | "processExited" | "scopeClosed",
  "payload": {}
}
```

For `claudeHeadless`, `streamResult` carries `{ "pid": ..., "result": ... }`,
where `result` uses the complete Rust `StreamResult` field projection. Startup
uses one `start_with_stdin` operation that writes the prompt and closes stdin;
the generic `sendLine` API remains unchanged for Codex/ACP.

`sequence` is strictly monotonic within a scope and is assigned by Rust.
Terminal kinds (`processExited` and `scopeClosed`) are lossless events. Claude headless
`processExited` includes `timed_out: true` when Rust's 6,000-second one-shot deadline fires.
For Codex/ACP, provider payloads that are not valid JSON are retained as a UTF-8-lossy string
inside a `providerMessage` payload instead of being silently discarded; Claude headless keeps the
translator's existing malformed-line suppression behavior.

The generic core subscription queue remains the delivery boundary. Queue gaps
and rejected payload markers retain their existing meaning and are never
reinterpreted as provider protocol messages.

## 4. FFI and lifetime rules

`agent_provider_open_scope` returns both the opaque provider scope ID and the
Rust-computed generic subscription scope ID. Callers use that returned ID for
`openSubscription`; Swift must not derive it independently. Every subsequent
start/send/shutdown call carries the runtime identity and is fail-closed on an
identity mismatch. Shutdown is idempotent and closes the process scope before
returning; the generic subscription is closed by the Swift stream/session owner (including the session shutdown and deinit backstops).

The authority is an in-process scope of the existing `CoreRuntime`; no second
Rust executable or persistence schema is introduced. Existing lease, routing,
transcript, and provider configuration behavior is unchanged.

## 5. Provider cutover

Every production Codex, ACP, and Claude headless factory (Agent Mode, headless discovery,
model polling, auth recovery, and conversation cleanup) supplies
`CoreAgentProviderRuntimeTransport` to its controller/client. Tests and
explicitly injected maintenance clients may continue to use their existing
process doubles. When a Rust-backed session
is present, controller logic only translates:

- Rust `providerMessage` payloads into the existing provider JSON-line parser;
- Rust `stderr` observations into existing diagnostics;
- Rust terminal observations into the existing process-failure state machine;
- Claude `streamResult` fields into the existing `AIStreamResult` DTO.

No provider semantic result is synthesized by Swift or by the generic transport facade.

## 6. Done-when for P6

- Codex and ACP production factories use the same Rust transport authority.
- No production provider path starts a duplicate process or writes around the
  authority when the Rust session is active.
- Runtime, FFI, bridge, and controller tests cover identity, scope lifetime,
  ordered payload delivery, malformed payload preservation, write failure,
  terminal shutdown, and provider-specific parser parity.
- Generated UniFFI bindings are deterministic and drift-free.
- Existing provider-specific policy and normalized external behavior remain
  unchanged; semantic-provider migration is explicitly outside this transport
  stage.
