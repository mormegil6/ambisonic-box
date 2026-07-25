#!/usr/bin/env bash
# Synthesise a placeholder content/demo.mp4 so loop-source has something to
# publish: ffmpeg's testsrc2 pattern + a 16-channel AAC (PCE) bed of sines,
# 200..1700 Hz, one per channel in the hexadecagonal layout, so every
# ambisonic channel carries its own identifiable pitch.
#
# This is a stand-in for deployments without a real master recording (and the
# pre-flight of scripts/test-guest-endpoint.sh); it is NOT the reference
# content. For a real demo loop prepare a proper H.264 + 16-ch AAC master
# instead (.env.example, "Demo content").
#
# Uses the earshot image's ffmpeg: the 16-channel AAC needs its PCE-aware
# build, stock ffmpeg will not write those headers. Builds the image first if
# it is missing.
#
# Usage: scripts/make-demo-loop.sh [-o OUT] [-t SECONDS] [--force]
#   defaults: content/demo.mp4, 60 s. Refuses to overwrite without --force,
#   so it can never clobber a real master by accident.
set -eu
cd "$(dirname "$0")/.."

OUT=content/demo.mp4
SECS=60
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT=$2; shift 2 ;;
        -t) SECS=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "usage: $0 [-o OUT] [-t SECONDS] [--force]" >&2; exit 2 ;;
    esac
done

if [ -f "$OUT" ] && [ "$FORCE" != "1" ]; then
    echo "[make-demo-loop] $OUT exists; use --force to overwrite" >&2
    exit 1
fi

# one lavfi graph: testsrc2 video + 16 sines joined as a hexadecagonal bed
GRAPH="testsrc2=size=640x320:rate=30[out0];"
LABELS=""
for i in $(seq 0 15); do
    GRAPH="${GRAPH}sine=frequency=$((200 + i * 100)):sample_rate=48000[s$i];"
    LABELS="${LABELS}[s$i]"
done
GRAPH="${GRAPH}${LABELS}join=inputs=16:channel_layout=hexadecagonal[out1]"

docker image inspect hoa360-earshot:local >/dev/null 2>&1 \
    || docker compose build earshot

OUTDIR=$(cd "$(dirname "$OUT")" && pwd)
OUTNAME=$(basename "$OUT")
docker run --rm -v "$OUTDIR:/outdir" --entrypoint ffmpeg hoa360-earshot:local \
    -hide_banner -loglevel error -y -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 1M -g 60 -keyint_min 60 \
    -c:a aac -strict -2 -ac 16 -b:a 512k -t "$SECS" -movflags +faststart \
    "/outdir/$OUTNAME"

echo "[make-demo-loop] wrote $OUT (${SECS}s, testsrc2 + 16-ch AAC PCE sine bed)"
