#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SCRIPTS_DIR="${REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR:-$ROOT_DIR/Scripts}"
cd "$ROOT_DIR"

CARGO_BIN="${CARGO:-$(command -v cargo || true)}"
SWIFT_BIN="${SWIFT:-$(command -v swift || true)}"
[[ -n "$CARGO_BIN" ]] || { echo "M7 certification requires cargo" >&2; exit 2; }
[[ -n "$SWIFT_BIN" ]] || { echo "M7 certification requires swift" >&2; exit 2; }

run_step() {
    printf '==> %s\n' "$*"
    "$@"
}

run_rust_step() {
    (
        cd "$ROOT_DIR/rust"
        run_step "$@"
    )
}

# Reuse the same arm64 Rust archive/codegen boundary as the coordinated Swift jobs.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/.build/cargo}"
export CARGO_BUILD_TARGET="${CARGO_BUILD_TARGET:-aarch64-apple-darwin}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

contract="$ROOT_DIR/Scripts/Fixtures/headless_mcp_domain_runtime_m7_contract.json"
evidence="$ROOT_DIR/Scripts/Fixtures/headless_mcp_domain_runtime_m7_evidence.json"
validator="$SCRIPTS_DIR/validate_m7_backend_release.py"
self_test="$SCRIPTS_DIR/test_validate_m7_backend_release.py"
run_step python3 "$self_test"
run_rust_step "$CARGO_BIN" run --locked -p xtask -- generate --check
run_rust_step "$CARGO_BIN" run --locked -p xtask -- archive --profile debug
run_step "$SWIFT_BIN" test --filter MCPBackendSelectionTests
run_step "$SWIFT_BIN" test --filter DirectHeadlessProcessTests
run_step "$SCRIPTS_DIR/guardrails.sh"
run_step python3 "$validator" --fixture "$contract" --evidence "$evidence" --check

printf 'M7 backend certification: offline checks executed and passed; live checks remain deferred.\n'
