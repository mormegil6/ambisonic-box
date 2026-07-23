#!/usr/bin/env bash
# Encode a VOD master (video + 16-ch audio) into an 8-rung AV1 ABR ladder plus a
# single 16-channel Opus audio rendition, ready for scripts/package-vod-dash.sh.
#
# All rungs are 2:1 equirectangular at preset 6. GOP = 2 s so the DASH packager
# cuts segments on keyframes. Audio is 16-ch Opus (mapping_family 255), NEVER
# downmixed.
#
# The top rung used to be forced to preset 8, because SVT-AV1 v1.7 refused 8K
# below M8. That restriction is gone as of v4.2.0. Dropping it is a trade, not
# a free win: on the full 120 s directions clip, preset 6 produces 169.5 MB at
# SSIM 0.997129 (25.42 dB) against preset 8's 184.0 MB at 0.997346 (25.76 dB).
# So 7.8 % fewer bytes for 0.34 dB less fidelity, at ~2.8x the encode time
# (4m15 against 1m30).
#
# Preset 6 is kept because the 8K rung is the one that strains the player: it
# is what pushed dash.js past the MSE buffer quota and had to be capped in the
# fork, so bytes off the top rung buy real headroom, and 0.34 dB of SSIM on a
# 25 dB clip is not visible. Measure again for content that is not this one -
# a 10 s excerpt of the same source suggested preset 6 won on BOTH axes, which
# the full-length encode did not bear out. If you are on an SVT-AV1 older than
# about v2, check the top rung still encodes at all before trusting this.
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
mkdir -p "$OUT"
GOP=$(( FPS * 2 ))

LOOP_IN=(); LOOP_OUT=()
if [ "$LOOP_TO" != "0" ]; then
  LOOP_IN=(-stream_loop -1); LOOP_OUT=(-t "$LOOP_TO")
  echo "looping ${SRC##*/} to ${LOOP_TO}s"
fi

rungs=("7680 3840" "5760 2880" "3840 1920" "2880 1440" "1920 960" "1440 720" "1080 540" "720 360")
for r in "${rungs[@]}"; do
  set -- $r; W=$1; H=$2; name="v_${W}x${H}"
  preset=6
  echo ">>> $name (crf $CRF preset $preset gop $GOP)"
  ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
    -an -map 0:v:0 -vf "scale=${W}:${H}:flags=lanczos" \
    -c:v libsvtav1 -preset "$preset" -crf "$CRF" -g "$GOP" -pix_fmt yuv420p \
    "${LOOP_OUT[@]}" "$OUT/${name}.mp4"
done

echo ">>> audio 16-ch Opus"
ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
  -vn -map 0:a:0 -c:a libopus -mapping_family 255 -b:a 1024k \
  "${LOOP_OUT[@]}" "$OUT/audio_16ch.webm"

echo "ladder written to $OUT"; ls -lh "$OUT"
