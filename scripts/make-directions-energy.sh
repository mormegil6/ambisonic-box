#!/usr/bin/env bash
# Composite the ambisonic ENERGY MAP over the 360 test card: a spoken direction
# cue ("front", "back", "left", "right", "top", "bottom") plays while a glowing
# blob sits on the part of the equirectangular frame that direction points at.
# The card already labels those directions, so the clip is self-checking - if
# the blob and the label disagree, the ambisonic chain is wrong.
#
# Why a key and not a plain blend: the energy map's background is the bottom of
# the colormap (viridis: near-black purple), which carries no information. A
# luma key drops it to full transparency and keeps the bright blob, so the card
# stays crisp everywhere the sound is not. Because viridis is monotonic in
# lightness, keying on LUMA also keys the color range - the dim blue skirts go
# translucent and the yellow core stays solid, which is the glow falloff you
# want for free. Tune with KEY_* below (higher THRESH/TOL = more of the map
# dropped; SOFT is the edge width).
#
# The energy map itself comes from AmbisonicEnergyRenderer.py (separate repo:
# ACN/SN3D in, energy video out). Render it first, then point this script at it:
#   python AmbisonicEnergyRenderer.py -i <16ch.wav> --fps 30 \
#          --encoder h264_videotoolbox --bitrate 12M
#
# Usage: scripts/make-directions-energy.sh ENERGY.mp4 AUDIO_16CH.wav [OUT] [CARD] [W] [H]
#   defaults: OUT=content/vod/masters/directions-energy_8k360_16ch.webm
#             CARD=content/vod/masters/testcard-360_8k.png  W=7680 H=3840
# Preview a quarter-size version first (fast) by passing 1920 960.
set -euo pipefail

ENERGY="${1:?energy map mp4 (from AmbisonicEnergyRenderer.py)}"
AUDIO="${2:?16-channel ACN/SN3D wav}"
OUT="${3:-content/vod/masters/directions-energy_8k360_16ch.webm}"
CARD="${4:-content/vod/masters/testcard-360_8k.png}"
W="${5:-7680}"; H="${6:-3840}"

# Luma key. Defaults chosen against viridis on the black card: the map's
# background is fully gone, the blue skirt reads as a glow, the core is solid.
KEY_THRESH="${KEY_THRESH:-0.10}"    # luma treated as background
KEY_TOL="${KEY_TOL:-0.30}"          # how far above it still keys out
KEY_SOFT="${KEY_SOFT:-0.18}"        # edge softness

for f in "$ENERGY" "$AUDIO" "$CARD"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
mkdir -p "$(dirname "$OUT")"

# The map is an equirectangular projection of the same sphere the card shows,
# so it overlays 1:1 after a scale - no offset, no rotation. shortest=1 ends
# the (still) card when the map ends.
echo "[directions-energy] ${W}x${H}, key th=$KEY_THRESH tol=$KEY_TOL soft=$KEY_SOFT"
ffmpeg -y -hide_banner \
    -loop 1 -i "$CARD" \
    -i "$ENERGY" \
    -i "$AUDIO" \
    -filter_complex "\
[0:v]scale=${W}:${H},format=rgba[bg];\
[1:v]scale=${W}:${H},format=rgba,\
lumakey=threshold=${KEY_THRESH}:tolerance=${KEY_TOL}:softness=${KEY_SOFT}[key];\
[bg][key]overlay=format=auto:shortest=1,format=yuv420p[v]" \
    -map "[v]" -map 2:a \
    -c:v libvpx-vp9 -b:v 0 -crf 30 -row-mt 1 -tile-columns 4 -threads 8 \
    -speed 2 -g 30 -pix_fmt yuv420p -color_range tv \
    -c:a libopus -mapping_family 255 -b:a 1024k -ar 48000 \
    "$OUT"

echo "[directions-energy] wrote $OUT"
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,channels \
        -of default=noprint_wrappers=1 "$OUT"
