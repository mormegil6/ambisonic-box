#!/usr/bin/env bash
# E2E test for the SRT guest gateway: proves a live OBS-shaped SRT push (one
# mpegts, H.264 + four 4-channel AAC tracks) is admitted by the arbiter,
# merged to 16 discrete channels, and emerges from the full pipeline as
# 16-ch DASH Opus with every channel in its slot - and that a second
# concurrent caller is refused at the SRT handshake itself.
#
# Needs the compose stack already running with GUEST_ENABLED=1 and
# SRT_ENABLED=1 (see .env.example). GUEST_GW_SECRET is optional on this route:
# the guest gateway takes the RTMP republish hop by default
# (GUEST_SRT_DIRECT=0), which is exactly the route this test asserts, and
# telemetry honours the gateway's ?realip= attribution without a secret. It is
# NOT optional for the direct path - an unauthenticated gateway refuses guests
# there. The SRT caller runs inside the
# compose network using the gateway's own image, so the host needs no
# libsrt-enabled ffmpeg.
#
# Ends the session with the dashboard kill, which leaves the standard
# operator-kill cooldown (GUEST_COOLDOWN_S, default 300 s) on the guest slot.
#
# Usage: ./scripts/test-srt-ingest.sh
# Exit codes: 0 PASS, 1 FAIL, 2 precondition error.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${COMPOSE_PROJECT_NAME:-ambi-box}"
NET="${PROJECT}_default"
TEL=http://127.0.0.1:8090
WORK=scratch/srt-e2e
CALLER=srt-e2e-caller

fail() { echo "FAIL: $*" >&2; exit 1; }

SEGMARK=
cleanup() {
    docker rm -f "$CALLER" >/dev/null 2>&1 || true
    # output/ is the live DASH directory, so leave nothing of ours in it
    [ -n "$SEGMARK" ] && rm -f "$SEGMARK"
    return 0
}
trap cleanup EXIT

echo "[1/6] preconditions"
# Clip synthesis needs an ffmpeg, but not necessarily one on the host. Demanding
# a host binary made the RECOMMENDED route's test the only one a Docker-only
# machine could not run, while scripts/make-demo-loop.sh had already solved the
# same problem by borrowing the earshot image's ffmpeg. Prefer the host one when
# it is there (no container start, no bind mount), fall back to the image when
# it is not. Found by CI: ubuntu-latest no longer ships ffmpeg.
if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG_MODE=host
elif docker image inspect ambi-box-earshot:local >/dev/null 2>&1; then
    FFMPEG_MODE=container
else
    echo "need an ffmpeg: install one, or build the image (docker compose build earshot)" >&2
    exit 2
fi

# ONE dispatcher for every ffmpeg call in this script, and $FFW for the working
# directory as that ffmpeg sees it. There are two such calls, synthesis and
# decode; fixing only the first cost a CI cycle, because the decode's
# `2>/dev/null` swallowed "command not found" and the empty pipe reached
# check-tones.py as "0 samples", which the script then reported as a channel
# ORDER failure. A wrong diagnosis is worse than a loud one. Route any new
# ffmpeg call through here.
if [ "$FFMPEG_MODE" = host ]; then
    FFW="$WORK"
    ff() { ffmpeg "$@"; }
else
    FFW=/w
    ff() { docker run --rm -v "$PWD/$WORK:/w" --entrypoint ffmpeg ambi-box-earshot:local "$@"; }
fi
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }
docker compose ps --format '{{.Service}} {{.State}}' | grep -q "earshot running" \
    || { echo "compose stack not running (docker compose up -d)" >&2; exit 2; }
docker compose ps --format '{{.Service}} {{.State}}' | grep -q "srt-gateway running" \
    || { echo "srt-gateway not running" >&2; exit 2; }
