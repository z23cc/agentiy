#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
LABEL="${2:-App architecture validation}"
LIPO="${LIPO:-lipo}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

architectures() {
    "$LIPO" -archs "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

require_regular_executable() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" && -x "$path" ]] ||
        fail "expected executable regular file: $path"
    local actual
    actual="$(architectures "$path")" || fail "could not read Mach-O architectures: $path"
    [[ "$actual" == "arm64" ]] ||
        fail "$LABEL rejected required executable $path: expected exact arm64, got ${actual:-<none>}"
}

[[ -n "$APP_BUNDLE" ]] || fail "usage: $0 <app-bundle> [label]"
[[ -d "$APP_BUNDLE/Contents" ]] || fail "missing app bundle Contents directory: $APP_BUNDLE"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"

MAIN="$APP_BUNDLE/Contents/MacOS/Agentry"
HELPER="$APP_BUNDLE/Contents/MacOS/agentry-mcp"
HOST_HELPER="$APP_BUNDLE/Contents/MacOS/agentry-agent-host"
require_regular_executable "$MAIN"
require_regular_executable "$HELPER"
require_regular_executable "$HOST_HELPER"

macho_count=0
while IFS= read -r -d '' path; do
    actual="$(architectures "$path")" || continue
    [[ -n "$actual" ]] || continue
    macho_count=$((macho_count + 1))
    [[ "$actual" == "arm64" ]] ||
        fail "$LABEL rejected $path: expected exact arm64, got ${actual:-<none>}"
done < <(find "$APP_BUNDLE/Contents" -type f -print0)

(( macho_count > 0 )) || fail "$LABEL found no Mach-O files under $APP_BUNDLE/Contents"
printf 'OK: %s passed exact arm64 policy across %d Mach-O files.\n' "$LABEL" "$macho_count"
