#!/usr/bin/env bash
# Build the full `directions` VOD clip: a 360 test card with the ambisonic
# ENERGY MAP keyed over it, spoken direction cues, and the musical bed - tiled
# to a 2 minute clip.
#
# STRUCTURE (one loop unit, repeated until TOTAL, last repeat cut short):
#   card    ============================  still, whole clip
#   bed     ============================  audio only, defines the loop period
#   voice        ==================       OFFSET into each unit
#   energy       ==================       SAME offset (one take: the blob must
#                                         land on the word)
# The bed is deliberately NOT visualised - a diffuse musical bed would wash out
# the direction blobs, and the map is meant to track the spoken cues alone.
#
# THE LOOP PERIOD, measured rather than assumed. Autocorrelating the published
# 120 s master's W channel puts its repeat at 11.0833 s (corr 0.996) = 266
# frames at 24 fps, while the source bed WAV is 11.122 s. So the original was
# reconciled to a whole frame count by a 0.35 % nudge, then tiled and cut at
# 120 s (10.827 repeats). Neither 120/11 nor 120/10 correlates at all, so there
# was no stretch-to-an-integer-loop-count. BED_FIT picks how to spend that
# 39 ms: `tempo` resamples (pitch preserved, nothing lost, the whole bed
# imperceptibly faster) or `trim` cuts the tail (bit-exact content, but the
# splice lands 39 ms early and can click if the bed does not end on silence).
# `native` keeps 11.122 s and ignores the frame grid.
#
# Usage: scripts/make-directions-clip.sh ENERGY.mp4 VOICE_16CH.wav BED_16CH.wav [OUT] [CARD] [W] [H]
#   env: BED_FIT=tempo|trim|native  LOOP_PERIOD=<s>  TOTAL=120  OFFSET=1.0
#        BED_GAIN=<linear>  VOICE_GAIN=<linear>  KEY_THRESH/KEY_TOL/KEY_SOFT
#        FPS=24  (the frame grid the period is quantised to)
# Preview fast with W H = 1920 960.
set -euo pipefail

ENERGY="${1:?energy map mp4 (AmbisonicEnergyRenderer, DRY VOICE stem)}"
VOICE="${2:?16-channel ACN/SN3D voice stem}"
BED="${3:?16-channel ACN/SN3D musical bed (defines the loop period)}"
OUT="${4:-content/vod/masters/directions-energy_8k360_16ch.webm}"
CARD="${5:-content/vod/masters/testcard-360_8k.png}"
W="${6:-7680}"; H="${7:-3840}"

BED_FIT="${BED_FIT:-tempo}"
TOTAL="${TOTAL:-120}"
OFFSET="${OFFSET:-1.0}"
FPS="${FPS:-24}"
# The old master's voice sits 5.4 dB hotter than the new read (mean -22.0 vs
# -27.4 dB) against the same bed, and it was audibly not buried - so match that
# proven ratio by pulling the bed down rather than pushing the voice into clip
# (the new voice peaks at -2.1 dB; +5.4 dB would overshoot 0 dBFS).
BED_GAIN="${BED_GAIN:-0.537}"       # -5.4 dB
VOICE_GAIN="${VOICE_GAIN:-1.0}"
KEY_THRESH="${KEY_THRESH:-0.10}"; KEY_TOL="${KEY_TOL:-0.30}"; KEY_SOFT="${KEY_SOFT:-0.18}"

for f in "$ENERGY" "$VOICE" "$BED" "$CARD"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

