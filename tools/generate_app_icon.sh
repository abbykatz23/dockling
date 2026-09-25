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
PADDED="$OUT_DIR/AppIcon-source-1024.png"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Fits the source into Apple's exact macOS app-icon squircle tile — an
# 832x832 tile offset at (96, 88) within the 1024x1024 canvas, 185px corner
# radius (confirmed against a maintained open-source implementation of this
# exact spec, cross-checked against multiple independent write-ups of
# Apple's macOS 26+ icon geometry) — rather than an arbitrary center-padded
# scale-down. Starting with macOS 26 (Tahoe), the system actively detects
# icons whose opaque content extends past its own version of this mask and
# draws its own gray backing plate behind them to compensate; matching the
# real geometry exactly, corner radius included, is what stops that plate
# from appearing at all, not just centering/shrinking the art.
python3 - "$SRC" "$PADDED" <<'PYEOF'
import sys
from PIL import Image, ImageDraw

CANVAS = 1024
TILE = 832
TILE_X = 96
TILE_Y = 88
RADIUS = 185

src = Image.open(sys.argv[1]).convert("RGBA")
content = src.resize((TILE, TILE), Image.LANCZOS)

canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
canvas.paste(content, (TILE_X, TILE_Y), content)

# Hard-clips to Apple's exact tile shape on top of whatever the source
# art's own edge/corner already looks like — this is what guarantees the
# final shape never extends past macOS's own mask, regardless of how the
# source was drawn.
mask = Image.new("L", (CANVAS, CANVAS), 0)
draw = ImageDraw.Draw(mask)
draw.rounded_rectangle([TILE_X, TILE_Y, TILE_X + TILE, TILE_Y + TILE], radius=RADIUS, fill=255)
r, g, b, a = canvas.split()
a = Image.composite(a, Image.new("L", (CANVAS, CANVAS), 0), mask)
canvas = Image.merge("RGBA", (r, g, b, a))

# The source images this has been fed so far each came with a faint,
# near-white halo baked in behind the bezel's rounded corners (confirmed
# directly: a solid light-gray fill, distinct from the bezel/duck colors,
# visible only in the corner-arc regions) — invisible at full size but
# reads as an ugly light border around the whole icon once scaled down to
# actual Dock size. Nothing else in this style of art (a saturated color
# bezel plus a hand-drawn duck) uses a flat near-white fill, so clearing
# any opaque, low-saturation, bright pixel is safe and specific to that
# halo rather than incidentally erasing real art.
px = canvas.load()
for y in range(CANVAS):
    for x in range(CANVAS):
        r, g, b, a = px[x, y]
        if a == 0:
            continue
        if max(r, g, b) - min(r, g, b) < 18 and min(r, g, b) > 170:
            px[x, y] = (0, 0, 0, 0)

canvas.save(sys.argv[2])
PYEOF

for sz in 16 32 128 256 512; do
  sips -s format png -z "$sz" "$sz" "$PADDED" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sz2x=$((sz * 2))
  sips -s format png -z "$sz2x" "$sz2x" "$PADDED" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
echo "wrote $OUT_DIR/AppIcon.icns"
