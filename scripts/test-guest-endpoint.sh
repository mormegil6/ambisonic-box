#!/usr/bin/env bash
# Guest test endpoint: full-cycle exercise of the arbiter and, above all, the
# RESUME path (loop -> guest -> loop), which is where stale state would bite.
#
# Runs, by default:
#   A1..A10  full cycles: loop live -> guest push -> clean stop -> grace
#            expiry -> loop resumed. Asserts single-writer handover, fresh
#            guest segments (new availabilityStartTime), no dangling guest
#            publisher on ingest, loop publishing again with 16-ch Opus.
#   T1       abrupt kill of the pusher (no RTMP teardown): drop_idle_publisher
#            must unpublish it, then grace, then resume.
#   T2       session cap expiry mid-publish: on_update answers non-2xx, the
#            publisher is dropped, session ends, loop resumes.
#   T3       reconnect inside grace: session continues (cap clock NOT reset),
#            then clean stop -> grace expiry -> resume.
#   T4       operator kill via /api/guest/kill: session ends within ~15 s,
#            the cooldown refuses an immediate re-publish, loop resumes.
#   R        second concurrent publisher is rejected fast; first is unharmed.
#   F        fail-closed: with telemetry stopped, a guest push is rejected and
#            the demo loop keeps publishing untouched.
#
# The stack is (re)started with GUEST_GRACE_S/GUEST_MAX_S shrunk so the run
# finishes in minutes; production defaults are untouched. Timings per cycle are
# printed at the end. Exit 0 all pass, 1 any fail, 2 precondition.
set -u
cd "$(dirname "$0")/.."

CYCLES=${CYCLES:-10}
TG_GRACE=${TG_GRACE:-10}          # test-run reconnect window (prod: 120)
TG_CAP=${TG_CAP:-45}              # test-run session cap      (prod: 10800)
TG_COOLDOWN=${TG_COOLDOWN:-8}     # test-run forced-end cooldown (prod: 300)
PUSH_S=${PUSH_S:-20}              # A-cycle guest publish length
TEL=http://127.0.0.1:8090
PLAYER=http://127.0.0.1:8080

log()  { printf '[guest-test] %s\n' "$*"; }
pre()  { log "PRECONDITION: $*"; exit 2; }
now()  { python3 -c 'import time; print(f"{time.time():.1f}")'; }

FAILS=0
REPORT=$(mktemp)
row()  { printf '%s\n' "$*" >> "$REPORT"; }
fail() { log "FAIL: $*"; row "FAIL: $*"; FAILS=$((FAILS+1)); }

docker info >/dev/null 2>&1 || pre "docker daemon not reachable"
docker compose version >/dev/null 2>&1 || pre "docker compose plugin not found"

# ------------------------------------------------------------ helpers -------
api() {  # api <path> -> body (empty on failure)
    curl -s --max-time 5 "$TEL$1" 2>/dev/null || true
}

jget() {  # jget <json> <dotted.path> -> value or empty
    python3 -c '
import sys, json
try:
    o = json.loads(sys.argv[1])
    for k in sys.argv[2].split("."):
        o = o[k]
    print("" if o is None else o)
except Exception:
    pass' "$1" "$2"
}

ep_state()   { jget "$(api /api/live)" endpoint.state; }
ep_name()    { jget "$(api /api/live)" endpoint.name; }
ep_remain()  { jget "$(api /api/live)" endpoint.remaining_s; }
live_now()   { jget "$(api /api/live)" live; }

loop_running() {
    # the real service container ONLY: our own guest pushers are one-off `run`
    # containers of the same loop-source service and must not count
    docker ps --filter "label=com.docker.compose.service=loop-source" \
              --filter "label=com.docker.compose.oneoff=False" \
              --format '{{.Names}}' 2>/dev/null | grep -q .
}

earshot_publishing() {
    docker compose exec -T telemetry curl -s --max-time 4 http://earshot/stat 2>/dev/null \
        | grep -q '<publishing/>'
}

ingest_guest_publishers() {  # publishers currently on the guest application
    docker compose exec -T telemetry sh -c \
        'curl -s --max-time 4 http://rtmp-ingest:8080/stat' 2>/dev/null | python3 -c '
import sys, re
x = sys.stdin.read()
m = re.search(r"<name>guest</name>(.*?)</application>", x, re.S)
print(m.group(1).count("<publishing/>") if m else 0)'
}

