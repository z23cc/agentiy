# `agentry-mcp` (Rust, agent-host only)

ADR-0011 P7 Agent Session Host as a mode of `agentry-mcp`
(design §4.1, §8 P7). This crate is **not** the full MCP CLI; the Swift
`RepoPromptMCP` product still owns `agent_run` / interactive / exec.

```text
agentry-mcp agent-host [--idle-exit-seconds N]
```

The Cargo binary keeps the name `agentry-mcp` and lives under
`.build/cargo/` (workspace `CARGO_TARGET_DIR`). The app bundle installs it
as `Contents/MacOS/agentry-agent-host` so it cannot be confused with the
Swift CLI at `Contents/MacOS/agentry-mcp`. Clients spawn that helper with
argv `agent-host`.

Paths match `AgentSessionHostPaths` / design §5.1:

- socket: `/tmp/agentry-mcp-<uid>/agentry-agent-host-{D-}<v>.sock` (dir `0700`)
- isolated socket when `AGENTRY_APPLICATION_SUPPORT_ROOT` is set:
  `/tmp/agentry-mcp-<uid>/hosts/<sha256(root)[0:12]>/…`
- lease: `<Application Support>/.agentry-domain-runtime/locks/agent-host-v1.lock`

`SessionRouter` maps `sessionID → SessionExecutor`. Production default is
`HostedRuntimeExecutor`: the router appends `AgentSessionLog` and folds
`agent_session_transcript::SessionState`; the executor applies
`agent_run_lifecycle` and `agent_provider_semantics` over a
`ProviderTransport`.

Production clients set `AGENTRY_AGENT_HOST_LIVE=1` (plus the GUI build
fingerprint) so Claude uses interactive `AgentClaudeScope` and Codex/ACP
use `agent_provider` + `provider_json_rpc`. Tests leave live off and keep
`ScriptedTransport`. A required credential that cannot be redeemed
fail-closes via `UnattachedTransport`. Secrets stay in the host process;
they never enter the wire.

`StubExecutor` remains only for test hooks (`leave-unsettled`,
`fail-checkpoint`, `flood:N`).
