#!/usr/bin/env bash
# Regenerate the five docs/images figures that are DERIVED from the 360 test card.
#
# WHY THIS EXISTS. These five were originally produced by hand, from a gitignored
# scratch directory - the commit that added two of them says so outright ("the two
# viewer previews were referenced from a gitignored path"). That was survivable
# until the card's wordmark changed on 2026-08-08, at which point every figure
# still showed the old name and nobody could reproduce them without working out,
# from the pixels, how each had been made. That reverse-engineering is what this
# script exists to make unnecessary a second time.
#
# It regenerates, all from the card:
#   testcard-360-equirect.png            the stored equirectangular card, downscaled
#   viewer-front-90deg.png               the FRONT cube face, i.e. what a viewer sees
#   viewer-up-90deg.png                  the UP face, the pole that is an ordinary wall
#   sphere-tessellation-before-after.png the nadir mesh comparison
#   directions-energy-frame.png          card + energy overlay, at the "Right" cue
#
# The two viewer figures are the flat cube faces, NOT a reprojection: each face
# spans exactly 90 deg by construction (see make-360-testcard.py's geometry note),
# so the face as rendered IS the 90-degree view. Verified against the originals
# when this was written: framing pixel-identical, only the wordmark differed.
#
# DEPENDENCIES. numpy, Pillow and matplotlib (the card takes its font from
# matplotlib's bundled DejaVu Sans), plus ffmpeg for the energy composite. If the
# host has no such Python, run the Python parts in a container:
#   docker build -t cardgen:local - <<'EOF'
#   FROM python:3.12-slim
#   RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
#       && rm -rf /var/lib/apt/lists/*
#   RUN pip install --no-cache-dir numpy pillow matplotlib
#   EOF
#   docker run --rm -v "$PWD:/w" -w /w cardgen:local env PY=python ./scripts/make-doc-figures.sh
#
# ffmpeg belongs in that image on purpose. Without it the container does four of
# the five and the host does the fifth, which is two half-runs and a chance to
# forget one; with it, one command produces all five in one environment.
set -euo pipefail
cd "$(dirname "$0")/.."

CARD="${CARD:-content/vod/masters/testcard-360_8k.png}"
ENERGY="${ENERGY:-content/vod-sources/directions-source_energy_voice16ch.mov}"
OUT="${OUT:-docs/images}"
PY="${PY:-python3}"

# The moment the energy blob sits on the RIGHT wall. Found by scanning the energy
# render for a yellow-green region centred at x=0.75 of the frame (equirect puts
# FRONT at centre, so RIGHT is three quarters across). The blob pulses once per
# spoken cue and is gone within a fifth of a second, which is why a guess based on
# the caption timing lands on an empty frame.
ENERGY_T="${ENERGY_T:-5.0}"
# Same key the clip itself uses, so the still and the video agree. The energy map
# is viridis, whose zero is dark purple (68,0,84); lumakey drops it on luma.
KEY="lumakey=threshold=0.10:tolerance=0.30:softness=0.18"

[ -f "$CARD" ] || { echo "missing card: $CARD (run make-360-testcard.py first)" >&2; exit 1; }

echo "== 1/3  cube faces -> the two viewer figures =="
FACES=$(mktemp -d); trap 'rm -rf "$FACES"' EXIT
"$PY" scripts/make-360-testcard.py -o "$FACES/discard.png" --faces-out "$FACES" >/dev/null

echo "== 2/3  downscales =="
"$PY" - "$CARD" "$FACES" "$OUT" <<'PYEOF'
import sys
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
card, faces, out = sys.argv[1:4]
Image.open(card).convert("RGB").resize((1400, 700), Image.LANCZOS).save(f"{out}/testcard-360-equirect.png")
for face, name in (("front", "viewer-front-90deg"), ("up", "viewer-up-90deg")):
    Image.open(f"{faces}/face-{face}.png").convert("RGB").resize((900, 900), Image.LANCZOS).save(f"{out}/{name}.png")
print("  testcard-360-equirect.png, viewer-front-90deg.png, viewer-up-90deg.png")
PYEOF

echo "== 3/3  tessellation + energy composite =="
"$PY" scripts/render-sphere-distortion.py "$CARD" \
      --az 0 --el -90 --fov 68 --size 520 --out-dir "$OUT" >/dev/null
echo "  sphere-tessellation-before-after.png"

if [ ! -f "$ENERGY" ]; then
    echo "  SKIPPED directions-energy-frame.png: $ENERGY not present" >&2
    echo "    fetch it: gh release download vod-clips -p $(basename "$ENERGY") -D $(dirname "$ENERGY")" >&2
elif ! command -v ffmpeg >/dev/null 2>&1; then
    # the container fallback in the header has Python but no ffmpeg, and the four
    # figures above are the ones that need Python - so this is a normal split,
    # not a broken run. Say so rather than dying on "command not found".
    echo "  SKIPPED directions-energy-frame.png: ffmpeg not on PATH" >&2
    echo "    the other four are done; run this script again on a host with ffmpeg" >&2
else
    ffmpeg -y -hide_banner -loglevel error -i "$CARD" -ss "$ENERGY_T" -i "$ENERGY" \
      -filter_complex "[0:v]scale=1920:960,format=rgba[bg];[1:v]scale=1920:960,format=rgba,${KEY}[k];[bg][k]overlay=format=auto,format=rgb24[v]" \
      -map "[v]" -frames:v 1 "$OUT/directions-energy-frame.png"
    echo "  directions-energy-frame.png (energy at t=${ENERGY_T}s, RIGHT wall)"
fi
