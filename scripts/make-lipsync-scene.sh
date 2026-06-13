#!/usr/bin/env bash
# Build a lip-sync "scene" variant: a GOP-matched, limited-range excerpt of the
# 4K master, packaged at 2 s segments into lip-sync-test/dash_<LABEL>/ for the
# matching tab in lip-sync-test/index.html.
#
# Why this exists separately from package-dash-variants.sh: that script builds
# the four segment-duration variants (0.5/1/2/4 s) from the start of the master,
# where little happens, to compare segment durations. This script instead cuts a
# specific moment with a sharp audio+visual transient so lip-sync can be judged
# by eye/ear. The default targets 1:06:20 of the demo recording.
#
# Two things this guarantees that bare ffmpeg cuts do not:
#   1. limited-range (tv) VP9 (-vf scale=in_range=pc:out_range=tv -color_range
#      tv). The 4K master is full-range (pc); full-range VP9 breaks the
#      dash.js/MSE player (PIPELINE_ERROR_DECODE). See lip-sync-test/RESULTS.md.
#   2. -g 60 so keyframes land on the 2 s segment boundaries (29.97/30 fps).
#
# Usage: scripts/make-lipsync-scene.sh [START] [DURATION] [LABEL] [MASTER]
#   START     seek into the master, seconds or ffmpeg time (default 3980 = 1:06:20)
#   DURATION  excerpt length in seconds (default 90)
#   LABEL     output folder + index.html tab id (default 1h06)
#   MASTER    source 4K master (default content/demo_4k.webm)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

START="${1:-3980}"
DURATION="${2:-90}"
LABEL="${3:-1h06}"
MASTER="${4:-content/demo_4k.webm}"
SEG=2          # segment duration; matches the live stack and index.html tab
GOP=60         # 2 s at 29.97/30 fps

if [ ! -f "${MASTER}" ]; then
    echo "ERROR: master '${MASTER}' not found." >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not found on the host (apt install ffmpeg)." >&2
    exit 1
fi

EXCERPT="content/lipsync_${LABEL}_g${GOP}.webm"
SPLIT_V="content/.scene-split-video.webm"
SPLIT_A="content/.scene-split-audio.webm"
OUTDIR="lip-sync-test/dash_${LABEL}"
trap 'rm -f "${REPO_ROOT}/${SPLIT_V}" "${REPO_ROOT}/${SPLIT_A}"' EXIT

echo "Encoding ${DURATION}s excerpt from ${MASTER} at ${START} (tv range, -g ${GOP})..."
ffmpeg -y -v error -ss "${START}" -t "${DURATION}" -i "${MASTER}" \
    -vf "scale=in_range=pc:out_range=tv" -color_range tv \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -row-mt 1 -b:v 4M \
    -g "${GOP}" -keyint_min "${GOP}" -c:a copy "${EXCERPT}"

# shaka rejects ffmpeg's multi-track interleaving, so split to single-track
# inputs (stream copy, no re-encode). Same step as package-dash-variants.sh.
echo "Splitting into single-track inputs for shaka..."
ffmpeg -y -v error -i "${EXCERPT}" -map 0:v:0 -c copy "${SPLIT_V}"
ffmpeg -y -v error -i "${EXCERPT}" -map 0:a:0 -c copy "${SPLIT_A}"

echo "Packaging into ${OUTDIR}/ (discrete segments, static SegmentTemplate MPD)..."
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"
docker compose --profile tools run --rm --no-deps \
    --user "$(id -u):$(id -g)" \
    shaka \
    "in=/content/$(basename "${SPLIT_V}"),stream=video,init_segment=/lip-sync-test/dash_${LABEL}/video_init.webm,segment_template=/lip-sync-test/dash_${LABEL}/video_\$Number\$.webm" \
    "in=/content/$(basename "${SPLIT_A}"),stream=audio,init_segment=/lip-sync-test/dash_${LABEL}/audio_init.webm,segment_template=/lip-sync-test/dash_${LABEL}/audio_\$Number\$.webm" \
    --segment_duration "${SEG}" \
    --generate_static_live_mpd \
    --mpd_output "/lip-sync-test/dash_${LABEL}/manifest.mpd"

echo
echo "Done. dash_${LABEL}/ is served by the '${LABEL}' tab in lip-sync-test/index.html."
echo "  cd lip-sync-test && python3 -m http.server 9000   # then open http://localhost:9000"
