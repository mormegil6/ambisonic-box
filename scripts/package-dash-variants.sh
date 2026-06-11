#!/usr/bin/env bash
# Package the demo master into four DASH variants for the lip-sync test
# Segment durations: 0.5 s, 1 s, 2 s, 4 s.
#
# Source: a VP9 + 16-channel Opus WebM master (default ./content/demo.webm).
#         NOTE: this is NOT ./content/demo.mp4; that file is the H.264 +
#         16-ch AAC copy used for the RTMP contribution leg, from which VP9
#         passthrough is impossible. Both streams are PASSED THROUGH here
#         (no transcode), so codecs and GOP come from the master.
#
# Output: ./lip-sync-test/dash_{0.5s,1s,2s,4s}/manifest.mpd  (+ video.webm,
#         audio.webm; WebM on-demand profile, same as HOAST360's demo media)
#
# GOP rule: subsegments must start on keyframes, so the master's keyframe
# interval must divide every segment duration. A 0.5 s GOP satisfies all four
# variants (e.g. -g 12 @ 25 fps was unattainable; use -g 12/13 ≈ 0.5 s, or
# re-encode the master with -g = segment_duration * fps). This script
# measures the real keyframe cadence with ffprobe and warns per variant.
#
# Packaging runs in the shaka service (compose profile `tools`,
# google/shaka-packager). Player assets (dist/, irs/) are copied into
# lip-sync-test/ so the page works with `python3 -m http.server` from there.
#
# Usage: scripts/package-dash-variants.sh [path/to/master.webm]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SRC="${1:-content/demo.webm}"
DURATIONS=("0.5" "1" "2" "4")
PROBE_WINDOW=30   # seconds of the master to scan for keyframes
TOLERANCE=0.02    # seconds; |k*GOP - segdur| below this counts as aligned

if [ ! -f "${SRC}" ]; then
    echo "ERROR: source master '${SRC}' not found." >&2
    echo "Expected a VP9 + 16-ch Opus WebM file (not demo.mp4, which is the" >&2
    echo "H.264/AAC RTMP contribution copy). Pass a path explicitly:" >&2
    echo "  $0 content/demo-master-master.webm" >&2
    exit 1
fi

# the shaka container only mounts ./content, so the master must live there
case "$(cd "$(dirname "${SRC}")" && pwd)" in
    "${REPO_ROOT}/content") ;;
    *)  echo "ERROR: source must be inside ./content/ (it is bind-mounted into" >&2
        echo "the shaka container). Copy it there first." >&2
        exit 1 ;;
esac

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffprobe not found on the host (apt install ffmpeg)." >&2
    exit 1
fi

# --- 1. verify passthrough codecs -------------------------------------------
VCODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "${SRC}")
ACODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "${SRC}")
ACHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "${SRC}")

echo "Source: ${SRC}  (video=${VCODEC}, audio=${ACODEC}/${ACHANNELS}ch)"

if [ "${VCODEC}" != "vp9" ] || [ "${ACODEC}" != "opus" ]; then
    echo "ERROR: passthrough packaging requires VP9 video and Opus audio." >&2
    echo "This file has ${VCODEC}/${ACODEC}. Use the WebM master, or re-encode" >&2
    echo "(use -g = segment_duration * fps)." >&2
    exit 1
fi
if [ "${ACHANNELS}" != "16" ]; then
    echo "WARNING: expected 16 audio channels (3rd-order Ambisonics), found ${ACHANNELS}." >&2
fi

# --- 2. measure keyframe cadence ---------------------------------------------
echo "Measuring keyframe interval over the first ${PROBE_WINDOW}s..."
KEYFRAME_TIMES=$(ffprobe -v error -select_streams v:0 -skip_frame nokey \
    -show_entries frame=pts_time -of csv=p=0 \
    -read_intervals "%+${PROBE_WINDOW}" "${SRC}" | grep -v '^$' || true)

GOP_SECONDS=$(echo "${KEYFRAME_TIMES}" | awk '
    NR > 1 { d = $1 - prev; sum += d; n++ }
    { prev = $1 }
    END { if (n > 0) printf "%.3f", sum / n; else print "unknown" }')

if [ "${GOP_SECONDS}" = "unknown" ]; then
    echo "WARNING: could not measure GOP (single keyframe in probe window?)." >&2
else
    echo "Mean keyframe interval: ${GOP_SECONDS}s"
fi

gop_aligned() { # gop_aligned <segdur> -> 0 if keyframes land on segment boundaries
    awk -v gop="${GOP_SECONDS}" -v seg="$1" -v tol="${TOLERANCE}" 'BEGIN {
        if (gop <= 0) exit 1
        k = int(seg / gop + 0.5)
        if (k < 1) k = 1
        exit ((k * gop - seg < tol) && (seg - k * gop < tol)) ? 0 : 1
    }'
}

# --- 3. package each variant --------------------------------------------------
for D in "${DURATIONS[@]}"; do
    OUTDIR="lip-sync-test/dash_${D}s"
    echo
    echo "=== Variant ${D}s -> ${OUTDIR}/"

    if [ "${GOP_SECONDS}" != "unknown" ] && ! gop_aligned "${D}"; then
        echo "WARNING: keyframe interval ${GOP_SECONDS}s does not align with ${D}s segments;" >&2
        echo "         subsegment boundaries will drift from the requested duration." >&2
    fi

    rm -rf "${OUTDIR}"
    mkdir -p "${OUTDIR}"

    docker compose --profile tools run --rm --no-deps \
        --user "$(id -u):$(id -g)" \
        shaka \
        "in=/content/$(basename "${SRC}"),stream=video,output=/lip-sync-test/dash_${D}s/video.webm" \
        "in=/content/$(basename "${SRC}"),stream=audio,output=/lip-sync-test/dash_${D}s/audio.webm" \
        --segment_duration "${D}" \
        --mpd_output "/lip-sync-test/dash_${D}s/manifest.mpd"
done

# --- 4. copy player assets so lip-sync-test/ is self-contained ----------------
echo
echo "Copying HOAST360 player assets into lip-sync-test/..."
mkdir -p lip-sync-test/dist lip-sync-test/irs
cp hoast360/dist/hoast360.bundle.js lip-sync-test/dist/
cp hoast360/irs/*.wav lip-sync-test/irs/

# --- 5. report -----------------------------------------------------------------
echo
echo "=== Output sizes:"
du -sh lip-sync-test/dash_*s
echo
echo "Done. Serve the comparison page with:"
echo "  cd lip-sync-test && python3 -m http.server 9000"
echo "then open http://localhost:9000"
