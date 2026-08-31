# Rust Agent Provider P7-4 — Production certification and release hardening

Status: implemented (2026-08-31).

## Contract

P7-4 is a bounded certification and diagnostics phase after the Codex (P7-1),
ACP semantic/lifecycle (P7-2/P7-3), and Claude headless (P6-11) cutovers. It does
not add another provider runtime or a second semantic reducer. Rust remains the
production transport/semantic authority already established by those phases;
Swift remains the policy, transcript, permission, and UI adapter.

Rust exposes two identity-bound, read-only diagnostics for an open provider
scope:

- `agent_provider_conformance_snapshot` returns the immutable schema-versioned
  capability profile;
- `agent_provider_validate_conformance` compares that profile against the Rust
  canonical matrix and returns `valid` plus deterministic typed violations.

Neither operation starts a child process, allocates a JSON-RPC ID, writes stdin,
publishes an event, changes lifecycle state, or reads credentials/network state.
Invalid profile data is a report (`valid: false`), while identity/scope/runtime
errors remain ordinary fail-closed FFI errors.

## Canonical provider matrix

All three profiles own process lifetime, line framing, serialized stdin writes,
ordered events, bounded stderr, and process-exit terminal events.

| Profile | Semantic requests | Typed notifications/server requests/state | Token cancellation | Typed control receipts | JSON-RPC ID type | Generic send line | Start with stdin | Stream-result translation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `codexAppServer` | yes | yes | yes | no | yes | no | no | no |
| `acp` | yes | yes | yes | yes | yes | no | no | no |
| `claudeHeadless` | no | no | no | no | no | yes | yes | yes |

The matrix is frozen in
`Scripts/Fixtures/rust_agent_provider_p7_4_conformance.json`. The offline
validator rejects missing/extra keys, type drift, capability drift, live-soak
claims, and ABI-epoch changes without an explicit contract update.

## Certification gates

The synthetic gate is credential-free, network-free, and uses only bounded shell
children. Rust tests exercise all canonical profiles, every violation ordering,
identity fencing, and side-effect freedom. FFI/Bridge tests exercise generated
records and the Swift projection. Existing provider-session suites remain the
behavioral coverage for semantic requests, typed events, operation restrictions,
and lifecycle behavior; P7-4 certifies that those paths expose the frozen
ownership matrix rather than replaying each provider protocol. The
Make/Conductor `provider-conformance` gate validates the fixture without
launching the app; focused Rust and Swift commands provide the runtime
synthetic evidence.

Live provider credentials, external network connectivity, and visible-app
lifecycle/sleep-wake soaks are operational evidence and remain deferred. They
must be run separately with explicit authorization and must not be reported as
passing from this contract or its synthetic fixtures.

## Compatibility and ABI

The diagnostic exports are additive records/enums and retain ABI epoch 1. No MCP
wire schema, provider event envelope, transcript, persistence, permission
policy, model catalog, or production routing behavior changes in P7-4. Existing
`sendLine` restrictions remain: Codex and ACP use typed semantic APIs, while
Claude headless retains `startWithStdin` and stream-result translation.
