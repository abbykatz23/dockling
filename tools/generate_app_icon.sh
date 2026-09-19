#!/bin/sh
# Builds icons/AppIcon.icns (the static Finder/Applications/installer icon) from
# the bezeled reference image. Per DOCKLING_SPEC.md this uses the teal-bezel
# version as-is, unlike the live Dock-tile art which uses the transparent one.
#
# Usage: tools/generate_app_icon.sh dockling.jpg icons/

set -eu

SRC="${1:?usage: generate_app_icon.sh <source.jpg> <output-dir>}"
OUT_DIR="${2:?usage: generate_app_icon.sh <source.jpg> <output-dir>}"
ICONSET="$OUT_DIR/AppIcon.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for sz in 16 32 128 256 512; do
  sips -s format png -z "$sz" "$sz" "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sz2x=$((sz * 2))
  sips -s format png -z "$sz2x" "$sz2x" "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
echo "wrote $OUT_DIR/AppIcon.icns"
