#!/usr/bin/env bash
# Encode a VOD master (video + 16-ch audio) into an 8-rung AV1 ABR ladder plus a
# single 16-channel Opus audio rendition, ready for scripts/package-vod-dash.sh.
#
# All rungs are 2:1 equirectangular. GOP = 2 s so the DASH packager cuts segments
# on keyframes. SVT-AV1 v1.7 refuses 8K below preset M8, so the top rung uses
# preset 8; the rest use preset 6. Audio is 16-ch Opus (mapping_family 255),
# NEVER downmixed.
#
# Usage: scripts/encode-vod-ladder.sh <master.(webm|mov|mp4)> <out-dir> [crf] [fps]
#   defaults: crf 30, fps 24
set -euo pipefail
SRC="${1:?usage: encode-vod-ladder.sh <master> <out-dir> [crf] [fps]}"
OUT="${2:?output dir required}"
CRF="${3:-30}"
FPS="${4:-24}"
mkdir -p "$OUT"
GOP=$(( FPS * 2 ))

rungs=("7680 3840" "5760 2880" "3840 1920" "2880 1440" "1920 960" "1440 720" "1080 540" "720 360")
for r in "${rungs[@]}"; do
  set -- $r; W=$1; H=$2; name="v_${W}x${H}"
  preset=6; [ "$W" -ge 7680 ] && preset=8            # SVT-AV1 v1.7: 8K needs >= M8
  echo ">>> $name (crf $CRF preset $preset gop $GOP)"
  ffmpeg -y -hide_banner -loglevel error -i "$SRC" \
    -an -map 0:v:0 -vf "scale=${W}:${H}:flags=lanczos" \
    -c:v libsvtav1 -preset "$preset" -crf "$CRF" -g "$GOP" -pix_fmt yuv420p \
    "$OUT/${name}.mp4"
done

echo ">>> audio 16-ch Opus"
ffmpeg -y -hide_banner -loglevel error -i "$SRC" \
  -vn -map 0:a:0 -c:a libopus -mapping_family 255 -b:a 1024k \
  "$OUT/audio_16ch.webm"

echo "ladder written to $OUT"; ls -lh "$OUT"
