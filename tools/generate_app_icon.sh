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

# Scales the source down to ~97% of a 1024x1024 canvas, centered on
# transparent padding, before generating any icon size — without this, the
# bezel's border touches the canvas edge with zero margin (confirmed: 0px
# measured directly), which downstream compositing/anti-aliasing (in
# particular, the small icon rendering inside the custom DMG's "drag to
# Applications" window) clips straight into, making the border look cut
# off at the edges rather than framing the icon. Deliberately subtle (a
# first attempt at 90.6% was visibly, clearly over-padded at small sizes,
# confirmed directly) — this only needs to stop literal edge-touching, not
# visibly shrink the icon.
python3 - "$SRC" "$PADDED" <<'PYEOF'
import sys
from PIL import Image

src = Image.open(sys.argv[1]).convert("RGBA")
canvas_size = 1024
square = src.resize((canvas_size, canvas_size), Image.LANCZOS)

content_size = round(canvas_size * 0.97)
resized = square.resize((content_size, content_size), Image.LANCZOS)

canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
offset = (canvas_size - content_size) // 2
canvas.paste(resized, (offset, offset), resized)

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
for y in range(canvas_size):
    for x in range(canvas_size):
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