mpd_ast() {
    curl -s --max-time 4 "$PLAYER/dash/hoast_demo.mpd" 2>/dev/null \
        | grep -o 'availabilityStartTime="[^"]*"' | head -1
}

wait_for() {  # wait_for <desc> <deadline_s> <cmd...>; returns 0 met, 1 timeout
    local desc=$1 deadline=$2; shift 2
    local t0; t0=$(date +%s)
    while :; do
        if "$@"; then return 0; fi
        if [ $(( $(date +%s) - t0 )) -ge "$deadline" ]; then
            log "timeout waiting for: $desc"
            return 1
        fi
        sleep 0.5
    done
}

st_is()   { [ "$(ep_state)" = "$1" ]; }
is_live() { [ "$(live_now)" = "True" ] || [ "$(live_now)" = "true" ]; }

# 16-ch synthetic guest push, same shape as test-pipeline's: H.264 + 16-ch AAC
# (PCE) out of the earshot image's ffmpeg. Backgrounded; container is named so
# T1 can kill it abruptly.
GRAPH='testsrc2=size=640x320:rate=30[out0];sine=frequency=200:sample_rate=48000[s0];sine=frequency=300:sample_rate=48000[s1];sine=frequency=400:sample_rate=48000[s2];sine=frequency=500:sample_rate=48000[s3];sine=frequency=600:sample_rate=48000[s4];sine=frequency=700:sample_rate=48000[s5];sine=frequency=800:sample_rate=48000[s6];sine=frequency=900:sample_rate=48000[s7];sine=frequency=1000:sample_rate=48000[s8];sine=frequency=1100:sample_rate=48000[s9];sine=frequency=1200:sample_rate=48000[s10];sine=frequency=1300:sample_rate=48000[s11];sine=frequency=1400:sample_rate=48000[s12];sine=frequency=1500:sample_rate=48000[s13];sine=frequency=1600:sample_rate=48000[s14];sine=frequency=1700:sample_rate=48000[s15];[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9][s10][s11][s12][s13][s14][s15]join=inputs=16:channel_layout=hexadecagonal[out1]'

push_guest() {  # push_guest <name> <seconds> [sync]; sync: run in foreground, return ffmpeg rc
    local name=$1 secs=$2 mode=${3:-bg}
    docker rm -f "guestpush-$name" >/dev/null 2>&1 || true
    if [ "$mode" = sync ]; then
        docker compose run --rm --no-deps -T --name "guestpush-$name" \
            --entrypoint ffmpeg loop-source \
            -hide_banner -loglevel error \
            -re -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
            -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
            -b:v 800k -g 60 -keyint_min 60 \
            -c:a aac -strict -2 -b:a 256k -ar 48000 \
            -t "$secs" -f flv "rtmp://rtmp-ingest:1935/guest/$name" >/dev/null 2>&1
        return $?
    fi
    docker compose run --rm --no-deps -T --name "guestpush-$name" \
        --entrypoint ffmpeg loop-source \
        -hide_banner -loglevel error \
        -re -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
        -b:v 800k -g 60 -keyint_min 60 \
        -c:a aac -strict -2 -b:a 256k -ar 48000 \
        -t "$secs" -f flv "rtmp://rtmp-ingest:1935/guest/$name" >/dev/null 2>&1 &
}

# Wait through a grace window until the slot is free AND the loop publishes.
wait_resume() {  # wait_resume <label> -> echoes resume seconds, empty on fail
    local label=$1 t0 t1
    t0=$(now)
    wait_for "$label: slot free" $((TG_GRACE + 30)) st_is free || return 1
    wait_for "$label: loop publishing again" 40 earshot_publishing || return 1
    wait_for "$label: segments fresh" 30 is_live || return 1
    t1=$(now)
    python3 -c "print(f'{$t1 - $t0:.1f}')"
}

check_clean() {  # no dangling guest publisher, exactly the expected transcoders
    local label=$1
    local n; n=$(ingest_guest_publishers)
    [ "${n:-0}" = "0" ] || fail "$label: $n dangling guest publisher(s) on ingest"
    local mpd; mpd=$(curl -s --max-time 4 "$PLAYER/dash/hoast_demo.mpd" 2>/dev/null)
    echo "$mpd" | grep -q 'codecs="opus"' || fail "$label: manifest lacks Opus after resume"
    echo "$mpd" | grep -q 'value="16"'    || fail "$label: manifest lost 16 channels after resume"
}

