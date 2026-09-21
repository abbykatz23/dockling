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
BINARY="$REPO_ROOT/DocklingAgent/.build/release/DocklingAgent"

if command -v swift >/dev/null 2>&1; then
  echo "Building Dockling (release)..."
  (cd "$REPO_ROOT/DocklingAgent" && swift build -c release)
  # A from-source dev build works fine unsigned, same as always — this only
  # upgrades it to a real signature when a Developer ID identity happens to
  # be in the keychain (e.g. this is a release checkout), since that's a
  # prerequisite for notarizing later and costs nothing when there's no
  # identity to sign with.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
  if [ -n "$IDENTITY" ]; then
    echo "Signing with $IDENTITY..."
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BINARY"
  fi
elif [ -x "$BINARY" ]; then
  echo "'swift' not found on PATH — using the prebuilt binary already at $BINARY"
else
  echo "error: 'swift' is required but not found on PATH (install Xcode Command Line Tools: xcode-select --install)," >&2
  echo "       and no prebuilt binary was found at $BINARY either." >&2
  exit 1
fi

"$BINARY" --install --repo-root "$REPO_ROOT"

# A permanent copy, independent of wherever $REPO_ROOT happens to be — most
# importantly, a DMG mount (/Volumes/Dockling/...), which vanishes the
# moment it's ejected. install_launchd.sh points the launchd agent at this
# copy, not at $BINARY directly, so auto-start keeps working after that —
# same reasoning as why icon/sound resources get copied to ~/.dockling
# instead of read from the checkout in place.
INSTALLED_BINARY="$HOME/.dockling/bin/DocklingAgent"
mkdir -p "$HOME/.dockling/bin"
cp "$BINARY" "$INSTALLED_BINARY"
chmod +x "$INSTALLED_BINARY"

echo
echo "Next: run the dispatcher (keep it running in the background):"
echo "  $INSTALLED_BINARY &"
echo
echo "Or set it up to start automatically at login:"
echo "  ./install/install_launchd.sh"
