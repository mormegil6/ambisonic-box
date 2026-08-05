#!/usr/bin/env bash
# Composite the ambisonic ENERGY MAP over the 360 test card: a spoken direction
# cue ("front", "back", "left", "right", "top", "bottom") plays while a glowing
# blob sits on the part of the equirectangular frame that direction points at.
# The card already labels those directions, so the clip is self-checking - if
# the blob and the label disagree, the ambisonic chain is wrong.
#
# Arrangement (mirrors the Resolve edit this replaces):
#   card  ---------------------------------------------  (whole clip)
#   bed   ---------------------------------------------  (whole clip, audio only)
#   voice        ------------------------------          (offset by OFFSET)
#   energy       ------------------------------          (SAME offset, so the
#                                                         blob lands on the word)
# The bed is deliberately NOT visualised: the energy map tracks the spoken cues
# only, so a diffuse musical bed cannot wash out the direction blobs. That is
# also why the map is delayed by exactly the voice offset - they are one take.
#
# Why a luma key and not a plain blend: the map's background is the bottom of
# the colormap (viridis: near-black purple) and carries no information. A luma
# key drops it to full transparency and keeps the bright blob, so the card stays
# crisp everywhere the sound is not. Because viridis is monotonic in lightness,
# keying on LUMA also keys the colour range - dim blue skirts go translucent,
# the yellow core stays solid, which is the glow falloff you want for free.
# Tune with KEY_* (higher THRESH/TOL drops more of the map; SOFT is edge width).
#
# The energy map comes from AmbisonicEnergyRenderer.py (separate repo: ACN/SN3D
# in, energy video out), rendered from the DRY VOICE stem, not the mix:
#   python AmbisonicEnergyRenderer.py -i <voice_16ch.wav> --fps 30 \
#          --encoder h264_videotoolbox --bitrate 12M
#
# Usage: scripts/make-directions-energy.sh ENERGY.mp4 VOICE_16CH.wav [BED_16CH.wav] [OUT] [CARD] [W] [H]
#   env: OFFSET (s, default 1.0) KEY_THRESH KEY_TOL KEY_SOFT BED_GAIN VOICE_GAIN
#   defaults: OUT=content/vod/masters/directions-energy_8k360_16ch.webm
#             CARD=content/vod/masters/testcard-360_8k.png  W=7680 H=3840
# Preview fast by passing 1920 960 as W H.
set -euo pipefail

ENERGY="${1:?energy map mp4 (from AmbisonicEnergyRenderer.py, dry voice)}"
VOICE="${2:?16-channel ACN/SN3D voice stem}"
BED="${3:-}"                        # optional 16-ch bed, mixed under, NOT visualised
OUT="${4:-content/vod/masters/directions-energy_8k360_16ch.webm}"
CARD="${5:-content/vod/masters/testcard-360_8k.png}"
W="${6:-7680}"; H="${7:-3840}"

OFFSET="${OFFSET:-1.0}"             # voice + energy start this late; bed and card at 0
KEY_THRESH="${KEY_THRESH:-0.10}"
KEY_TOL="${KEY_TOL:-0.30}"
KEY_SOFT="${KEY_SOFT:-0.18}"
BED_GAIN="${BED_GAIN:-1.0}"         # linear; the bed is often hotter than the voice
VOICE_GAIN="${VOICE_GAIN:-1.0}"

for f in "$ENERGY" "$VOICE" "$CARD" ${BED:+"$BED"}; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
mkdir -p "$(dirname "$OUT")"

dur () { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
VOICE_DUR=$(dur "$VOICE")
if [ -n "$BED" ]; then
    BED_DUR=$(dur "$BED")
    # the clip runs as long as the longer of (bed) and (offset + voice)
    TOTAL=$(python3 -c "print(max($BED_DUR, $OFFSET + $VOICE_DUR))")
else
    TOTAL=$(python3 -c "print($OFFSET + $VOICE_DUR)")
fi

MS=$(python3 -c "print(int(round($OFFSET * 1000)))")

# Video: still card for the whole clip; energy map padded by OFFSET (the pad is
# black, which the luma key turns transparent, so no seam) then keyed and laid
# over. The map is an equirectangular projection of the same sphere the card
# shows, so it overlays 1:1 after a scale - no offset, no rotation.
VF="[0:v]scale=${W}:${H},format=rgba[bg];\
[1:v]scale=${W}:${H},format=rgba,tpad=start_duration=${OFFSET}:color=black@0.0,\
lumakey=threshold=${KEY_THRESH}:tolerance=${KEY_TOL}:softness=${KEY_SOFT}[key];\
[bg][key]overlay=format=auto,format=yuv420p[v]"

# Audio: per-channel sum, no normalisation (amix would otherwise halve both).
# aresample because the bed and the voice are not necessarily the same rate.
if [ -n "$BED" ]; then
    AF="[2:a]aresample=48000,volume=${VOICE_GAIN},adelay=delays=${MS}:all=1[vo];\
[3:a]aresample=48000,volume=${BED_GAIN}[bd];\
[vo][bd]amix=inputs=2:normalize=0:duration=longest[a]"
    INPUTS=(-loop 1 -i "$CARD" -i "$ENERGY" -i "$VOICE" -i "$BED")
else
    AF="[2:a]aresample=48000,volume=${VOICE_GAIN},adelay=delays=${MS}:all=1[a]"
    INPUTS=(-loop 1 -i "$CARD" -i "$ENERGY" -i "$VOICE")
fi

echo "[directions-energy] ${W}x${H}, ${TOTAL}s, voice+map offset ${OFFSET}s${BED:+, bed mixed under}"
echo "[directions-energy] key th=$KEY_THRESH tol=$KEY_TOL soft=$KEY_SOFT"

ffmpeg -y -hide_banner "${INPUTS[@]}" \
    -filter_complex "${VF};${AF}" \
    -map "[v]" -map "[a]" -t "$TOTAL" \
    -c:v libvpx-vp9 -b:v 0 -crf 30 -row-mt 1 -tile-columns 4 -threads 8 \
    -speed 2 -g 30 -pix_fmt yuv420p -color_range tv \
    -c:a libopus -mapping_family 255 -b:a 1024k -ar 48000 \
    "$OUT"

echo "[directions-energy] wrote $OUT"
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,channels \
        -show_entries format=duration -of default=noprint_wrappers=1 "$OUT"
# a summed 16-ch bed + voice can exceed 0 dBFS; say so rather than ship clipping
peak=$(ffmpeg -hide_banner -nostats -i "$OUT" -af "pan=mono|c0=c0,volumedetect" -f null - 2>&1 \
       | grep max_volume | grep -oE '\-?[0-9.]+' | tail -1)
echo "[directions-energy] W-channel peak: ${peak} dBFS (negative is headroom; if 0.0 lower BED_GAIN)"
