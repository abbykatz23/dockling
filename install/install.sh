#!/bin/sh
# Builds Dockling and registers its hooks into the user-level
# ~/.claude/settings.json, so every Claude Code session on this machine
# reports to the dispatcher — not just sessions run inside this repo. Safe
# to re-run at any time (see Installer.swift for the merge guarantees).
#
# The only real dependency is the Swift toolchain (needed to build the app
# at all); the merge and secret generation are done by the built binary
# itself, not by shelling out to jq/openssl, so there's nothing else to
# install first.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

command -v swift >/dev/null 2>&1 || {
  echo "error: 'swift' is required but not found on PATH (install Xcode Command Line Tools: xcode-select --install)" >&2
  exit 1
}

echo "Building Dockling (release)..."
(cd "$REPO_ROOT/DocklingAgent" && swift build -c release)

BINARY="$REPO_ROOT/DocklingAgent/.build/release/DocklingAgent"
"$BINARY" --install --repo-root "$REPO_ROOT"

echo
echo "Next: run the dispatcher (keep it running in the background):"
echo "  $BINARY &"
echo
echo "Or set it up to start automatically at login:"
echo "  ./install/install_launchd.sh"
