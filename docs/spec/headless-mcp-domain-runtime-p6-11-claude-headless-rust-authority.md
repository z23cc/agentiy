# Headless MCP domain runtime P6-11 — Claude one-shot Rust authority

Status: **implemented** (2026-08-31).

## Contract

Claude Code discovery and headless Agent Mode runs use the CLI's one-shot
`-p --verbose --output-format stream-json` lifecycle. Swift remains responsible
for MCP availability, credential/config leases, compatible-backend environment
resolution, prompt delivery, and the existing app-facing `AIStreamResult` DTO.
Rust is the only production owner of process spawn, process-group teardown,
stdin delivery/EOF, line framing, NDJSON translation, tool-use correlation,
stream-result field projection, stderr tail, and terminal process events.

The Rust provider scope is protocol-tagged `claudeHeadless`. A single
`startWithStdin` operation writes the complete UTF-8 prompt and closes stdin;
there is no second Swift writer and no opportunity for a child to remain blocked
waiting for more input. The existing Codex/ACP protocol variants retain their
opaque provider-message behavior.

## Event and failure rules

Each translated result is published as one sequenced `streamResult` envelope
whose `result` field uses the same complete field set as the interactive Claude
scope (`type`, content/reasoning, usage/cost, tool metadata, provider session,
stop reason, context and model fields). Rust applies the reviewed Claude
translator suppression rules before publication. `processStarted`, `stderrTail`
and terminal `processExited` remain lossless lifecycle facts. Rust enforces the
legacy 6,000-second one-shot deadline and marks timeout terminal events with
`timed_out`; Swift maps that bit to the existing retryable timeout message. Swift
maps only the typed field projection and existing provider-facing error messages;
malformed or unsupported provider lines produce no user-facing result, matching
the prior translator behavior.

The scope identity and runtime identity are checked at every FFI command. Scope
shutdown is idempotent, process-group based and reaper-owned. A failed exit or
non-zero status is surfaced only after the stream has drained; a successful
`message_stop` result remains authoritative for the normal one-shot completion.
No raw prompt, environment value, credential, or result body is added to Rust
diagnostics.

## Migration boundary

`ClaudeCodeAgentProvider` and its `CLIProcessRunner` production path are retired.
`ClaudeRustBackedHeadlessAgentProvider` keeps the same `HeadlessAgentProvider`
surface and delegates argument construction and prompt packaging to the existing
Claude-compatible package bridge. The interactive `CoreAgentSession` contract,
ACP/Codex transport, MCP wire schemas, and external provider behavior remain
unchanged.

## Verification gates

- Rust provider scope tests cover protocol tagging, prompt EOF, translated
  content/final result/session identity, ordered events, and absence of the old
  opaque-message path.
- FFI/Bridge tests cover the Claude headless enum and translated stream result
  projection through the real generated bindings.
- Generated UniFFI bindings are deterministic; Rust/FFI, focused Swift provider
  tests, product builds, format/lint, source guardrails and `git diff --check`
  are required before commit.
