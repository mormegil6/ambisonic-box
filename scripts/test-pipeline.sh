#!/usr/bin/env bash
# Synthetic end-to-end pipeline test.
#
# Pushes a synthetic contribution stream: 16 sine channels (200..1700 Hz, one
# per channel, hexadecagonal layout) + testsrc2 video, H.264 + 16-ch AAC (PCE)
# in FLV, encoded by the earshot image's PCE-aware ffmpeg, through
# rtmp-ingest's token auth into earshot, then asserts live DASH appears in
# ./output/:
#   - <stream>.mpd manifest: valid XML, 16-ch Opus audio
#     (AudioChannelConfiguration value="16"), VP9 video (vp09) with the
#     default FFMPEG_FLAGS (avc1 accepted when the -c:v copy fallback is set)
#   - chunk files within FIRST_SEGMENT_DEADLINE seconds of the push start
#   - at least MIN_CHUNKS chunks per stream after the push completes
#
# The RTMP contribution leg is H.264 + 16-ch AAC by protocol necessity; the
# earshot transcode (16-ch Opus + VP9 WebM) is what this test verifies.
#
# The test publishes as "pipeline-test?token=$STREAM_KEY" (exercising the
# token-auth path). earshot writes every stream's chunks into the same
# directory with identical default names, so the test refuses to run while
# another publisher is active; if that publisher is loop-source, it is
# stopped for the duration of the test and restarted afterwards. The stack's
# prior state (running / stopped / absent) is restored on exit.
#
# The DASH manifest is named after DASH_NAME (default hoast_demo), NOT the
# publish name: earshot no longer interpolates the attacker-controllable publish
# name into the output path. This test still publishes as "pipeline-test" (to
# exercise token auth) but asserts on $DASH_NAME.mpd. Its cleanup therefore
# transiently removes the production manifest name, which loop-source
# regenerates within a segment or two of the restart this script performs.
#
# Usage: ./scripts/test-pipeline.sh
# Exit codes: 0 PASS, 1 FAIL, 2 precondition error.

set -euo pipefail
cd "$(dirname "$0")/.."

TEST_STREAM=pipeline-test
PUSH_CONTAINER=hoa360-pipeline-test-push
PUSH_SECONDS=30
HEALTHY_DEADLINE=120     # first `up` may also build images; polling starts after up returns
FIRST_SEGMENT_DEADLINE=20   # expectation is <15 s from push start
STOP_PUBLISH_DEADLINE=20
MIN_CHUNKS=5             # >=10 s of content at 2 s segments
OUTPUT_DIR=./output

# Read STREAM_KEY / FFMPEG_FLAGS the way compose resolves them: shell env
# first, then .env. Never shell-source .env - the compose dialect allows
# unquoted values with spaces (see FFMPEG_FLAGS in .env.example).
env_get() {
    sed -n "s/^$1=//p" .env | tail -1 \
        | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
if [ -z "${STREAM_KEY:-}" ] && [ -f .env ]; then STREAM_KEY=$(env_get STREAM_KEY); fi
if [ -z "${FFMPEG_FLAGS:-}" ] && [ -f .env ]; then FFMPEG_FLAGS=$(env_get FFMPEG_FLAGS); fi
STREAM_KEY="${STREAM_KEY:-hoast_demo}"
FFMPEG_FLAGS="${FFMPEG_FLAGS:-}"
if [ -z "${DASH_NAME:-}" ] && [ -f .env ]; then DASH_NAME=$(env_get DASH_NAME); fi
DASH_NAME="${DASH_NAME:-hoast_demo}"
# earshot names the manifest after DASH_NAME, not the publish name. TEST_STREAM
# stays the publish name so the ?token= path is still exercised.
TEST_MPD="$OUTPUT_DIR/$DASH_NAME.mpd"
case "$FFMPEG_FLAGS" in
    *"-c:v copy"*) VIDEO_CODEC=avc1 ;;   # H.264 passthrough fallback
    *)             VIDEO_CODEC=vp09 ;;   # default policy
esac

log()  { printf '[test-pipeline] %s\n' "$*"; }
fail() { log "FAIL: $*"; exit 1; }
pre()  { log "ERROR: $*"; exit 2; }

command -v docker >/dev/null || pre "docker not found"
docker compose version >/dev/null 2>&1 || pre "docker compose plugin not found"
docker info >/dev/null 2>&1 || pre "docker daemon not running"
mkdir -p "$OUTPUT_DIR"

