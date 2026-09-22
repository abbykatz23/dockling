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

# Scales the source down to ~90.6% of a 1024x1024 canvas, centered on
# transparent padding, before generating any icon size — without this, the
# bezel's border touches the canvas edge with zero margin (confirmed: 0px
# measured directly), which downstream compositing/anti-aliasing (in
# particular, the small icon rendering inside the custom DMG's "drag to
# Applications" window) clips straight into, making the border look cut
# off at the edges rather than framing the icon.
python3 - "$SRC" "$PADDED" <<'PYEOF'
import sys
from PIL import Image

src = Image.open(sys.argv[1]).convert("RGBA")
canvas_size = 1024
square = src.resize((canvas_size, canvas_size), Image.LANCZOS)

content_size = round(canvas_size * 0.906)
resized = square.resize((content_size, content_size), Image.LANCZOS)

canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
offset = (canvas_size - content_size) // 2
canvas.paste(resized, (offset, offset), resized)
canvas.save(sys.argv[2])
PYEOF

for sz in 16 32 128 256 512; do
  sips -s format png -z "$sz" "$sz" "$PADDED" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sz2x=$((sz * 2))
  sips -s format png -z "$sz2x" "$sz2x" "$PADDED" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
echo "wrote $OUT_DIR/AppIcon.icns"
