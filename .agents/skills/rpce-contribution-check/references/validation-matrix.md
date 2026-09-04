# Agentry contribution validation matrix

Use this after the mandatory safety preflight when the touched boundary needs focused, PR-ready, release, or live-app evidence.

## Mandatory safety gates

| Gate | Required command / evidence |
| --- | --- |
| Before every commit | `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` runs whitespace checks, a redacted staged-index secret scan, and `make guardrails`. Rerun after any staging change. |
| Before every push | `.agents/skills/rpce-contribution-check/scripts/preflight.sh push` reruns commit safety, requires a clean working tree, prints the current-branch outgoing range, and runs a redacted outgoing-range secret scan. |

Default `push` is a safety gate. It does not run lint, test, conductor, product-build, or Xcode workspace validation lanes. Run focused commands during iteration, and run `.agents/skills/rpce-contribution-check/scripts/preflight.sh pr-ready` when a computed-outgoing-range path-selected local PR-ready pass is required. Conductor-coordinated Swift/Xcode-heavy lanes may report `global-wait` while another worktree holds the per-user heavy slot; wait on the conductor ticket instead of bypassing the daemon or starting redundant heavy jobs.

After timing initialization, `pr-ready` makes a best-effort attempt to write a local schema-v1 timing receipt under `.build/validation-artifacts/pr-ready/` and print its path on normal success or ordinary failure. The ignored receipt is measurement-only and non-gating: initialization, state-transition, collision, or publication failure is warning-only and cannot change the validation result. Receipt status is authoritative only for normal process completion; signal termination is deliberately not inferred from an exit code, and a receipt produced around HUP/INT/TERM is non-authoritative and may be absent. No receipt is promised for pre-initialization failure, any signal (including SIGKILL), process crash, or power loss. Receipts record UTC timestamps, monotonic elapsed durations, safe commit/range provenance, selection counts and lane IDs, and ordered phase outcomes; the schema-v1 `signal` field remains null. They deliberately exclude repository paths, usernames, remote URLs, changed filenames/path lists, raw commands or output, secret-scan findings, conductor tickets/logs, environment variables, and signing or credential data. `commit` and `push` do not emit timing receipts, and measurement does not alter validation command execution or the existing HUP/INT/TERM exit traps.

## Focused and PR-ready evidence

| Changed boundary | Focused / PR-ready evidence |
| --- | --- |
| `Scripts/conductor.py`, conductor/preflight control-plane tests, the contribution preflight script or timing helper, or `Makefile` conductor wiring | `make conductor-selftest`; included in `pr-ready` for these paths. |
| Swift files | `make dev-lint`; included in `pr-ready` for Swift paths. Run `make dev-format` first when formatting mutation is intended. Product compile remains explicit: `make dev-swift-build PRODUCT=Agentry` or `PRODUCT=agentry-mcp`. |
| Rust crates under `rust/crates/`, `rust/tools/`, `rust/bins/`, or `rust/fuzz/` | `make dev-cargo-test` (unit tests / `--lib`). Use `CARGO_TEST_KIND=full` for integration, process, and proptest suites. Included in `pr-ready` as unit tests only. |
| Generated UniFFI / C FFI boundary (`rust/tools/xtask/`, `rust/ffi-contract/`, `Sources/AgentryUniFFIRaw/Generated/`, `Sources/CAgentryRustCore/`) | `make dev-cargo-codegen-check`; included in `pr-ready` for these paths. |
| Rust lockfile or deny/audit policy (`rust/Cargo.toml`, `rust/Cargo.lock`, `rust/**/Cargo.toml`, `rust/deny.toml`, `rust/audit.toml`) | `make dev-cargo-deny`; included in `pr-ready` for these paths. Weekly hosted `cargo audit` is `.github/workflows/dependency-audit.yml`. |
| Generated Xcode workspace boundary (`Package.swift`, `Package.resolved`, `Makefile`, `Scripts/generate_xcode_workspace.py`, `Scripts/xcode_developer_workflow.sh`, `.github/workflows/xcode-workspace.yml`) | `make xcode-generator-test`; included in `pr-ready` for these paths. Changes to `Scripts/test_xcode_workspace_generator.py` run the same generator tests. Full `make xcode-validate` is explicit (`xcodebuild -list`) or `workflow_dispatch` on `Xcode Workspace Validation`. Docs-only Xcode architecture changes remain guardrails-only locally unless explicit validation is requested. |
| Packaging, MCP CLI/server, Agent Mode, or running-app-sensitive paths | Record non-disruptive `make dev-smoke` when an already-running CE debug app and installed debug CLI are available; request approval before `make dev-smoke-launch`, `make dev-run`, or relaunching the visible app. |
| Release-sensitive changes | Run explicit release validation such as `make dev-release-preflight`; use `make dev-release-artifact` only when artifact evidence is required. Release lanes are not part of default `push` or `pr-ready`. |
| History rewrite, branch deletion, fork deletion, force-push, credential rotation, other GitHub-visible destructive mutation, visible app launch/relaunch, or visible app stop | Obtain explicit user approval immediately before the destructive command; redact secret values from output. |

## Secret hygiene

- Treat obfuscated, encoded, or split credentials as secrets. Do not print their decoded values.
- Use `gitleaks` with `--redact` for materialized staged index blobs and outgoing commits.
- Do not commit local configuration, prompt exports, daemon logs, raw provider traces, or generated diagnostic artifacts unless the repository explicitly allows the exact path.