fetch_stat() { curl -sf --max-time 5 http://localhost:8081/stat 2>/dev/null; }

# ---------------------------------------------------------------- cleanup ---
push_pid=
marker=
restart_loop_source=0
prior_state=absent
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$push_pid" ] && kill -0 "$push_pid" 2>/dev/null; then
        kill "$push_pid" 2>/dev/null || true
        wait "$push_pid" 2>/dev/null || true
    fi
    # the compose-run client dying does not stop the one-off container
    docker rm -f "$PUSH_CONTAINER" >/dev/null 2>&1 || true
    # let the transcoder notice the publisher is gone before touching output
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        s=$(fetch_stat) || break
        printf '%s' "$s" | grep -q '<publishing/>' || break
        sleep 1
    done
    if [ -n "$marker" ] && [ -f "$marker" ]; then
        # remove only what this run produced
        find "$OUTPUT_DIR" -maxdepth 1 \( -name 'chunk-stream*' -o -name 'init-stream*' \) \
            -newer "$marker" -delete 2>/dev/null || true
        rm -f "$TEST_MPD" "$marker"
    fi
    if [ "$restart_loop_source" = 1 ]; then
        log "restarting loop-source"
        docker compose start loop-source >/dev/null 2>&1 || true
    fi
    case "$prior_state" in
        absent)
            log "stack was not present before the test - taking it down"
            docker compose down >/dev/null 2>&1 || true ;;
        stopped)
            log "stack was stopped before the test - stopping it again"
            docker compose stop >/dev/null 2>&1 || true ;;
    esac
    exit "$status"
}
trap cleanup EXIT

