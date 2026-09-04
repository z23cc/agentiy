# Agentry contribution validation matrix

Use this after the mandatory safety preflight when the touched boundary needs focused evidence. Nothing here is auto-selected by `preflight.sh`.

## Mandatory safety gates

| Gate | Required command / evidence |
| --- | --- |
| Before every commit | `.agents/skills/rpce-contribution-check/scripts/preflight.sh commit` — whitespace, redacted staged-index secret scan, `make guardrails`. Rerun after any staging change. |
| Before every push | `.agents/skills/rpce-contribution-check/scripts/preflight.sh push` — commit safety, clean working tree, outgoing range, redacted outgoing-range secret scan. `pr-ready` is the same command. |

## Run yourself when the change needs it

| Changed boundary | Command |
| --- | --- |
| `Scripts/conductor.py` or preflight | `make conductor-selftest` |
| Swift files | `make dev-lint` (and `make dev-format` when formatting mutation is intended) |
| Rust crates | `make dev-test` (`--lib`). `CARGO_TEST_KIND=full` for integration/process/proptest. |
| UniFFI / C FFI generated boundary | `make dev-cargo-codegen-check` |
| `rust/Cargo.lock` or deny/audit policy | `make dev-cargo-deny` |
| Xcode generator / `Package.swift` | `make xcode-generator-test`. `make xcode-validate` only when you need `xcodebuild -list`. |
| Packaging, MCP, Agent Mode, running app | `make dev-smoke` on an already-running debug app; ask before `make dev-run` / relaunch. |
| Release | `make dev-release-preflight` (and `make dev-release-artifact` only when an artifact is required). |
| Force-push, history rewrite, branch/fork deletion, credential rotation, visible app stop/launch | Explicit user approval immediately before the command. |

## Secret hygiene

- Treat obfuscated, encoded, or split credentials as secrets. Do not print their decoded values.
- Use `gitleaks` with `--redact` for materialized staged index blobs and outgoing commits.
- Do not commit local configuration, prompt exports, daemon logs, raw provider traces, or generated diagnostic artifacts unless the repository explicitly allows the exact path.
