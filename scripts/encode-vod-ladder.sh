#!/usr/bin/env bash
# Encode a VOD master (video + 16-ch audio) into an 8-rung AV1 ABR ladder plus a
# single 16-channel Opus audio rendition, ready for scripts/package-vod-dash.sh.
#
# All rungs are 2:1 equirectangular. GOP = 2 s so the DASH packager
# cuts segments on keyframes. Audio is 16-ch Opus (mapping_family 255), NEVER
# downmixed.
#
# PRESET defaults to 4 because slower presets measured better on BOTH size and
# fidelity at every rung - not the usual trade. Full 120 s directions clip,
# SSIM against the source over a 30 s window:
#
#   7680x3840   p6 169.5 MB 25.419 dB  ->  p5 147.1 MB 25.974 dB   -13.2 %, +0.55 dB
#   5760x2880   p6 122.9 MB 25.749 dB  ->  p4 102.5 MB 26.255 dB   -16.6 %, +0.51 dB
#   3840x1920   p6  56.3 MB 24.777 dB  ->  p4  44.7 MB 25.122 dB   -20.5 %, +0.35 dB
#   1920x960    p6  19.8 MB 24.236 dB  ->  p4  16.6 MB 24.523 dB   -16.2 %, +0.29 dB
#
# Cost is 1.2-1.7x encode time. Fewer bytes on the top rung matter beyond
# bandwidth: the 8K rung is what pushed dash.js past the MSE buffer quota and
# forced the cap in the player fork.
#
# SVT-AV1 refuses 8K below a preset floor, and the floor MOVES between versions:
# v1.7 allows only M8 and faster, v4.2 allows M5 and faster. The rung fails
# outright rather than degrading. So each rung is attempted at PRESET, and on
# refusal the floor is read straight out of the error text
# ("8k+ resolution support is limited to M5 and faster presets") and retried
# there - which keeps the best preset each library actually permits instead of
# pinning to the oldest one's floor. current distro ffmpeg builds still ship SVT-AV1 v1.7, so
# this path is live, not theoretical.
#
# Measure again for other content, and full length: a 10 s excerpt of this same
# source once pointed the opposite way from the 120 s encode.
#
# LOOP_TO repeats a short master until the given number of seconds, which is how
# the `directions` clip is built: its master is exactly one 11.083 s loop of the
# spoken reads, and the delivered clip is 2 min of it. Looping happens at read
# time rather than by writing an intermediate, which for an 8K ProRes master
# would be tens of gigabytes. Video and audio are looped in separate ffmpeg runs,
# which is only safe because both streams are an exact whole number of samples
# long (266 frames at 24 fps, 532000 samples at 48 kHz - both exactly 11.083333 s),
# so the two never drift apart at the seams. Check that before reusing this on
# another master.
#
# Usage: scripts/encode-vod-ladder.sh <master.(webm|mov|mp4)> <out-dir> [crf] [fps] [loop-to-seconds]
#   defaults: crf 30, fps 24, no looping
set -euo pipefail
SRC="${1:?usage: encode-vod-ladder.sh <master> <out-dir> [crf] [fps] [loop-to-seconds]}"
OUT="${2:?output dir required}"
CRF="${3:-30}"
FPS="${4:-24}"
LOOP_TO="${5:-0}"
PRESET="${PRESET:-4}"          # SVT-AV1 preset; rungs the library refuses fall
                               # back to the floor it names (see the loop below)
mkdir -p "$OUT"
GOP=$(( FPS * 2 ))

LOOP_IN=(); LOOP_OUT=()
if [ "$LOOP_TO" != "0" ]; then
  LOOP_IN=(-stream_loop -1); LOOP_OUT=(-t "$LOOP_TO")
  echo "looping ${SRC##*/} to ${LOOP_TO}s"
fi

encode_rung () {   # W H preset outfile errfile
  ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
    -an -map 0:v:0 -vf "scale=${1}:${2}:flags=lanczos" \
    -c:v libsvtav1 -preset "$3" -crf "$CRF" -g "$GOP" -pix_fmt yuv420p \
    "${LOOP_OUT[@]}" "$4" 2>"$5"
}

rungs=("7680 3840" "5760 2880" "3840 1920" "2880 1440" "1920 960" "1440 720" "1080 540" "720 360")
err=$(mktemp); trap 'rm -f "$err"' EXIT
for r in "${rungs[@]}"; do
  set -- $r; W=$1; H=$2; name="v_${W}x${H}"
  echo ">>> $name (crf $CRF preset $PRESET gop $GOP)"
  if ! encode_rung "$W" "$H" "$PRESET" "$OUT/${name}.mp4" "$err"; then
    # SVT-AV1 refuses 8K below a preset floor and fails the rung outright:
    #   Svt[error]: 8k+ resolution support is limited to M5 and faster presets.
    # The floor differs by version (M8 on v1.7, M5 on v4.2), so read it out of
    # the message rather than hard-coding either one. Anything else is a real
    # error and must not be retried.
    floor=$(grep -oiE "limited to M[0-9]+" "$err" | grep -oE "[0-9]+" | head -1)
    if [ -n "$floor" ]; then
      echo "    SVT-AV1 on this build refuses ${W}x${H} below M${floor}; retrying at preset ${floor}"
      encode_rung "$W" "$H" "$floor" "$OUT/${name}.mp4" "$err" || { cat "$err" >&2; exit 1; }
    else
      cat "$err" >&2; exit 1
    fi
  fi
done

echo ">>> audio 16-ch Opus"
ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
  -vn -map 0:a:0 -c:a libopus -mapping_family 255 -b:a 1024k \
  "${LOOP_OUT[@]}" "$OUT/audio_16ch.webm"

echo "ladder written to $OUT"; ls -lh "$OUT"
