#!/bin/sh
# loop-source entrypoint (mounted; the container is the unmodified earshot
# image). Demo-content policy, DEMO_CONTENT=1 by default:
#   - no content/demo.mp4 -> synthesise the spherical placeholder in-container
#     (this image IS the PCE-aware ffmpeg; no network involved, ~20 s once)
#   - fetch the VOD reference masters from the pinned release in the
#     BACKGROUND (fail-soft; the loop never waits on the network)
# DEMO_CONTENT=0 does neither: exactly the old idle-with-instructions
# behaviour when the file is absent.
set -u

DIR="$(dirname "$0")"
DEMO_CONTENT="${DEMO_CONTENT:-1}"

if [ "$DEMO_CONTENT" = "1" ] && [ ! -f /content/demo.mp4 ]; then
    echo "[loop-source] no demo.mp4 - synthesising the spherical placeholder (once, ~20 s)"
    . "$DIR/demo-graph.sh"
    if ffmpeg -hide_banner -loglevel error \
         -filter_complex "$DEMO_GRAPH" -map '[out0]' -map '[out1]' \
         $DEMO_ENC -t "$DEMO_DUR" /content/.demo.tmp.mp4 </dev/null; then
        mv /content/.demo.tmp.mp4 /content/demo.mp4
        echo "[loop-source] placeholder ready: black sphere + front test screen, orbiting 3OA tone"
    else
        rm -f /content/.demo.tmp.mp4
        echo "[loop-source] placeholder synthesis FAILED - continuing to the idle path"
    fi
fi

if [ "$DEMO_CONTENT" = "1" ]; then
    # VOD masters, pinned tag + pinned SHA-256, cache-aware, fail-soft. Runs
    # backgrounded so a 369 MB first fetch never delays the stream; it keeps
    # running after the exec below (reparented, same container).
    sh "$DIR/fetch-demo-content.sh" &
fi

if [ ! -f /content/demo.mp4 ]; then
    echo "[loop-source] /content/demo.mp4 not found - idling."
    echo "[loop-source] Prepare it once from your master recording (H.264 + 16-ch AAC),"
    echo "[loop-source] see .env.example for the exact command (or set DEMO_CONTENT=1"
    echo "[loop-source] to synthesise a placeholder automatically)."
    exec sleep 2147483647
fi

# Publish under a fixed, non-secret stream name (${DASH_NAME:-hoast_demo}) and
# pass STREAM_KEY as ?token= instead of using the key AS the stream name.
# rtmp-ingest accepts either, but a clean name keeps the secret out of the
# RTMP publish/relay log lines (which print the stream name); the token itself
# is suppressed by access_log off on the /auth location.
echo "[loop-source] streaming /content/demo.mp4 -> rtmp://rtmp-ingest:1935/live/${DASH_NAME:-hoast_demo} (token auth)"
exec ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i /content/demo.mp4 \
    -c copy -f flv "rtmp://rtmp-ingest:1935/live/${DASH_NAME:-hoast_demo}?token=${STREAM_KEY:-hoast_demo}"
