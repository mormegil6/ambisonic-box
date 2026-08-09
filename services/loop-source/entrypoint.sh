#!/bin/sh
# loop-source entrypoint (mounted; the container is the unmodified earshot
# image). Demo-content policy, DEMO_CONTENT=1 by default:
#   - no content/demo.mp4 -> synthesise the spherical placeholder in-container
#     (this image IS the PCE-aware ffmpeg; no network involved, ~20 s once)
#   - fetch the VOD reference masters (only when VOD_ENABLED=1; default 0) from the pinned release in the
#     BACKGROUND (fail-soft; the loop never waits on the network)
# DEMO_CONTENT=0 does neither: idle-with-instructions
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

if [ "$DEMO_CONTENT" = "1" ] && [ "${VOD_ENABLED:-0}" = "1" ]; then
    # VOD masters, pinned tag + pinned SHA-256, cache-aware, fail-soft. Runs
    # backgrounded so a 185 MB first fetch never delays the stream; it keeps
    # running after the exec below (reparented, same container).
    sh "$DIR/fetch-demo-content.sh" &
elif [ "$DEMO_CONTENT" = "1" ]; then
    echo "[loop-source] VOD_ENABLED=0: skipping the reference-master fetch (set VOD_ENABLED=1 to also fetch the VOD reference masters)"
fi

if [ ! -f /content/demo.mp4 ]; then
    echo "[loop-source] /content/demo.mp4 not found - idling."
    echo "[loop-source] Prepare it once from your master recording (H.264 + 16-ch AAC),"
    echo "[loop-source] see .env.example for the exact command (or set DEMO_CONTENT=1"
    echo "[loop-source] to synthesise a placeholder automatically)."
    exec sleep 2147483647
fi

# Refuse to start without the key rather than falling back to a default. compose
# ALWAYS injects LOOP_SOURCE_KEY (docker-compose.yml carries its own
# ${LOOP_SOURCE_KEY:-hoast_demo} fallback), so an absent variable here does not
# mean "fresh install", it means this container was built against a DIFFERENT
# environment than the one now in .env - in practice a stale container that
# telemetry `docker start`ed instead of recreating, after the key was renamed or
# rotated. A `:-hoast_demo` fallback turns that into a silent publish with the
# public placeholder key, which rtmp-ingest then rejects, and the operator sees
# only "I/O error" with nothing pointing at the cause. That has now cost two
# debugging sessions (2026-07-22 on the STREAM_KEY split, 2026-08-09 on the
# LIVE_APP_KEY -> LOOP_SOURCE_KEY rename), so it fails loudly instead. The fix
# when this fires is `docker compose up -d --force-recreate loop-source`.
: "${LOOP_SOURCE_KEY:?[loop-source] LOOP_SOURCE_KEY is not set. compose always
    passes it, so this container predates the current .env - recreate it with:
    docker compose up -d --force-recreate loop-source}"

# Publish under a fixed, non-secret stream name (${DASH_NAME:-hoast_demo}) and
# pass LOOP_SOURCE_KEY as ?token= instead of using the key AS the stream name.
# rtmp-ingest matches LOOP_SOURCE_KEY only as ?token= (the stream-name form
# checks RTMP_OWNER_KEY), and a clean name keeps the secret out of the
# RTMP publish/relay log lines (which print the stream name); the token itself
# never reaches the /auth access log: that location logs with the token-free
# rtmpauth format and only when the publish is rejected.
echo "[loop-source] streaming /content/demo.mp4 -> rtmp://rtmp-ingest:1935/owner/${DASH_NAME:-hoast_demo} (token auth)"
exec ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i /content/demo.mp4 \
    -c copy -f flv "rtmp://rtmp-ingest:1935/owner/${DASH_NAME:-hoast_demo}?token=${LOOP_SOURCE_KEY}"
