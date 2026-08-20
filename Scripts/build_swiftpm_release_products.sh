#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUN_WITHOUT_GITHUB_TOKENS="${REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS:-$SCRIPT_DIR/run_without_github_tokens.sh}"
OUTPUT_DIR="${1:-$ROOT_DIR/.build/public-release-products/release}"
DEFAULT_SCRATCH_ROOT="$ROOT_DIR/.build/public-release-swiftpm"
SCRATCH_ROOT="${REPOPROMPT_PUBLIC_SWIFTPM_SCRATCH_ROOT:-$DEFAULT_SCRATCH_ROOT}"
SCRATCH_SENTINEL_NAME=".agentry-public-swiftpm-scratch"
LIPO="${LIPO:-lipo}"
KEYBOARD_SHORTCUTS_PATCH_HELPER="${REPOPROMPT_KEYBOARD_SHORTCUTS_PATCH_HELPER:-$SCRIPT_DIR/patch_keyboard_shortcuts_resource_lookup.sh}"
CLEAN_PUBLIC_SWIFTPM_BUILDS="${REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS:-1}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

sentry_linking_enabled() {
    [[ "${AGENTRY_ENABLE_SENTRY:-}" == "1" ]]
}

run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}

canonical_path() {
    python3 - "$1" <<'PYTHON'
import sys
from pathlib import Path

print(Path(sys.argv[1]).resolve(strict=False))
PYTHON
}

normalized_arches() {
    "$LIPO" -archs "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

require_exact_arm64() {
    local path="$1"
    [[ -f "$path" ]] || fail "missing SwiftPM product: $path"
    local actual
    actual="$(normalized_arches "$path")"
    [[ "$actual" == "arm64" ]] ||
        fail "unexpected architecture set for $path: expected arm64, got ${actual:-<none>}"
}

[[ -x "$RUN_WITHOUT_GITHUB_TOKENS" ]] || fail "missing token-scrubbing SwiftPM wrapper: $RUN_WITHOUT_GITHUB_TOKENS"
[[ -x "$KEYBOARD_SHORTCUTS_PATCH_HELPER" ]] || fail "missing KeyboardShortcuts resource patch helper: $KEYBOARD_SHORTCUTS_PATCH_HELPER"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"
command -v ditto >/dev/null 2>&1 || fail "missing ditto"

mkdir -p "$(dirname "$OUTPUT_DIR")"
ROOT_CANONICAL="$(canonical_path "$ROOT_DIR")"
SCRATCH_CANONICAL="$(canonical_path "$SCRATCH_ROOT")"
DEFAULT_SCRATCH_CANONICAL="$(canonical_path "$DEFAULT_SCRATCH_ROOT")"
[[ "$SCRATCH_CANONICAL" != "/" ]] || fail "refusing to use / as the public SwiftPM scratch root"
[[ "$SCRATCH_CANONICAL" != "$ROOT_CANONICAL" ]] || fail "refusing to use the repository root as public SwiftPM scratch"
[[ "$ROOT_CANONICAL" != "$SCRATCH_CANONICAL/"* ]] || fail "refusing to use a repository ancestor as public SwiftPM scratch: $SCRATCH_CANONICAL"
if [[ ( -e "$SCRATCH_ROOT" || -L "$SCRATCH_ROOT" ) && "$SCRATCH_CANONICAL" != "$DEFAULT_SCRATCH_CANONICAL" && ! -f "$SCRATCH_ROOT/$SCRATCH_SENTINEL_NAME" ]]; then
    fail "refusing to use unmarked public SwiftPM scratch path: $SCRATCH_ROOT"
fi
case "$CLEAN_PUBLIC_SWIFTPM_BUILDS" in
    1)
        run rm -rf "$SCRATCH_ROOT"
        ;;
    0) ;;
    *) fail "REPOPROMPT_CLEAN_PUBLIC_SWIFTPM_BUILDS must be 0 or 1" ;;
esac
run mkdir -p "$SCRATCH_ROOT"
printf 'Agentry arm64 public SwiftPM scratch\n' > "$SCRATCH_ROOT/$SCRATCH_SENTINEL_NAME"

SWIFT_BUILD_ARGS=(-c release)
if sentry_linking_enabled; then
    SWIFT_BUILD_ARGS+=(-debug-info-format dwarf)
fi

scratch="$SCRATCH_ROOT/arm64"
run env \
    REPOPROMPT_RUN_WITHOUT_GITHUB_TOKENS="$RUN_WITHOUT_GITHUB_TOKENS" \
    REPOPROMPT_SWIFTPM_SCRATCH_PATH="$scratch" \
    "$KEYBOARD_SHORTCUTS_PATCH_HELPER" "$ROOT_DIR"
for product in Agentry agentry-mcp; do
    run "$RUN_WITHOUT_GITHUB_TOKENS" swift build \
        "${SWIFT_BUILD_ARGS[@]}" \
        --arch arm64 \
        --scratch-path "$scratch" \
        --product "$product"
done
printf '+ %q ' "$RUN_WITHOUT_GITHUB_TOKENS" swift build "${SWIFT_BUILD_ARGS[@]}" --arch arm64 --scratch-path "$scratch" --show-bin-path
printf '\n'
ARM64_BIN_DIR="$("$RUN_WITHOUT_GITHUB_TOKENS" swift build "${SWIFT_BUILD_ARGS[@]}" --arch arm64 --scratch-path "$scratch" --show-bin-path)"
require_exact_arm64 "$ARM64_BIN_DIR/Agentry"
require_exact_arm64 "$ARM64_BIN_DIR/agentry-mcp"

staged_output="$(mktemp -d "$(dirname "$OUTPUT_DIR")/.public-release-products.XXXXXX")"
cleanup() {
    rm -rf "$staged_output"
}
trap cleanup EXIT

run ditto "$ARM64_BIN_DIR/Agentry" "$staged_output/Agentry"
run ditto "$ARM64_BIN_DIR/agentry-mcp" "$staged_output/agentry-mcp"
run chmod +x "$staged_output/Agentry" "$staged_output/agentry-mcp"
require_exact_arm64 "$staged_output/Agentry"
require_exact_arm64 "$staged_output/agentry-mcp"

for resource in "$ARM64_BIN_DIR"/*.bundle "$ARM64_BIN_DIR/Sparkle.framework"; do
    [[ -e "$resource" ]] || continue
    run ditto "$resource" "$staged_output/$(basename "$resource")"
done

run rm -rf "$OUTPUT_DIR"
run mv "$staged_output" "$OUTPUT_DIR"
trap - EXIT
printf 'OK: arm64 SwiftPM release products created at %s\n' "$OUTPUT_DIR"