# ------------------------------------------------------------ stack up ------
if [ "$(docker compose ps -q 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    prior_state=running
elif [ "$(docker compose ps -aq 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
    prior_state=stopped
fi
log "docker compose up -d (stack before: $prior_state)"
docker compose up -d

# nginx-rtmp resolves the push target once at startup: if `up` recreated
# earshot but left an older rtmp-ingest running, the relay points at a dead
# IP while both healthchecks stay green. Restart rtmp-ingest in that case.
eid=$(docker compose ps -q earshot 2>/dev/null || true)
iid=$(docker compose ps -q rtmp-ingest 2>/dev/null || true)
if [ -n "$eid" ] && [ -n "$iid" ]; then
    ec=$(docker inspect -f '{{.Created}}' "$eid" 2>/dev/null || true)
    ic=$(docker inspect -f '{{.Created}}' "$iid" 2>/dev/null || true)
    if [ -n "$ec" ] && [ -n "$ic" ] && [[ "$ec" > "$ic" ]]; then
        log "earshot is newer than rtmp-ingest - restarting rtmp-ingest to re-resolve the relay"
        docker compose restart rtmp-ingest >/dev/null
    fi
fi

log "waiting for services to be healthy (up to ${HEALTHY_DEADLINE}s)"
t0=$(date +%s)
while :; do
    unhealthy=$( (docker compose ps --format json 2>/dev/null || true) | python3 -c '
import json, sys
need = {"earshot", "rtmp-ingest", "hoast-player"}
try:
    raw = sys.stdin.read().strip()
    rows = json.loads(raw) if raw.startswith("[") else \
        [json.loads(l) for l in raw.splitlines() if l.strip()]
    healthy = {r.get("Service") for r in rows if r.get("Health") == "healthy"}
except Exception:
    healthy = set()
print(" ".join(sorted(need - healthy)))
')
    [ -z "$unhealthy" ] && break
    [ $(( $(date +%s) - t0 )) -ge "$HEALTHY_DEADLINE" ] && \
        fail "services not healthy after ${HEALTHY_DEADLINE}s: $unhealthy"
    sleep 2
done
log "all services healthy ($(( $(date +%s) - t0 ))s)"

# --------------------------------------------- publisher exclusivity --------
# earshot's chunk filenames collide between concurrent streams, so require
# exclusive use of the transcoder for the duration of the test. A failed stat
# fetch is an error, not "idle" - proceeding blind risks the collision.
stat_xml=$(fetch_stat) || pre "cannot reach earshot's stat endpoint (http://localhost:8081/stat)"
if printf '%s' "$stat_xml" | grep -q '<publishing/>'; then
    if docker compose exec -T loop-source pidof ffmpeg >/dev/null 2>&1; then
        log "loop-source is streaming - stopping it for the test"
        restart_loop_source=1   # set BEFORE stop: a failed stop must still restore it
        docker compose stop loop-source >/dev/null
        t0=$(date +%s)
        while :; do
            stat_xml=$(fetch_stat) || pre "stat endpoint went away while draining the stream"
            printf '%s' "$stat_xml" | grep -q '<publishing/>' || break
            [ $(( $(date +%s) - t0 )) -ge "$STOP_PUBLISH_DEADLINE" ] && \
                pre "stream still active ${STOP_PUBLISH_DEADLINE}s after stopping loop-source"
            sleep 1
        done
    else
        pre "another publisher is active (see http://localhost:8081/stat) - stop it and re-run"
    fi
fi

# ------------------------------------------------------------- push ---------
marker=$(mktemp "$OUTPUT_DIR/.test-pipeline.XXXXXX")
rm -f "$TEST_MPD"
docker rm -f "$PUSH_CONTAINER" >/dev/null 2>&1 || true   # stale from a crashed run

# One lavfi graph exposing two output pads: testsrc2 video and a 16-channel
# hexadecagonal bed of sines (200..1700 Hz, one per channel) - a single input
# so one -re paces the whole push in realtime.
graph="testsrc2=size=1920x960:rate=30[out0];"
labels=""
for i in $(seq 0 15); do
    graph+="sine=frequency=$((200 + i * 100)):sample_rate=48000[s$i];"
    labels+="[s$i]"
done
graph+="${labels}join=inputs=16:channel_layout=hexadecagonal[out1]"

log "pushing ${PUSH_SECONDS}s synthetic H.264 + 16-ch AAC (PCE) to live/${TEST_STREAM} (token auth)"
push_start=$(date +%s)
docker compose run --rm --no-deps -T --name "$PUSH_CONTAINER" \
    --entrypoint ffmpeg loop-source \
    -hide_banner -loglevel error \
    -re -f lavfi -i "$graph" \
    -map 0:v -map 0:a \
    -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
    -b:v 4M -g 60 -keyint_min 60 \
    -c:a aac -strict -2 -b:a 512k -ar 48000 \
    -t "$PUSH_SECONDS" \
    -f flv "rtmp://rtmp-ingest:1935/live/${TEST_STREAM}?token=${STREAM_KEY}" &
push_pid=$!

# ------------------------------------------- first-segment deadline ---------
t_first=
while :; do
    if [ -s "$TEST_MPD" ] && \
       [ -n "$(find "$OUTPUT_DIR" -maxdepth 1 -name 'chunk-stream*' -newer "$marker" -print -quit)" ]; then
        t_first=$(( $(date +%s) - push_start ))
        log "manifest + first chunk after ${t_first}s"
        break
    fi
    kill -0 "$push_pid" 2>/dev/null || fail "push exited before any segment appeared (auth or relay problem?)"
    [ $(( $(date +%s) - push_start )) -ge "$FIRST_SEGMENT_DEADLINE" ] && \
        fail "no manifest+chunk within ${FIRST_SEGMENT_DEADLINE}s of push start"
    sleep 1
done

push_rc=0
wait "$push_pid" || push_rc=$?
push_pid=
[ "$push_rc" -eq 0 ] || fail "synthetic push exited with status $push_rc"

# ------------------------------------------------------------ asserts -------
mpd="$TEST_MPD"
[ -s "$mpd" ] || fail "manifest $mpd missing after push"

if command -v xmllint >/dev/null; then
    xmllint --noout "$mpd" || fail "manifest is not valid XML"
else
    python3 -c "import xml.etree.ElementTree as ET, sys; ET.parse(sys.argv[1])" "$mpd" \
        || fail "manifest is not valid XML"
fi

grep -q "$VIDEO_CODEC" "$mpd" || fail "manifest lacks expected video codec $VIDEO_CODEC"
grep -q 'codecs="opus"' "$mpd" || fail "manifest lacks Opus audio"
grep -q 'AudioChannelConfiguration' "$mpd" || fail "manifest lacks AudioChannelConfiguration"
grep -q 'value="16"' "$mpd" || fail "manifest does not advertise 16 audio channels"

chunks_v=$(find "$OUTPUT_DIR" -maxdepth 1 -name 'chunk-stream0-*' -newer "$marker" | wc -l | tr -d ' ')
chunks_a=$(find "$OUTPUT_DIR" -maxdepth 1 -name 'chunk-stream1-*' -newer "$marker" | wc -l | tr -d ' ')
log "chunks written: stream0=$chunks_v stream1=$chunks_a"
[ "$chunks_v" -ge "$MIN_CHUNKS" ] && [ "$chunks_a" -ge "$MIN_CHUNKS" ] || \
    fail "expected at least $MIN_CHUNKS chunks per stream (got $chunks_v/$chunks_a)"

log "PASS: first segment after ${t_first}s (deadline ${FIRST_SEGMENT_DEADLINE}s), $chunks_v+$chunks_a chunks, 16-ch Opus + $VIDEO_CODEC manifest OK"
