#!/usr/bin/env bash
# E2E test for the SRT guest gateway: proves a live OBS-shaped SRT push (one
# mpegts, H.264 + four 4-channel AAC tracks) is admitted by the arbiter,
# merged to 16 discrete channels, and emerges from the full pipeline as
# 16-ch DASH Opus with every channel in its slot - and that a second
# concurrent caller is refused at the SRT handshake itself.
#
# Needs the compose stack already running with GUEST_ENABLED=1, SRT_ENABLED=1
# and GUEST_GW_SECRET set (see .env.example). The SRT caller runs inside the
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

PROJECT="${COMPOSE_PROJECT_NAME:-hoa360}"
NET="${PROJECT}_default"
TEL=http://127.0.0.1:8090
WORK=scratch/srt-e2e
CALLER=srt-e2e-caller

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() { docker rm -f "$CALLER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[1/6] preconditions"
command -v ffmpeg >/dev/null || { echo "host ffmpeg required (clip synthesis)" >&2; exit 2; }
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
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=20" \
    "${IN[@]}" \
    -filter_complex "${FC%;}" \
    -map 0:v "${MAPS[@]}" \
    -c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p \
    -c:a aac -b:a 384k \
    -f mpegts "$WORK/clip.ts"

echo "[3/6] pushing as an SRT caller from inside the compose network"
# -map 0 is load-bearing: without it ffmpeg's default stream selection sends
# ONE audio track of the four (the same footgun the Windows SRT receiver test
# hit), and the gateway's fixed 4x4 join then correctly refuses the input
docker run -d --name "$CALLER" --network "$NET" \
    -v "$PWD/$WORK:/w:ro" --entrypoint ffmpeg hoa360-srt-gateway:local \
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
sleep 10       # let earshot cut a couple of segments beyond the handover
MPD=$(ls output/*.mpd 2>/dev/null | head -1)
[ -n "$MPD" ] || fail "no MPD in output/"
grep -q 'AudioChannelConfiguration[^/]*value="16"' "$MPD" \
    || fail "manifest does not declare 16 audio channels"
INIT=output/init-stream1.webm
CHUNK=$(ls -t output/chunk-stream1-*.webm 2>/dev/null | head -2 | tail -1)
[ -f "$INIT" ] && [ -n "$CHUNK" ] || fail "no DASH audio segments in output/"
cat "$INIT" "$CHUNK" > "$WORK/dash-audio.webm"
ffmpeg -v error -i "$WORK/dash-audio.webm" -ss 0.2 -t 1.5 -f s16le -c:a pcm_s16le - 2>/dev/null \
    | python3 scripts/check-tones.py 16 48000 100 100 \
    || fail "channel order did not survive the SRT path (DASH Opus output)"

echo "[5/6] second concurrent caller must be rejected at the handshake"
set +e
timeout 15 docker run --rm --network "$NET" \
    -v "$PWD/$WORK:/w:ro" --entrypoint ffmpeg hoa360-srt-gateway:local \
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
