#!/usr/bin/env bash
# Reproducible CRF sweep for choosing a delivery CRF.
#
# Encodes one segment of a source at a list of CRF values and reports the
# resulting video bitrate + size, plus the delivery bitrate once the 16-channel
# Opus track (1024 kbit/s, mapping_family 255) is added. This regenerates the
# data behind docs/PAPER-NOTES.md section 7 ("Perceived quality is capture-bound,
# not bitrate-bound"), so the raw encodes never need to be kept: run it, read the
# table, record the conclusion in PAPER-NOTES, delete the out-dir.
#
# Perceptual assessment is manual and in the target player, in the viewport (a
# viewer sees ~1/8 of the equirect frame magnified) - not a VMAF number. The
# section-7 finding was "no perceptible difference across CRF 21-27; the limiting
# artefacts are stitching seams and sensor noise, which no bitrate removes".
#
# Usage: scripts/crf-sweep.sh <source> [out-dir] [crf-list] [encoder] [scale] [seconds] [start]
#   defaults: out=./crf-sweep  crf="21 23 25 27"  encoder=libx264
#             scale=4096:2048   seconds=60         start=0
#   examples:
#     scripts/crf-sweep.sh concert_master.mp4                       # section-7 repro (x264, 4K)
#     scripts/crf-sweep.sh master.webm ./sweep "26 30 34" libsvtav1 7680:3840 30 65
set -euo pipefail

SRC="${1:?usage: crf-sweep.sh <source> [out-dir] [crf-list] [encoder] [scale] [seconds] [start]}"
OUT="${2:-./crf-sweep}"
CRFS="${3:-21 23 25 27}"
ENC="${4:-libx264}"
SCALE="${5:-4096:2048}"
SECS="${6:-60}"
SS="${7:-0}"
OPUS_KBPS=1024                 # 16-ch Opus, mapping_family 255 (see PAPER-NOTES section 7)

case "$ENC" in
  libx264|libx265) PRESET="-preset medium" ;;
  libsvtav1)       PRESET="-preset 6" ;;
  *)               PRESET="" ;;
esac

filesize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }

mkdir -p "$OUT"
echo "source=$SRC  encoder=$ENC $PRESET  scale=$SCALE  segment=${SECS}s @ ${SS}s"
printf "%-5s  %-9s  %-13s  %s\n" "CRF" "size" "video kbit/s" "delivery (+16ch Opus ${OPUS_KBPS}k)"
printf -- "-----  ---------  -------------  ------------------------------\n"
for crf in $CRFS; do
  f="$OUT/crf${crf}.mp4"
  ffmpeg -y -hide_banner -loglevel error -ss "$SS" -i "$SRC" -t "$SECS" \
    -vf "scale=${SCALE}:flags=lanczos" -an \
    -c:v "$ENC" $PRESET -crf "$crf" "$f"
  bytes=$(filesize "$f")
  kbps=$(awk "BEGIN{printf \"%d\", $bytes*8/1000/$SECS}")
  deliv=$(( kbps + OPUS_KBPS ))
  printf "%-5s  %-9s  %-13s  ~%s kbit/s\n" "$crf" "$(du -h "$f" | cut -f1)" "$kbps" "$deliv"
done
echo
echo "Assess perceptually in the player, in the viewport. Then record the finding"
echo "in docs/PAPER-NOTES.md and delete $OUT/ - the numbers, not the files, are the artefact."
