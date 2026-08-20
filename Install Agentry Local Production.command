#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$ROOT_DIR/conductor"
INSTALL_DIR="${AGENTRY_LOCAL_PRODUCTION_INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/Agentry.app"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required to install Agentry from Finder."
    echo
    echo "Install Python 3, then run this launcher again."
    read -r -p "Press Return to close this window..." || true
    exit 1
fi

if [[ ! -x "$CONDUCTOR" ]]; then
    echo "Couldn't find the coordinated installer:"
    echo "$CONDUCTOR"
    echo
    echo "Make sure this file is still in the repoprompt-ce folder and that conductor is executable."
    read -r -p "Press Return to close this window..." || true
    exit 1
fi

install_app() {
    echo
    echo "Building and installing Agentry..."
    echo "macOS may ask you to approve the dedicated local code-signing certificate."
    echo
    CONFIRM_LOCAL_PRODUCTION_INSTALL=1 "$CONDUCTOR" release local-install
}

clear 2>/dev/null || true
echo "Agentry - local self-signed production installer"
echo
echo "Project: $ROOT_DIR"
echo "Mode:    coordinated (build and install run through the dev daemon)"
echo
echo "This builds a release-mode app and replaces any existing app at:"
echo "$TARGET_APP"
echo "using a dedicated self-signed certificate trusted only on this Mac."
echo
echo "The installed app is local-only: it is not notarized, must not be uploaded"
echo "to GitHub Releases, and should not be copied to another Mac."
echo

if ! IFS= read -r -p "Build and replace $TARGET_APP? [y/N] " choice; then
    echo
    echo "Install canceled."
    exit 0
fi

case "$choice" in
    y | Y | yes | YES | Yes)
        ;;
    *)
        echo
        echo "Install canceled."
        exit 0
        ;;
esac

cd "$ROOT_DIR" || exit 1
if install_app; then
    echo
    echo "Agentry local production app installed successfully."
else
    status=$?
    echo
    echo "Agentry local production install failed."
    echo "Review the output above, then run this launcher again to retry."
    read -r -p "Press Return to close this window..." || true
    exit "$status"
fi

echo
read -r -p "Press Return to close this window..." || true
