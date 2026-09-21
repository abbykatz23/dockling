#!/bin/sh
# Builds a signed, notarized, stapled DMG for GitHub Releases — the "download
# and it just works, no Gatekeeper warning" path from DOCKLING_SPEC.md.
# Nothing about the dev workflow (swift build / install.sh) needs this; it's
# only for cutting an actual release.
#
# One-time setup this script assumes is already done (both require your own
# Apple ID login, so neither can be scripted):
#   1. A "Developer ID Application" certificate in your login keychain.
#      No Xcode needed — Keychain Access > Certificate Assistant > Request a
#      Certificate From a Certificate Authority (CSR to disk) > upload it at
#      https://developer.apple.com/account/resources/certificates/list
#      ("+" > Developer ID Application) > download the issued cert > double-
#      click it to install. Verify with: security find-identity -v -p codesigning
#   2. Notarization credentials stored under the profile name below — an
#      app-specific password (https://appleid.apple.com > Sign-In and
#      Security > App-Specific Passwords) plus your Team ID
#      (developer.apple.com/account > Membership details):
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
#
# Usage: tools/notarize_release.sh
set -eu

NOTARY_PROFILE="dockling-notary"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BINARY="$REPO_ROOT/DocklingAgent/.build/release/DocklingAgent"
VERSION=$(date +%Y.%m.%d)
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/Dockling-$VERSION.dmg"

command -v swift >/dev/null 2>&1 || {
  echo "error: 'swift' is required (install Xcode Command Line Tools: xcode-select --install)" >&2
  exit 1
}

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' certificate found in the keychain — see this script's header for setup." >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: no notarization credentials stored under profile '$NOTARY_PROFILE' — see this script's header for setup." >&2
  exit 1
fi

echo "Building Dockling (release)..."
(cd "$REPO_ROOT/DocklingAgent" && swift build -c release)

echo "Signing with $IDENTITY..."
# --options runtime (hardened runtime) is what notarization actually
# requires; plain codesign without it gets rejected by notarytool.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BINARY"
codesign --verify --strict --verbose=2 "$BINARY"

echo "Assembling release folder..."
rm -rf "$DIST_DIR"
STAGING="$DIST_DIR/staging"
mkdir -p "$STAGING/install" "$STAGING/.claude/hooks" "$STAGING/DocklingAgent/.build/release" "$STAGING/DocklingAgent/Sources/DocklingAgent"
cp "$REPO_ROOT/install/install.sh" "$REPO_ROOT/install/install_launchd.sh" "$STAGING/install/"
cp "$REPO_ROOT/.claude/hooks/report_session_start.sh" "$STAGING/.claude/hooks/"
cp "$BINARY" "$STAGING/DocklingAgent/.build/release/DocklingAgent"
cp -R "$REPO_ROOT/DocklingAgent/Sources/DocklingAgent/Resources" "$STAGING/DocklingAgent/Sources/DocklingAgent/Resources"
cp "$REPO_ROOT/README.md" "$STAGING/"

echo "Building DMG..."
hdiutil create -volname "Dockling" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

echo "Notarizing (this polls Apple and can take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

echo
echo "Done: $DMG_PATH"
echo "Recipients don't need the Swift toolchain — install.sh falls back to"
echo "this DMG's prebuilt, signed binary when 'swift' isn't on PATH."
