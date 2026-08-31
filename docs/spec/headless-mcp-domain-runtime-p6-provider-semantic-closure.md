# P6 tail — provider semantic closure

Status: implemented (2026-08-31).

## Contract

P6's Rust transport owns provider process identity, process groups, stdout/stderr framing,
serialized stdin, ordered observations, cancellation, shutdown, and reaping. The P6 tail adds
the semantic boundary above that transport: every provider adapter emits a typed
`DomainAgentRunProviderTerminationSignal`, and `DomainAgentRunProviderSemanticAuthority` reduces that
signal to the existing `DomainAgentRunTerminalOutcome` before terminal commit.

The reducer is provider-neutral and never inspects provider payload text to choose a failure class.
`superseded` is explicitly non-terminal. A terminal outcome is the only value accepted by the
existing Domain terminal commit barrier, so provider adapters cannot publish a second semantic
result or bypass stale ownership checks.

## Signal vocabulary and precedence

The shared signal vocabulary is:

- `completed` and `cancelled`, with optional assistant text;
- `superseded`, which is dropped without terminal publication;
- `startupFailure` and `providerFailure`, which preserve deferred transcript classification when
  no typed failure reason is available;
- `timeout`, `processExited`, `transportClosed`, and `unexpectedEnd`, which carry fixed timeout or
  process-crash semantics regardless of display text.

Cancellation is canonical. An explicit typed failure reason wins over deferred classification.
Unknown setup or provider failures remain `failedWithoutClassification` so the existing transcript
and terminal settlement path can apply its bounded fallback without guessing from an error string.

## Production coverage

The following production paths use `DomainAgentRunExecutionCore.executeProvider`:

- Agent Mode Codex dispatch and coordinator finalization;
- ACP integrated runs;
- Claude native integrated runs;
- headless Agent Mode runs;
- DirectHeadless provider runs.

Codex watchdog timeout, transport-closed recovery, and unexpected stream end now preserve typed
signals. ACP and Claude EOF/startup/cancellation/provider failures use the same vocabulary. The
existing terminal commit barrier remains responsible for ownership, generation, replay receipt,
attachment disposition, transcript publication, and teardown; this phase does not move those
side effects into the reducer.

## Ownership and safety

Rust remains the sole process/byte transport authority. Domain Swift owns only the pure semantic
reducer and execution-core trace. App adapters retain protocol parsing, transcript/UI updates,
progress, permissions, recovery policy, and physical teardown. DirectHeadless retains its existing
one-shot process backend while adopting the same semantic entry point.

The existing runtime, registration, activation, attempt, terminal-commit, and settlement fences
remain unchanged. A stale callback or cancelled attempt cannot create a terminal receipt merely by
emitting a signal. A replayed terminal request continues to reuse the existing staged receipt, and
`supportedFollowUp`/provider successor behavior remains governed by the Domain settlement
coordinator.

## Compatibility and scope

No provider wire schema, command-line argument, transcript text, MCP schema, permission policy,
model catalog, persistence format, or external terminal message is intentionally changed. The
phase removes duplicate semantic mapping only. The subsequent M6B closure now provides the
production private endpoint/carrier handoff without changing this provider semantic boundary.

## Verification gates

- `DomainAgentRunProviderSemanticContractsTests` covers every signal, precedence, supersession,
  cancellation, unknown-error fallback, and deterministic execution traces.
- Existing ACP and Codex execution adapter suites pass with their historical terminal outcomes.
- Source-layout guardrails verify one provider semantic authority, all production adapters use
  `executeProvider`, and local terminal reducers do not reappear.
- Rust transport, UniFFI generation, Agentry/agentry-mcp builds, format/lint, and repository
  contribution preflight remain required before commit or push.
