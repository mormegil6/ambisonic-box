#!/usr/bin/env bash
# Synthesise the spherical placeholder demo loop: a black equirectangular
# sphere with the testsrc2 pattern as a ~90x45 degree screen at the front, and
# ONE 440 Hz source encoded to 3rd-order Ambisonics (SN3D/ACN) orbiting the
# listener with an elevation wobble, so the HOA rendering is audibly real.
#
# The graph is shared with the loop-source entrypoint (which synthesises the
# same file in-container when DEMO_CONTENT=1 and demo.mp4 is missing), so this
# utility and a fresh deployment produce the identical file. This is a
# stand-in, not the reference content; for a real demo loop prepare a proper
# H.264 + 16-ch AAC master instead (.env.example, "Demo content").
#
# Uses the earshot image's ffmpeg (stock ffmpeg 4.0+ also has a PCE-capable
# AAC encoder; the image just guarantees one without needing ffmpeg on the
# host). Builds the image first if it is missing.
#
# Usage: scripts/make-demo-loop.sh [-o OUT] [-t SECONDS] [--force]
#   defaults: content/demo.mp4, 60 s. Durations that are multiples of 30 s
#   loop seamlessly (orbit, wobble and carrier all complete integer cycles).
#   Refuses to overwrite without --force, so it can never clobber a real
#   master by accident.
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
if [ $((SECS % 30)) -ne 0 ]; then
    echo "[make-demo-loop] note: $SECS s is not a multiple of 30; the loop point will have a small spatial jump" >&2
fi

DEMO_DUR=$SECS
. services/loop-source/demo-graph.sh

docker image inspect ambi-box-earshot:local >/dev/null 2>&1 \
    || docker compose build earshot

OUTDIR=$(cd "$(dirname "$OUT")" && pwd)
OUTNAME=$(basename "$OUT")
# shellcheck disable=SC2086   # DEMO_ENC word-splitting is intentional
docker run --rm -v "$OUTDIR:/outdir" --entrypoint ffmpeg ambi-box-earshot:local \
    -hide_banner -loglevel error -y \
    -filter_complex "$DEMO_GRAPH" -map '[out0]' -map '[out1]' \
    $DEMO_ENC -t "$SECS" "/outdir/$OUTNAME"

echo "[make-demo-loop] wrote $OUT (${SECS}s: black sphere + front test screen, orbiting 3OA tone)"
