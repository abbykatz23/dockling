#!/bin/sh
# Regenerates icons/Assets.car from icons/Dockling.icon — needed only when
# the icon's *design* changes (icons/Dockling.icon/icon.json or its
# Assets/*.png). Not part of the normal release flow: notarize_release.sh
# just copies the already-compiled icons/Assets.car, exactly like it does
# for icons/AppIcon.icns, so cutting an ordinary release never needs this.
#
# Requires actool, which ships only with full Xcode — not Command Line
# Tools alone. That's the whole reason this is a separate, rarely-run
# script instead of a normal-release build step: Xcode is a large, one-time
# install just to make this one file, and the compiled output is what
# actually gets shipped, so nobody building a release needs Xcode present.
#
# Usage: tools/compile_app_icon_asset.sh

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ICON_SRC="$REPO_ROOT/icons/Dockling.icon"
OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

command -v xcrun >/dev/null 2>&1 && xcrun actool --version >/dev/null 2>&1 || {
  echo "error: actool not available — install full Xcode (not just Command Line Tools), run 'sudo xcodebuild -license' and 'sudo xcodebuild -runFirstLaunch', then retry" >&2
  exit 1
}

xcrun actool "$ICON_SRC" \
  --compile "$OUT_DIR" \
  --output-format human-readable-text \
  --notices --warnings --errors \
  --output-partial-info-plist "$OUT_DIR/partial.plist" \
  --app-icon Dockling \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 13.0 \
  --platform macosx

cp "$OUT_DIR/Assets.car" "$REPO_ROOT/icons/Assets.car"
echo "wrote $REPO_ROOT/icons/Assets.car — commit this file"
