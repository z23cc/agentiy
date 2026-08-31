# Rust Agent Provider P7-3 — ACP lifecycle and control-plane authority

Status: implemented (2026-08-31).

## Contract

P7-2 moved ACP JSON-RPC correlation and semantic inbound classification into the
Rust provider runtime. P7-3 closes the remaining lifecycle/control-plane split.
Rust is the only authority for ACP lifecycle state, session identity generation,
prompt generation, serialized outbound ordering, and control write receipts.
Swift keeps provider policy, permission matching, session-update normalization,
model/config normalization, and UI mapping.

An ACP state snapshot contains:

- lifecycle (`created`, `running`, `initialized`, `authenticated`, `sessionOpen`,
  `promptRunning`, or `closed`);
- initialized/authenticated facts;
- current session ID and monotonic session generation;
- monotonic prompt generation and optional active prompt generation;
- pending request count.

`session/new` and `session/load` establish a session generation only after a
validated response. `session/prompt` reserves a new prompt generation at the
serialized write boundary and exposes it while the request is pending. Successful
completion, cancellation, timeout, process exit, or scope close clears the active
prompt without rewinding the generation. A cancel notification only affects the
matching current session.

## Typed receipts and write failure

Every ACP request response carries the outbound sequence that created the request
and the lifecycle/session/prompt generation observed when Rust settled it. Every
ACP notification, response, or error response returns a control receipt with the
same sequence and generation fence. The receipt is produced only after the shared
Rust stdin writer accepts the complete newline-delimited frame.

Production `ACPAgentSessionController` calls await these typed operations. A write
failure therefore remains in the initiating actor turn and transitions the
controller through its existing runtime failure path. No fire-and-forget task may
write ACP control messages or report a success before Rust has accepted the frame.
The legacy synchronous `sendJSONLine` and Swift pending-request parser remain only
for explicitly injected non-Rust test sessions.

## Generation and shutdown rules

- Session generation increments only when the validated session ID changes.
- Prompt generation is monotonic for every accepted prompt request, including a
  request that later fails or is cancelled.
- A stale session cancel cannot clear a newer session's active prompt.
- Scope close and natural process exit mark lifecycle `closed`, clear active prompt
  state, and settle every pending request before emitting terminal scope events.
- Runtime identity validation remains mandatory on every FFI operation.
- Provider-specific ACP semantics are not duplicated in Rust; only transport,
  lifecycle, generation, and control acknowledgement are authoritative there.

## Verification gates

- Rust runtime tests cover lifecycle transitions, session/prompt generation,
  typed response/control receipts, cancellation, timeout, process exit, and
  structured protocol failures.
- FFI and Bridge tests compile against generated receipt/state records and preserve
  deterministic UniFFI output.
- ACP controller tests cover awaited runtime writes and legacy parser compatibility.
- Source guardrails reject runtime fire-and-forget ACP writes and require the
  lifecycle/control receipt seam.
- Existing ACP wire messages, permission outcomes, normalized events, and provider
  policy remain unchanged.