# --------------------------------------------------------------- stack ------
log "building images touched by the guest feature"
docker compose build rtmp-ingest telemetry hoast-player >/dev/null 2>&1 || pre "image build failed"

if [ ! -f content/demo.mp4 ]; then
    log "content/demo.mp4 missing - synthesising a 60 s test loop (16-ch AAC PCE)"
    docker image inspect hoa360-earshot:local >/dev/null 2>&1 \
        || docker compose build earshot >/dev/null 2>&1 || true
    docker run --rm -v "$PWD/content:/content" --entrypoint ffmpeg hoa360-earshot:local \
        -hide_banner -loglevel error -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 1M -g 60 -keyint_min 60 \
        -c:a aac -strict -2 -ac 16 -b:a 512k -t 60 -movflags +faststart \
        /content/demo.mp4 || pre "could not synthesise content/demo.mp4"
fi

log "starting stack with GUEST_ENABLED=1 GRACE=$TG_GRACE CAP=$TG_CAP COOLDOWN=$TG_COOLDOWN TEL_IDLE_STOP_MIN=0"
export GUEST_ENABLED=1 GUEST_GRACE_S=$TG_GRACE GUEST_MAX_S=$TG_CAP GUEST_COOLDOWN_S=$TG_COOLDOWN TEL_IDLE_STOP_MIN=0
docker compose down --remove-orphans >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1 || pre "compose up failed"

wait_for "telemetry api" 60 sh -c "curl -s --max-time 2 $TEL/api/live | grep -q endpoint" \
    || pre "telemetry /api/live never answered"
wait_for "initial slot free" $((TG_GRACE + 20)) st_is free || pre "guest slot not free at start"
wait_for "loop publishing" 90 earshot_publishing || pre "demo loop never published"
wait_for "loop live" 60 is_live || pre "demo loop never became live"
log "stack up, loop live; starting cycles"

clear_pushers() {  # best-effort: remove stray guest pushers from failed cycles
    for c in $(docker ps --format '{{.Names}}' | grep '^guestpush-' || true); do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
}

# ------------------------------------------------------------- A-cycles -----
for i in $(seq 1 "$CYCLES"); do
    label="A$i"
    # start from a clean slot; one failed cycle must not cascade into the next
    if ! st_is free; then
        clear_pushers
        wait_for "$label: slot free to start" $((TG_GRACE + 40)) st_is free \
            || { fail "$label: slot never freed from previous cycle"; continue; }
        wait_for "$label: loop back before cycle" 60 is_live || true
    fi
    ast0=$(mpd_ast)
    fails0=$FAILS
    t0=$(now)
    push_guest "g$i" "$PUSH_S"
    # "live" is reported only once the handover completed (claim shows as
    # "handover"), so this measures the full takeover, loop unwind included
    if ! wait_for "$label: guest owns slot" 30 st_is live; then
        fail "$label: guest publish never accepted"; continue
    fi
    t1=$(now); takeover=$(python3 -c "print(f'{$t1 - $t0:.1f}')")
    loop_running && fail "$label: loop-source container still running under guest"
    # the old loop's segments stay "fresh" for up to SEG_STALE_S, so the proof
    # of the guest actually writing is the manifest's NEW availabilityStartTime
    ast_changed() { local a; a=$(mpd_ast); [ -n "$a" ] && [ "$a" != "$ast0" ]; }
    wait_for "$label: new DASH timeline from guest" 30 ast_changed \
        || fail "$label: availabilityStartTime never changed under guest"
    wait_for "$label: guest segments live" 30 is_live \
        || fail "$label: guest stream never became live"
    [ "$(ep_name)" = "g$i" ] || fail "$label: endpoint name is '$(ep_name)', wanted g$i"
    # clean stop: ffmpeg exits at -t, on_publish_done -> grace -> expiry -> resume
    wait_for "$label: grace after stop" $((PUSH_S + 25)) st_is grace \
        || fail "$label: never entered grace after clean stop"
    resume=$(wait_resume "$label") || { fail "$label: loop did not resume"; continue; }
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: takeover ${takeover}s, resume-after-grace ${resume}s"
        log "$label ok (takeover ${takeover}s, resume ${resume}s)"
    fi
