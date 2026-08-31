#!/usr/bin/env bash
# Stage binary-target frameworks where the XCTest bundle's rpath expects them.
#
# SwiftPM copies Sparkle.xcframework's framework to the products root, but
# RepoPromptTests.xctest is linked against `@rpath/Sparkle.framework/...` and
# only searches `PackageFrameworks/`. Without this the app test target fails at
# load with "Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle".
#
# Idempotent and cheap: a relative symlink that survives incremental builds, so
# this only does real work after the products directory has been wiped.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
PRODUCTS_DIR="$ROOT_DIR/.build/out/Products/$CONFIGURATION"

# Nothing has been built yet; the caller's build step will create it and a later
# invocation stages the link.
[[ -d "$PRODUCTS_DIR" ]] || exit 0

for framework in "$PRODUCTS_DIR"/*.framework; do
    [[ -d "$framework" ]] || continue
    name="$(basename "$framework")"
    link="$PRODUCTS_DIR/PackageFrameworks/$name"
    [[ -e "$link" || -L "$link" ]] && continue
    mkdir -p "$PRODUCTS_DIR/PackageFrameworks"
    ln -s "../$name" "$link"
    printf 'staged %s -> PackageFrameworks/%s\n' "$name" "$name"
done