GWSTATUS=$(docker compose exec -T srt-gateway python3 -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8091/status', timeout=3).read().decode())")
echo "  gateway: $GWSTATUS"
echo "$GWSTATUS" | grep -q '"enabled": true' \
    || { echo "gateway idle - set SRT_ENABLED=1 and recreate (GUEST_GW_SECRET is optional)" >&2; exit 2; }
curl -sf --max-time 3 "$TEL/api/live" >/dev/null \
    || { echo "telemetry not reachable on $TEL" >&2; exit 2; }

echo "[2/6] synthesising the OBS-shaped SRT payload (H.264 + 4x quad AAC tone ladder)"
rm -rf "$WORK" && mkdir -p "$WORK"
IN=()
for i in $(seq 0 15); do
    IN+=(-f lavfi -i "sine=frequency=$((100 + i * 100)):sample_rate=48000:duration=20")
done
FC=""
MAPS=()
for t in 0 1 2 3; do
    a=$((t * 4 + 1)); b=$((t * 4 + 2)); c=$((t * 4 + 3)); d=$((t * 4 + 4))
    # 4.0, not quad: it is what OBS tags its tracks, and it is the layout
    # proven to round-trip ffmpeg's AAC positionally (quad measurably
    # scrambles channel 2 through encode/decode - caught by this harness)
    FC="${FC}[${a}:a][${b}:a][${c}:a][${d}:a]amerge=inputs=4,pan=4.0|c0=c0|c1=c1|c2=c2|c3=c3[t${t}];"
    MAPS+=(-map "[t${t}]")
done
FF_ARGS=(-hide_banner -loglevel error -y
    -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=20"
    "${IN[@]}"
    -filter_complex "${FC%;}"
    -map 0:v "${MAPS[@]}"
    -c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p
    -c:a aac -b:a 384k
    -f mpegts)

[ "$FFMPEG_MODE" = host ] || echo "  (no host ffmpeg; using the earshot image)"
ff "${FF_ARGS[@]}" "$FFW/clip.ts"
[ -s "$WORK/clip.ts" ] || { echo "clip synthesis produced nothing" >&2; exit 2; }

echo "[3/6] pushing as an SRT caller from inside the compose network"
# Marker written BEFORE the push, so step 4 can tell this session's segments
# from whatever was already in output/. The demo loop is normally publishing
# when this test starts, and its chunks sit in the same directory with the same
# names - so "the two newest chunks" is only the right answer once the SRT
# session has actually written some. Same idiom as test-pipeline.sh.
SEGMARK=$(mktemp output/.srt-e2e.XXXXXX)
# -map 0 is load-bearing: without it ffmpeg's default stream selection sends
# ONE audio track of the four (the same footgun the Windows SRT receiver test
# hit), and the gateway's fixed 4x4 join then correctly refuses the input
docker run -d --name "$CALLER" --network "$NET" \
    -v "$PWD/$WORK:/w:ro" --entrypoint ffmpeg ambi-box-srt-gateway:local \
    -hide_banner -loglevel warning -re -stream_loop -1 -i /w/clip.ts \
    -map 0 -c copy -f mpegts \
    "srt://srt-gateway:8890?mode=caller&streamid=srte2e&latency=2000000" >/dev/null

ADOPTED=0
for _ in $(seq 1 30); do
    sleep 2
    STATE=$(curl -s --max-time 3 "$TEL/api/live" || true)
    if echo "$STATE" | grep -q '"name": "srte2e"' && echo "$STATE" | grep -q '"state": "live"'; then
        ADOPTED=1; break
    fi
    docker ps -q --no-trunc --filter name="$CALLER" | grep -q . \
        || fail "caller exited before adoption (rejected? check srt-gateway logs)"
done
[ "$ADOPTED" -eq 1 ] || fail "session never adopted as 'srte2e' (state: $(curl -s $TEL/api/live))"
echo "  adopted: srte2e is live"

echo "[4/6] verifying 16-ch DASH output (manifest + per-channel tones)"
# Poll rather than sleep a flat 10 s. Segments are 2 s, so two of them is the
# real precondition, and a slow or loaded host simply needs longer to cut them.
# A fixed sleep turns that into an intermittent red for a stack that is working.
SEGDEADLINE=60
t0=$(date +%s)
while :; do
    INIT=output/init-stream1.webm
    # -newer "$SEGMARK": only chunks this session produced. Without it the poll
    # matches the demo loop's leftovers on its first iteration and the whole
    # tone check runs against the wrong stream, reporting a channel-ORDER fault
    # for a perfectly good SRT session. That is what CI did on 2026-08-10, and
    # the giveaway in the log was "segments after 0s".
    FRESH=$(find output -maxdepth 1 -name 'chunk-stream1-*.webm' -newer "$SEGMARK" 2>/dev/null | wc -l | tr -d ' ')
    if [ -f "$INIT" ] && [ "$FRESH" -ge 2 ]; then
        CHUNK=$(find output -maxdepth 1 -name 'chunk-stream1-*.webm' -newer "$SEGMARK" 2>/dev/null \
                | sort | tail -2 | head -1)
        break
    fi
    if [ $(( $(date +%s) - t0 )) -ge "$SEGDEADLINE" ]; then
        fail "only $FRESH new DASH segments after ${SEGDEADLINE}s (session was adopted, so earshot is not cutting for it)"
    fi
    sleep 2
done
echo "  $FRESH fresh segments after $(( $(date +%s) - t0 ))s"

MPD=$(ls output/*.mpd 2>/dev/null | head -1)
[ -n "$MPD" ] || fail "no MPD in output/"
grep -q 'AudioChannelConfiguration[^/]*value="16"' "$MPD" \
    || fail "manifest does not declare 16 audio channels"
cat "$INIT" "$CHUNK" > "$WORK/dash-audio.webm"

# Decode to a file first, and assert it is non-empty, so a decode failure says
# so instead of arriving at check-tones.py as an empty stream and being reported
# as a channel-ORDER fault. That misdiagnosis is exactly what happened on
# 2026-08-10 when this call still required a host ffmpeg.
ff -v error -i "$FFW/dash-audio.webm" -ss 0.2 -t 1.5 -f s16le -c:a pcm_s16le - \
    > "$WORK/dash.pcm" 2> "$WORK/decode.err" || true
if [ ! -s "$WORK/dash.pcm" ]; then
    echo "  decoder said:" >&2
    head -5 "$WORK/decode.err" | sed 's/^/    /' >&2
    fail "could not decode the DASH audio at all (not a channel-order result)"
fi
python3 scripts/check-tones.py 16 48000 100 100 < "$WORK/dash.pcm" \
    || fail "channel order did not survive the SRT path (DASH Opus output)"

echo "[5/6] second concurrent caller must be rejected at the handshake"
set +e
timeout 15 docker run --rm --network "$NET" \
    -v "$PWD/$WORK:/w:ro" --entrypoint ffmpeg ambi-box-srt-gateway:local \
    -hide_banner -loglevel error -re -i /w/clip.ts -map 0 -c copy -t 4 -f mpegts \
    "srt://srt-gateway:8890?mode=caller&streamid=reject-probe&latency=2000000" \
    >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "second caller was accepted while a session was live"
curl -s --max-time 3 "$TEL/api/live" | grep -q '"name": "srte2e"' \
    || fail "first session lost during the second-caller probe"
echo "  rejected (rc=$RC), first session intact"

echo "[6/6] teardown: operator kill must drop the LIVE session end to end"
# kill while the caller is still pushing: this exercises the whole
# enforcement chain (403 at the next 10 s update ping -> nginx drops the
# publisher -> the gateway's relay dies -> the gateway drops the SRT caller)
curl -s -X POST --max-time 5 "$TEL/api/guest/kill" >/dev/null
ENDED=0
for _ in $(seq 1 15); do
    sleep 2
    curl -s --max-time 3 "$TEL/api/live" | grep -q '"state": "live"' || { ENDED=1; break; }
done
docker rm -f "$CALLER" >/dev/null 2>&1 || true
[ "$ENDED" -eq 1 ] || fail "session still live 30s after the kill"
echo "PASS (SRT caller admitted, 16 discrete ordered channels in DASH, second caller refused, kill honoured)"
echo "note: the guest slot now carries the standard operator-kill cooldown (${GUEST_COOLDOWN_S:-300}s)"