done

# ------------------------------------------------------- T1 abrupt kill -----
label="T1-abrupt-kill"
fails0=$FAILS
push_guest tkill 300
if wait_for "$label: guest live" 30 st_is live; then
    sleep 3
    t0=$(now)
    docker kill guestpush-tkill >/dev/null 2>&1 || fail "$label: could not kill pusher"
    # no RTMP teardown: drop_idle_publisher(10s) must unpublish -> grace
    wait_for "$label: grace via idle-drop" 40 st_is grace \
        || fail "$label: dead publisher never entered grace"
    resume=$(wait_resume "$label") || fail "$label: loop did not resume"
    check_clean "$label"
    t1=$(now)
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: kill->loop-live $(python3 -c "print(f'{$t1 - $t0:.1f}')")s (incl. 10s idle-drop + ${TG_GRACE}s grace)"
        log "$label ok"
    fi
else
    fail "$label: guest publish never accepted"
fi

# ---------------------------------------------------------- T2 cap expiry ---
label="T2-cap"
fails0=$FAILS
push_guest tcap 300   # would run 5 min; cap is TG_CAP
if wait_for "$label: guest live" 30 st_is live; then
    t0=$(now)
    # session must end between cap and cap + update interval + margin
    wait_for "$label: capped session gone" $((TG_CAP + 30)) st_is free \
        || fail "$label: session outlived its cap"
    t1=$(now); held=$(python3 -c "print(f'{$t1 - $t0:.1f}')")
    docker rm -f guestpush-tcap >/dev/null 2>&1 || true
    # forced end => cooldown: an immediate reconnect (what OBS auto-reconnect
    # does) must be refused, or the cap is just a 45 s duty cycle
    push_guest tcap2 8 sync; rc2=$?
    [ "$rc2" -ne 0 ] || fail "$label: re-publish during cooldown was accepted"
    wait_for "$label: loop publishing again" 40 earshot_publishing || fail "$label: loop did not resume"
    wait_for "$label: loop live" 30 is_live || fail "$label: loop never became live"
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: session ended after ~${held}s (cap ${TG_CAP}s + <=10s ping); cooldown refused instant re-publish"
        log "$label ok (ended after ${held}s, cooldown enforced)"
    fi
    sleep "$TG_COOLDOWN"    # let the cooldown lapse before the next section
else
    fail "$label: guest publish never accepted"
fi

# ------------------------------------------------- T3 reconnect in grace ----
label="T3-reconnect"
fails0=$FAILS
push_guest trec1 12
if wait_for "$label: guest live" 30 st_is live; then
    r1=$(ep_remain)
    wait_for "$label: grace after first stop" 40 st_is grace \
        || fail "$label: no grace after first stop"
    push_guest trec2 10        # arrives inside the grace window
    wait_for "$label: reconnected" 20 st_is live \
        || fail "$label: reconnect inside grace not accepted"
    r2=$(ep_remain)
    # same session: the cap clock must NOT have reset (remaining well below r1)
    python3 -c "exit(0 if ($r2 + 8) < $r1 else 1)" 2>/dev/null \
        || fail "$label: cap clock reset on reconnect (r1=$r1 r2=$r2)"
    wait_for "$label: grace after second stop" 40 st_is grace \
        || fail "$label: no grace after second stop"
    resume=$(wait_resume "$label") || fail "$label: loop did not resume"
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: cap remaining $r1 -> $r2 across reconnect (not reset), resume ${resume}s"
        log "$label ok (remaining $r1 -> $r2)"
    fi
else
    fail "$label: guest publish never accepted"
fi