dur () { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
BED_DUR=$(dur "$BED")
# Quantise DOWN to a whole frame count (floor, not round): the original
# TIGHTENED the bed, and flooring is what reproduces the measured 266 frames
# at 24 fps = 11.0833 s from an 11.122 s source. Rounding would give 267 frames
# = 11.125 s, i.e. a bed stretched LONGER than the source - the opposite of
# what the published master did.
PERIOD="${LOOP_PERIOD:-$(python3 -c "import math; print(math.floor($BED_DUR*$FPS)/$FPS if '$BED_FIT'!='native' else $BED_DUR)")}"

echo "[directions] bed ${BED_DUR}s -> loop period ${PERIOD}s via ${BED_FIT}; total ${TOTAL}s @ ${W}x${H}"

# --- one loop unit of BED audio, at exactly PERIOD -------------------------
case "$BED_FIT" in
  tempo)  RATIO=$(python3 -c "print($BED_DUR/$PERIOD)")     # >1 = play faster
          BEDF="aresample=48000,atempo=${RATIO},atrim=0:${PERIOD},asetpts=N/SR/TB" ;;
  trim)   BEDF="aresample=48000,atrim=0:${PERIOD},asetpts=N/SR/TB" ;;
  native) BEDF="aresample=48000" ;;
  *)      echo "BED_FIT must be tempo|trim|native" >&2; exit 1 ;;
esac
ffmpeg -y -hide_banner -loglevel error -i "$BED" \
    -af "${BEDF},volume=${BED_GAIN}" -c:a pcm_s24le "$TMP/bed_unit.wav"

# --- one loop unit of VOICE audio: OFFSET of silence, then the read, padded --
ffmpeg -y -hide_banner -loglevel error -i "$VOICE" \
    -af "aresample=48000,volume=${VOICE_GAIN},adelay=delays=$(python3 -c "print(int($OFFSET*1000))"):all=1,apad,atrim=0:${PERIOD},asetpts=N/SR/TB" \
    -c:a pcm_s24le "$TMP/voice_unit.wav"

# --- one loop unit of ENERGY video: same OFFSET, padded to PERIOD -----------
# padded with black, which the luma key turns transparent, so no seam
ffmpeg -y -hide_banner -loglevel error -i "$ENERGY" \
    -vf "tpad=start_duration=${OFFSET}:stop_mode=add:stop_duration=${PERIOD},trim=0:${PERIOD},setpts=PTS-STARTPTS,fps=${FPS}" \
    -an -c:v libx264 -preset ultrafast -crf 14 -pix_fmt yuv420p "$TMP/energy_unit.mp4"

# --- tile the units to TOTAL and composite in one pass ----------------------
ffmpeg -y -hide_banner \
    -loop 1 -i "$CARD" \
    -stream_loop -1 -i "$TMP/energy_unit.mp4" \
    -stream_loop -1 -i "$TMP/voice_unit.wav" \
    -stream_loop -1 -i "$TMP/bed_unit.wav" \
    -filter_complex "\
[0:v]scale=${W}:${H},format=rgba[bg];\
[1:v]scale=${W}:${H},format=rgba,\
lumakey=threshold=${KEY_THRESH}:tolerance=${KEY_TOL}:softness=${KEY_SOFT}[key];\
[bg][key]overlay=format=auto,format=yuv420p[v];\
[2:a][3:a]amix=inputs=2:normalize=0:duration=longest[a]" \
    -map "[v]" -map "[a]" -t "$TOTAL" -r "$FPS" \
    -c:v libvpx-vp9 -b:v 0 -crf 30 -row-mt 1 -tile-columns 4 -threads 8 \
    -speed 2 -g "$FPS" -pix_fmt yuv420p -color_range tv \
    -c:a libopus -mapping_family 255 -b:a 1024k -ar 48000 \
    "$OUT"

echo "[directions] wrote $OUT"
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,channels \
        -show_entries format=duration -of default=noprint_wrappers=1 "$OUT"
peak=$(ffmpeg -hide_banner -nostats -i "$OUT" -af "pan=mono|c0=c0,volumedetect" -f null - 2>&1 \
       | grep max_volume | grep -oE '\-?[0-9.]+$' | tail -1)
echo "[directions] W-channel peak: ${peak} dBFS (negative = headroom)"
