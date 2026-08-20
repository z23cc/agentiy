#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORK="${1:-}"
LABEL="${2:-Staged Sparkle.framework}"
LIPO="${LIPO:-lipo}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

canonical_path() {
    python3 - "$1" <<'PYTHON'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve(strict=False))
PYTHON
}

architectures() {
    "$LIPO" -archs "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

[[ -n "$FRAMEWORK" ]] || fail "usage: $0 <staged-Sparkle.framework> [label]"
[[ -d "$FRAMEWORK" && ! -L "$FRAMEWORK" ]] || fail "missing staged Sparkle framework directory: $FRAMEWORK"
command -v "$LIPO" >/dev/null 2>&1 || fail "missing lipo command: $LIPO"

framework_canonical="$(canonical_path "$FRAMEWORK")"
vendor_canonical="$(canonical_path "$ROOT_DIR/Vendor/Sparkle")"
[[ "$framework_canonical" != "$vendor_canonical" && "$framework_canonical" != "$vendor_canonical/"* ]] ||
    fail "refusing to modify vendored Sparkle in place: $FRAMEWORK"

required_macho=(
    "$FRAMEWORK/Versions/B/Sparkle"
    "$FRAMEWORK/Versions/B/Autoupdate"
    "$FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
)
for path in "${required_macho[@]}"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "missing required Sparkle Mach-O: $path"
done

macho_count=0
while IFS= read -r -d '' path; do
    actual="$(architectures "$path")" || continue
    [[ -n "$actual" ]] || continue
    macho_count=$((macho_count + 1))
    if [[ "$actual" == "arm64" ]]; then
        continue
    fi
    case ",$actual," in
        *,arm64,*) ;;
        *) fail "$LABEL cannot be thinned to arm64: $path has ${actual:-<none>}" ;;
    esac

    mode="$(stat -f '%Lp' "$path")"
    temp="$(mktemp "$(dirname "$path")/.agentry-arm64.XXXXXX")"
    if ! "$LIPO" -thin arm64 "$path" -output "$temp"; then
        rm -f "$temp"
        fail "$LABEL failed to thin Mach-O: $path"
    fi
    chmod "$mode" "$temp"
    thinned="$(architectures "$temp")" || {
        rm -f "$temp"
        fail "$LABEL could not verify thinned Mach-O: $path"
    }
    [[ "$thinned" == "arm64" ]] || {
        rm -f "$temp"
        fail "$LABEL produced unexpected architectures for $path: ${thinned:-<none>}"
    }
    mv -f "$temp" "$path"
done < <(find "$FRAMEWORK" -type f -print0)

(( macho_count > 0 )) || fail "$LABEL contains no Mach-O files"
for path in "${required_macho[@]}"; do
    actual="$(architectures "$path")" || fail "$LABEL could not read required Mach-O architectures: $path"
    [[ "$actual" == "arm64" ]] || fail "$LABEL required Mach-O is not exact arm64: $path (${actual:-<none>})"
done

printf 'OK: %s is exact arm64 across %d Mach-O files.\n' "$LABEL" "$macho_count"