# ------------------------------------------------- T4 operator kill ---------
label="T4-kill"
fails0=$FAILS
push_guest tkil2 120
if wait_for "$label: guest live" 30 st_is live; then
    t0=$(now)
    curl -s --max-time 5 -X POST "$TEL/api/guest/kill" >/dev/null
    # dropped at the next update ping (<=10 s), session ends with NO grace
    wait_for "$label: session ended" 25 st_is free || fail "$label: kill did not end the session"
    t1=$(now)
    push_guest tkil3 8 sync; rc=$?
    [ "$rc" -ne 0 ] || fail "$label: re-publish right after kill was accepted (cooldown)"
    docker rm -f guestpush-tkil2 >/dev/null 2>&1 || true
    wait_for "$label: loop publishing again" 40 earshot_publishing || fail "$label: loop did not resume"
    wait_for "$label: loop live" 30 is_live || fail "$label: loop never became live"
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: kill->ended in $(python3 -c "print(f'{$t1 - $t0:.1f}')")s; cooldown refused instant re-claim"
        log "$label ok"
    fi
    sleep "$TG_COOLDOWN"    # let the cooldown lapse before the next section
else
    fail "$label: guest publish never accepted"
fi

# ------------------------------------------------- R second publisher -------
label="R-reject-second"
fails0=$FAILS
push_guest ra 40
if wait_for "$label: first guest live" 30 st_is live; then
    t0=$(now)
    push_guest rb 10 sync; rc=$?
    t1=$(now); rej=$(python3 -c "print(f'{$t1 - $t0:.1f}')")
    [ "$rc" -ne 0 ] || fail "$label: second publisher was NOT rejected (rc=0)"
    [ "$(ep_name)" = "ra" ] || fail "$label: slot owner changed to '$(ep_name)'"
    docker ps --format '{{.Names}}' | grep -q '^guestpush-ra$' \
        || fail "$label: first publisher died when second was rejected"
    # a wait, not an instant probe: this can run before the first guest's first
    # chunks exist (the timeline is mid-swap from the loop). If the rejection
    # had actually killed ra, no fresh segments would ever arrive and the loop
    # is stopped, so this times out and still catches the real defect.
    wait_for "$label: first guest's segments flowing" 25 is_live \
        || fail "$label: first guest's stream never flowed after rejection"
    docker ps --format '{{.Names}}' | grep -q '^guestpush-ra$' \
        || fail "$label: first publisher gone after rejection settled"
    wait_for "$label: grace after first ends" 60 st_is grace || fail "$label: no grace"
    wait_resume "$label" >/dev/null || fail "$label: loop did not resume"
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: second push rejected in ${rej}s (rc=$rc), first unharmed"
        log "$label ok (rejected in ${rej}s)"
    fi
else
    fail "$label: first guest publish never accepted"
fi

# ------------------------------------------------- F fail-closed ------------
label="F-fail-closed"
fails0=$FAILS
wait_for "$label: loop live before test" 60 is_live || fail "$label: loop not live pre-test"
docker compose stop telemetry >/dev/null 2>&1
sleep 2
push_guest fc 10 sync; rc=$?
[ "$rc" -ne 0 ] || fail "$label: guest accepted while telemetry down (rc=0)"
# loop unaffected: the live manifest keeps moving (publishTime advances)
p1=$(curl -s --max-time 4 "$PLAYER/dash/hoast_demo.mpd" | grep -o 'publishTime="[^"]*"')
sleep 5
p2=$(curl -s --max-time 4 "$PLAYER/dash/hoast_demo.mpd" | grep -o 'publishTime="[^"]*"')
{ [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ]; } \
    || fail "$label: demo loop stalled while telemetry was down ($p1 / $p2)"
docker compose start telemetry >/dev/null 2>&1
wait_for "$label: telemetry back" 60 sh -c "curl -s --max-time 2 $TEL/api/live | grep -q endpoint" \
    || fail "$label: telemetry did not come back"
wait_for "$label: slot free after restart" $((TG_GRACE + 30)) st_is free \
    || fail "$label: slot not free after telemetry restart"
is_live || wait_for "$label: loop still live" 30 is_live || fail "$label: loop lost after restart"
if [ "$FAILS" -eq "$fails0" ]; then
    row "$label: push rejected (rc=$rc) with telemetry down; loop kept publishing; clean state after restart"
    log "$label ok"
fi

# --------------------------------------------------------------- report -----
echo
echo "================ guest endpoint test report ================"
cat "$REPORT"
echo "============================================================"
rm -f "$REPORT"
if [ "$FAILS" -gt 0 ]; then
    log "RESULT: $FAILS failure(s)"
    exit 1
fi
log "RESULT: all cycles passed"
exit 0
