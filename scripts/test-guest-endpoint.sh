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
#   T5       stalled transcode: a MONO push (the classic wrong-audio mistake)
#            is auto-ended ~45 s after going live, the reason is surfaced on
#            /api/live, and there is NO cooldown (the fix should be instantly
#            retryable).
#   RB       report button path: accepted report returns ok, the 4th report
#            from one reporter IP inside the window is refused 429 "already
#            reported" (REPORT_IP_MAX=3) while a second reporter is not,
#            session counter grows.
#   BN       ban path (enforcement blocks only rows that are active-labelled,
#            unexpired by the clock, AND carry a non-truncated matching IP; see
#            collect._ban_blocks). End+ban ends the live session and the banned address is
#            refused at on_publish; unban lifts it. Edge cases per the design:
#            an active-labelled row that is time-expired, and one with a
#            redacted IP, must BOTH still be allowed to publish (the triple
#            rule protects against stale labels after a missed sweep).
#   R        second concurrent publisher is rejected fast; first is unharmed.
#   F        fail-closed: with telemetry stopped, a guest push is rejected and
#            the demo loop keeps publishing untouched.
#
# The stack is (re)started with GUEST_GRACE_S/GUEST_MAX_S shrunk so the run
# finishes in minutes. `.env` is never written, but the RUNNING CONTAINERS do
# carry the shrunk values while the suite is up, so an EXIT trap recreates the
# stack with them unset. Without that the box is left with a 45 s session cap,
# a 10 s grace and auto-idle disabled - which is exactly what happened on the
# reference deployment on 2026-08-10, where the demo loop then transcoded 4K
# for nobody until it was noticed. Timings per cycle are printed at the end.
# Exit 0 all pass, 1 any fail, 2 precondition.
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
GRAPH='testsrc2=size=640x320:rate=30[out0];sine=frequency=200:sample_rate=48000[s0];sine=frequency=300:sample_rate=48000[s1];sine=frequency=400:sample_rate=48000[s2];sine=frequency=500:sample_rate=48000[s3];sine=frequency=600:sample_rate=48000[s4];sine=frequency=700:sample_rate=48000[s5];sine=frequency=800:sample_rate=48000[s6];sine=frequency=900:sample_rate=48000[s7];sine=frequency=1000:sample_rate=48000[s8];sine=frequency=1100:sample_rate=48000[s9];sine=frequency=1200:sample_rate=48000[s10];sine=frequency=1300:sample_rate=48000[s11];sine=frequency=1400:sample_rate=48000[s12];sine=frequency=1500:sample_rate=48000[s13];sine=frequency=1600:sample_rate=48000[s14];sine=frequency=1700:sample_rate=48000[s15];[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9][s10][s11][s12][s13][s14][s15]join=inputs=16:channel_layout=hexadecagonal:map=0.0-FL|1.0-FR|2.0-FC|3.0-BL|4.0-BR|5.0-BC|6.0-SL|7.0-SR|8.0-TFL|9.0-TFC|10.0-TFR|11.0-TBL|12.0-TBC|13.0-TBR|14.0-WL|15.0-WR[out1]'

# A pusher's SOURCE ADDRESS is part of what the arbiter tests, because the grace
# window is address-locked (guest_publish refuses a reconnect from a different
# addr). `docker compose run` gives each push a fresh container and Docker's
# IPAM hands out the lowest free address, which CHANGES between two sequential
# pushes - admission stops loop-source and frees its address in between. So a
# "reconnect" used to arrive from a different IP and was correctly refused,
# and T3 never tested a reconnect at all.
#
# The fix is not to pin an address. `docker run --ip` only works on networks
# with a USER-CONFIGURED subnet, and compose lets Docker choose one, so it is
# refused on a stock runner ("user specified IP address is supported only when
# connecting to networks with user configured subnets") even though
# `docker network inspect` happily reports a subnet. That difference is
# invisible locally and cost a full CI run to find.
#
# Instead: one long-lived container on the compose network, and exec each push
# inside it. Same container means the same address by construction, on any
# Docker, with no assumptions about IPAM - and it is also what a real
# reconnecting encoder does.

# Fills the global FF_ARGS with the ffmpeg argv every pusher shares.
# Deliberately sets an array rather than printing lines for the caller to
# collect: reading them back would want `mapfile`, which is bash 4+, and macOS
# still ships bash 3.2 - so that version ran ffmpeg with an EMPTY argv and the
# suite failed on the operator's own machine while passing in CI.
FF_ARGS=()
build_ff_args() {  # build_ff_args <seconds> <stream name>
    FF_ARGS=(-hide_banner -loglevel error
        -re -f lavfi -i "$GRAPH" -map 0:v -map 0:a
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
        -b:v 800k -g 60 -keyint_min 60
        -c:a aac -b:a 256k -ar 48000
        -t "$1" -f flv "rtmp://rtmp-ingest:1935/guest/$2")
}

# --- shared-source pusher: successive pushes from ONE container, hence one
#     address. Used where the arbiter's address-locked grace is under test.
shared_up() {
    docker rm -f guestpush-shared >/dev/null 2>&1 || true
    docker run -d --rm --network "$PUSH_NET" --name guestpush-shared \
        --entrypoint sleep "$PUSH_IMG" 900 >/dev/null
    # `docker run -d` returns when the container is CREATED, not when it can
    # accept an exec. Reading straight through was a race: on 2026-08-12 two CI
    # cases (T3-reconnect, BN-ban) died on `exec: ""` because the lookup below
    # came back empty and the suite reported "no ffmpeg inside the shared pusher
    # image" - about an image that has ffmpeg at /usr/local/bin/ffmpeg and had
    # just been used successfully by ten A-cycles. Wait for the container to be
    # running before asking it anything. Same shape as the guest-handover race
    # fixed the same day: a one-shot check straight after an async docker call.
    ready_end=$(( $(date +%s) + 20 ))
    while [ "$(docker inspect -f '{{.State.Running}}' guestpush-shared 2>/dev/null)" != "true" ]; do
        [ "$(date +%s)" -ge "$ready_end" ] && { log "shared pusher never reached running state"; return 1; }
        sleep 0.3
    done
    SHARED_IP=$(docker inspect -f \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' guestpush-shared)
    [ -n "$SHARED_IP" ] || { log "could not read the shared pusher's address"; return 1; }
    # BOTH lookups, because neither is reliable alone and each fails on the
    # architecture the other works on. `docker exec` runs no login shell and
    # inherits whatever PATH the image config declares, which on the amd64 image
    # here omits /usr/local/bin, so `command -v` finds nothing even though the
    # binary is right there. A hardcoded path was the previous fix and it broke
    # the Pi 4 run on 2026-08-10 the other way round. Ask the container, then
    # fall back to probing the usual locations.
    # Retried for the same reason, and because 2>/dev/null turns a transient
    # exec failure into an empty string indistinguishable from a real absence.
    SHARED_FF=""
    ff_end=$(( $(date +%s) + 15 ))
    while : ; do
        SHARED_FF=$(docker exec guestpush-shared sh -c \
            'command -v ffmpeg || for p in /usr/local/bin/ffmpeg /usr/bin/ffmpeg /opt/ffmpeg/bin/ffmpeg; do [ -x "$p" ] && { echo "$p"; break; }; done' \
            2>/dev/null | tr -d '\r' | head -1)
        [ -n "$SHARED_FF" ] && break
        [ "$(date +%s)" -ge "$ff_end" ] && break
        sleep 0.5
    done
    if [ -z "$SHARED_FF" ]; then
        # Say what was actually observed rather than asserting the image is at
        # fault, which is the claim that misdirected this for a run.
        log "no ffmpeg found in the shared pusher after 15s (state: $(docker inspect -f '{{.State.Status}}' guestpush-shared 2>/dev/null)); the lookup said:"
        docker exec guestpush-shared sh -c 'command -v ffmpeg; ls -l /usr/local/bin/ffmpeg' 2>&1 | sed 's/^/      | /'
        return 1
    fi
    log "shared pusher up at $SHARED_IP (ffmpeg at $SHARED_FF)"
}
shared_push() {  # shared_push <name> <seconds> - starts, does not wait
    local name=$1 secs=$2
    last_push=shared
    build_ff_args "$secs" "$name"
    # `docker exec` runs no login shell, so a bare `ffmpeg` is not found. An
    # absolute path fixed that and introduced a worse bug: it assumed a layout.
    # The Pi 4 run on 2026-08-10 failed BN-ban and T3 with
    # `exec: "/usr/local/bin/ffmpeg": no such file or directory` while every
    # A-cycle passed, because those two cases are the only ones that go through
    # this helper. $SHARED_FF is resolved once from inside the container itself,
    # which is right on any architecture and any image compose picks.
    docker exec -d guestpush-shared "$SHARED_FF" "${FF_ARGS[@]}"
}
shared_stop_push() { docker exec guestpush-shared pkill -f ffmpeg >/dev/null 2>&1 || true; }
shared_down()      { docker rm -f guestpush-shared >/dev/null 2>&1 || true; }

push_guest() {  # push_guest <name> <seconds> [sync|bg]
    local name=$1 secs=$2 mode=${3:-bg}
    last_push=$name          # so why_not_live knows whose log to dump
    docker rm -f "guestpush-$name" >/dev/null 2>&1 || true
    local -a run
    run=(docker compose run --rm --no-deps -T --name "guestpush-$name"
         --entrypoint ffmpeg loop-source)
    if [ "$mode" = sync ]; then
        "${run[@]}" \
            -hide_banner -loglevel error \
            -re -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
            -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
            -b:v 800k -g 60 -keyint_min 60 \
            -c:a aac -b:a 256k -ar 48000 \
            -t "$secs" -f flv "rtmp://rtmp-ingest:1935/guest/$name" >"/tmp/guestpush-$name.log" 2>&1
        return $?
    fi
    "${run[@]}" \
        -hide_banner -loglevel error \
        -re -f lavfi -i "$GRAPH" -map 0:v -map 0:a \
        -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
        -b:v 800k -g 60 -keyint_min 60 \
        -c:a aac -b:a 256k -ar 48000 \
        -t "$secs" -f flv "rtmp://rtmp-ingest:1935/guest/$name" >"/tmp/guestpush-$name.log" 2>&1 &
}

# Why a pusher never went live. Without this the failure is just "guest publish
# never accepted", which is true of a refused publish, a container that could
# not be created, and a DNS failure alike - three very different bugs.
why_not_live() {  # why_not_live <name>
    local name=$1
    echo "[guest-test]   pusher log (/tmp/guestpush-$name.log):"
    sed 's/^/[guest-test]     /' "/tmp/guestpush-$name.log" 2>/dev/null | head -15         || echo "[guest-test]     (no log - container may never have started)"
    echo "[guest-test]   arbiter's last words:"
    docker compose logs --tail 15 telemetry 2>/dev/null         | grep -iE "guest|reject|ban|grace" | sed 's/^/[guest-test]     /' | tail -8
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
    log "content/demo.mp4 missing - synthesising a placeholder loop"
    ./scripts/make-demo-loop.sh >/dev/null 2>&1 || pre "could not synthesise content/demo.mp4"
fi

log "starting stack with GUEST_ENABLED=1 GRACE=$TG_GRACE CAP=$TG_CAP COOLDOWN=$TG_COOLDOWN TEL_IDLE_STOP_MIN=0"

# Put the deployment back however this exits, including Ctrl-C and a failed
# precondition. `env -u` rather than restoring saved values on purpose: the
# right end state is whatever docker-compose.yml and .env say, not whatever
# happened to be exported when the suite started.
restore_stack() {
    local rc=$?
    [ -n "${REPORT:-}" ] && rm -f "$REPORT"
    log "restoring production timings (unsetting the suite's overrides)"
    env -u GUEST_GRACE_S -u GUEST_MAX_S -u GUEST_COOLDOWN_S -u TEL_IDLE_STOP_MIN \
        docker compose up -d --force-recreate --no-deps telemetry >/dev/null 2>&1 \
        || log "WARNING: could not restore telemetry; run 'docker compose up -d --force-recreate telemetry' by hand"
    return $rc
}
trap restore_stack EXIT

export GUEST_ENABLED=1 GUEST_GRACE_S=$TG_GRACE GUEST_MAX_S=$TG_CAP GUEST_COOLDOWN_S=$TG_COOLDOWN TEL_IDLE_STOP_MIN=0
docker compose down --remove-orphans >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1 || pre "compose up failed"

wait_for "telemetry api" 60 sh -c "curl -s --max-time 2 $TEL/api/live | grep -q endpoint" \
    || pre "telemetry /api/live never answered"
wait_for "initial slot free" $((TG_GRACE + 20)) st_is free || pre "guest slot not free at start"
wait_for "loop publishing" 90 earshot_publishing || pre "demo loop never published"
wait_for "loop live" 60 is_live || pre "demo loop never became live"

# Derived, not hardcoded: the compose project was renamed once already, and the
# image comes from compose itself, so neither can drift. No subnet arithmetic
# here any more - the shared pusher gets whatever address Docker gives it and
# simply keeps it, which works on every Docker rather than only on networks
# with a user-configured subnet.
PUSH_NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' \
    "$(docker compose ps -q telemetry)" 2>/dev/null)
PUSH_IMG=$(docker compose config --images loop-source 2>/dev/null | head -1)
[ -n "$PUSH_NET" ] && [ -n "$PUSH_IMG" ] \
    || pre "could not derive the pusher network/image (net='$PUSH_NET' img='$PUSH_IMG')"

log "stack up, loop live; starting cycles (pusher image $PUSH_IMG on $PUSH_NET)"

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
        fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"; continue
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
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
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
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
fi

# ------------------------------------------------- T3 reconnect in grace ----
label="T3-reconnect"
fails0=$FAILS
# BOTH pushes pin the same source address, because grace is address-locked and a
# reconnect from a different addr is refused by design. Without this the two
# containers get different IPs and this never tested a reconnect at all.
shared_up || fail "$label: shared pusher would not start"
shared_push trec1 12
if wait_for "$label: guest live" 30 st_is live; then
    r1=$(ep_remain)
    wait_for "$label: grace after first stop" 40 st_is grace \
        || fail "$label: no grace after first stop"
    shared_push trec2 10                 # same container, so the same caller
    wait_for "$label: reconnected" 20 st_is live \
        || fail "$label: reconnect inside grace not accepted"
    r2=$(ep_remain)
    # same session: the cap clock must NOT have reset (remaining well below r1).
    # r2 must be a real number - it was empty for as long as the reconnect was
    # being refused, and an empty operand made this comparison vacuously true.
    [ -n "$r2" ] && [ -n "$r1" ] \
        || fail "$label: no cap clock to compare (r1='$r1' r2='$r2')"
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
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
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
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
fi

# ------------------------------------------------- T5 stalled transcode -----
label="T5-stall"
fails0=$FAILS
# mono: valid H.264+AAC contribution, wrong channel count; earshot's exec
# produces nothing and, before the detector, squatted the slot for the cap
docker rm -f guestpush-tmono >/dev/null 2>&1 || true
docker compose run --rm --no-deps -T --name guestpush-tmono --entrypoint ffmpeg loop-source \
  -hide_banner -loglevel error -re -f lavfi \
  -i "testsrc2=size=320x160:rate=30[out0];sine=frequency=440:sample_rate=48000[out1]" \
  -map '0:v' -map '0:a' -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 \
  -c:a aac -b:a 96k -t 180 -f flv rtmp://rtmp-ingest:1935/guest/tmono >/dev/null 2>&1 &
if wait_for "$label: mono guest live" 30 st_is live; then
    t0=$(now)
    # detector arms at 45 s + drop at next 10 s ping + teardown
    wait_for "$label: auto-ended" 90 st_is free || fail "$label: stalled session not auto-ended"
    t1=$(now)
    reason=$(curl -s "$TEL/api/live" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("endpoint",{}).get("last_end_reason",""))')
    # Assert the INVARIANT prefix, not the channel-count tail. This used to grep
    # "16-channel" and broke when 1st order became a legal layout and the message
    # became "...(ambisonic audio required: 4 or 16 channels)". The tail is
    # documentation that moves whenever accepted layouts change; "no playable
    # output" is also the substring the player itself keys on to show the banner
    # (services/hoast-player/index.html), so pinning to it couples the test to the
    # same contract the shipped consumer depends on.
    echo "$reason" | grep -q "no playable output" || fail "$label: end reason not surfaced (got: '$reason')"
    docker rm -f guestpush-tmono >/dev/null 2>&1 || true
    # NO cooldown after a stall: an immediate correct retry must be accepted
    push_guest tfixed 15
    wait_for "$label: corrected 16-ch retry accepted" 30 st_is live \
        || fail "$label: retry after stall was refused (cooldown wrongly applied?)"
    wait_for "$label: retry grace" 40 st_is grace || fail "$label: retry never ended"
    wait_resume "$label" >/dev/null || fail "$label: loop did not resume"
    check_clean "$label"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: mono auto-ended in $(python3 -c "print(f'{$t1 - $t0:.1f}')")s, reason surfaced, corrected retry accepted instantly"
        log "$label ok"
    fi
else
    fail "$label: mono guest publish never accepted"
fi

# ------------------------------------------------- RB report button ---------
label="RB-report"
fails0=$FAILS
push_guest trep 40
if wait_for "$label: guest live" 30 st_is live; then
    # direct to telemetry with forged headers: the nginx brake is per real
    # viewer IP and is exercised separately; here we verify the app logic
    r1=$(curl -s -X POST -H "X-Viewer-IP: 198.51.100.20" -H "X-Viewer-CC: DE" "$TEL/api/guest/report")
    echo "$r1" | grep -q '"ok": true' || fail "$label: first report not accepted ($r1)"
    r2=$(curl -s -X POST -H "X-Viewer-IP: 198.51.100.20" -H "X-Viewer-CC: DE" "$TEL/api/guest/report")
    r3=$(curl -s -X POST -H "X-Viewer-IP: 198.51.100.20" -H "X-Viewer-CC: DE" "$TEL/api/guest/report")
    r4=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Viewer-IP: 198.51.100.20" "$TEL/api/guest/report")
    [ "$r4" = "429" ] || fail "$label: 4th report from same IP not rate-limited (got $r4)"
    r5=$(curl -s -X POST -H "X-Viewer-IP: 203.0.113.9" -H "X-Viewer-CC: FR" "$TEL/api/guest/report")
    echo "$r5" | grep -q '"ok": true' || fail "$label: different reporter wrongly limited ($r5)"
    grep -c 'trep' "$(docker compose ps -q telemetry | head -1)" >/dev/null 2>&1 || true
    n=$(docker compose exec -T telemetry sh -c 'grep -c trep /data/guest_reports.csv 2>/dev/null' || echo 0)
    [ "${n:-0}" -ge 4 ] || fail "$label: reports CSV has $n rows for the session, expected >=4"
    docker rm -f guestpush-trep >/dev/null 2>&1 || true
    wait_for "$label: session over" 60 st_is grace || true
    wait_resume "$label" >/dev/null || fail "$label: loop did not resume"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: report accepted, 4th rate-limited (429), 2nd reporter ok, $n rows logged"
        log "$label ok"
    fi
else
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
fi

# ------------------------------------------------- BN ban path --------------
label="BN-ban"
fails0=$FAILS
# Pinned, so the banned address is one we can push from AGAIN below. Without
# that, the end-to-end re-push would come from a fresh container with a
# different IP and would be admitted - proving nothing.
shared_up || fail "$label: shared pusher would not start"
shared_push tban 60
if wait_for "$label: guest live" 30 st_is live; then
    r=$(curl -s -X POST "$TEL/api/guest/ban")
    echo "$r" | grep -q '"banned"' || fail "$label: ban call did not report an address ($r)"
    wait_for "$label: session ended by ban" 30 st_is free || fail "$label: ban did not end the session"
    shared_stop_push
    ip=$(docker compose exec -T telemetry sh -c 'tail -1 /data/guest_bans.csv | cut -d, -f2' | tr -d '\r')
    # the ban must have landed on the pinned address, or the re-push below is
    # testing a different caller than the one that got banned
    [ "$ip" = "$SHARED_IP" ] || fail "$label: banned addr is '$ip', expected the shared pusher $SHARED_IP"
    # let the operator-kill cooldown lapse so a 403 below can ONLY be the ban
    sleep $((TG_COOLDOWN + 2))
    # Call from INSIDE telemetry, against its own loopback. telemetry's /rtmp/*
    # routes are peer-authenticated (only rtmp-ingest, the gateways, or loopback),
    # so the same request from the host arrives via the bridge gateway and is
    # refused with 404 BEFORE the ban check ever runs - which is what this
    # assertion used to observe. The gate is correct and stays untouched; it is
    # the test that has to call from somewhere the real caller could call from.
    code=$(docker compose exec -T telemetry curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:8090/rtmp/guest/publish?call=publish&name=zzz&addr=$ip" | tr -d '\r')
    [ "$code" = "403" ] || fail "$label: banned addr not refused at on_publish (got $code)"
    # ...and prove that 403 is the BAN and not a blanket refusal: the same call
    # from an unbanned address must be admitted. It claims the slot, so hand it
    # straight back, and leave the section on a free slot as it found it.
    ok=$(docker compose exec -T telemetry curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:8090/rtmp/guest/publish?call=publish&name=zzz&addr=203.0.113.42" | tr -d '\r')
    case "$ok" in
        20*) docker compose exec -T telemetry curl -s -o /dev/null \
                 "http://127.0.0.1:8090/rtmp/guest/done?name=zzz" || true
             wait_for "$label: slot released after control publish" $((TG_GRACE + 20)) st_is free \
                 || fail "$label: control publish left the slot held" ;;
        *)   fail "$label: unbanned addr also refused (got $ok) - the 403 above does not prove the ban" ;;
    esac
    # END TO END over the REAL hop, which nothing covered before: a banned
    # address pushing actual RTMP must be refused by nginx-rtmp. The checks
    # above only prove the arbiter DECIDES 403; this proves the 403 survives
    # `location = /guest/publish` (which has no error_page, unlike the owner
    # locations) and is acted on. It is the only assertion here that exercises
    # what a real banned stranger would hit.
    # Count the arbiter's own refusal lines before and after, rather than
    # grepping a tail: the HTTP probe above ALREADY logged one "rejected
    # (banned)", so a plain grep would match that and pass without the RTMP
    # push having been refused at all. Only a NEW line proves this push was.
    bans0=$(docker compose logs --tail 500 telemetry 2>/dev/null | grep -c "rejected (banned)" || true)
    shared_push tbanx 6; sleep 6
    st_is free || fail "$label: banned address was allowed to publish over RTMP"
    st_is free || fail "$label: banned push claimed the slot (state=$(ep_state))"
    # rc alone is not proof: a container that fails to CREATE also exits nonzero.
    bans1=$(docker compose logs --tail 500 telemetry 2>/dev/null | grep -c "rejected (banned)" || true)
    [ "${bans1:-0}" -gt "${bans0:-0}" ] \
        || fail "$label: no new 'rejected (banned)' from the arbiter - the nonzero rc may be a container-create failure, not a refusal"
    shared_stop_push; shared_down
    # triple-rule edges, tested against the exact enforcement function so no
    # slot/cooldown side effects: a stale active label past its expiry and a
    # redacted-IP row must both be inert
    docker compose exec -T telemetry sh -c 'printf "2026-01-01T00:00:00+00:00,198.51.100.77,DE,2026-01-31T00:00:00+00:00,operator ban,active\n2026-01-01T00:00:00+00:00,-,DE,2099-01-01T00:00:00+00:00,operator ban,active\n" >> /data/guest_bans.csv'
    edges=$(docker compose exec -T telemetry python3 -c "import collect; print(collect._ban_blocks('198.51.100.77'), collect._ban_blocks('198.51.100.88'), collect._ban_blocks('$ip'))" | tr -d '\r')
    [ "$edges" = "False False True" ] || fail "$label: triple rule wrong (got '$edges', want 'False False True')"
    # unban lifts it: checked against the enforcement function, NOT via a
    # real publish, so no slot is claimed and nothing needs backstop cleanup
    curl -s -X POST "$TEL/api/guest/unban?ip=$ip" >/dev/null
    lifted=$(docker compose exec -T telemetry python3 -c "import collect; print(collect._ban_blocks('$ip'))" | tr -d '\r')
    [ "$lifted" = "False" ] || fail "$label: unbanned addr still blocked by the rule (got '$lifted')"
    st=$(docker compose exec -T telemetry sh -c "grep ',$ip,' /data/guest_bans.csv | tail -1 | cut -d, -f6" | tr -d '\r')
    [ "$st" = "unbanned" ] || fail "$label: CSV state not rewritten to unbanned (got '$st')"
    docker compose exec -T telemetry sh -c 'rm -f /data/guest_bans.csv'
    wait_resume "$label" >/dev/null || fail "$label: loop did not resume"
    if [ "$FAILS" -eq "$fails0" ]; then
        row "$label: ban ends session + blocks addr; stale-label and redacted rows inert; unban lifts, CSV self-describes"
        log "$label ok"
    fi
else
    fail "$label: guest publish never accepted"; why_not_live "${last_push:-unknown}"
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
# Answering the HOST is not the post-condition the next case depends on.
# Stopping telemetry pulls its record from docker's embedded DNS, and
# rtmp-ingest's nginx can still be holding that failure when the next case
# publishes (guest-http.conf.in sets `resolver 127.0.0.11 valid=5s` precisely
# so it recovers on its own, and measured 2026-08-10 it does: ~3 s, versus 1 s
# for telemetry to answer the host). Two seconds is a small window, but a case
# that opens with a publish would fail inside it for a reason unrelated to what
# it tests. So wait for the observable from INSIDE ingest, which is the path a
# guest actually traverses.
wait_for "$label: rtmp-ingest can reach telemetry again" 60 \
    sh -c 'docker compose exec -T rtmp-ingest wget -qO- --timeout=2 http://telemetry:8090/api/live 2>/dev/null | grep -q endpoint' \
    || fail "$label: rtmp-ingest still cannot resolve telemetry after restart"
wait_for "$label: slot free after restart" $((TG_GRACE + 30)) st_is free \
    || fail "$label: slot not free after telemetry restart"
is_live || wait_for "$label: loop still live" 30 is_live || fail "$label: loop lost after restart"
if [ "$FAILS" -eq "$fails0" ]; then
    row "$label: push rejected (rc=$rc) with telemetry down; loop kept publishing; clean state after restart"
    log "$label ok"
fi

# ------------------------------------------- IN hostile stream name --------
label="IN-input"
fails0=$FAILS
# The stream name is the ONE value a guest fully controls, and it travels
# further than anything else they supply: into /api/live, which hoast-player
# proxies to the PUBLIC port, into the operator dashboard, and into
# guest_sessions.csv. Every other case in this suite tests a DECISION the box
# makes. This tests DATA the box accepts and then shows to other people.
#
# Written 2026-08-10, after a literal "<any-name>" was pasted into an OBS
# streamid by accident and the allowlist silently stripped it. That was the
# correct behaviour, and nothing in the suite asserted it, which is exactly the
# shape of a gap: a defence nobody would notice losing.
#
# The name goes through shared_push on purpose. push_guest interpolates the name
# into a CONTAINER name, and docker rejects most of these characters, so the
# test would fail on its own harness rather than on the thing under test.
# No space and no ampersand, and that is a finding rather than a compromise:
# probed 2026-08-10, an RTMP publish URL carrying either is rejected by ffmpeg
# before a byte leaves the client, so a name containing them is not something a
# guest can actually send down this path and testing it would only test ffmpeg.
# Everything an RTMP client CAN transmit is here: angle brackets, both quote
# kinds, a semicolon, a backtick, a dollar-substitution and a 100-character run
# against the 32-char cap. The SRT streamid is a protocol field rather than a
# URL and accepts more; test-srt-ingest.sh covers that side.
HOSTILE='<script>alert(1)</script>";DROP--`$(id)`'"'"'x'"$(printf 'A%.0s' $(seq 1 100))"

# WHICH LAYER THIS TESTS, and why it is not an RTMP push. Measured on the box
# 2026-08-10: ffmpeg refuses to publish to rtmp://.../guest/<HOSTILE> at all,
# failing with an I/O error before a byte leaves the client, while the same
# push with a legal name succeeds. That is the same wall the comment above
# records for space and `&` - it just applies to the whole hostile set, which
# the first version of this case did not check. A test that pushes it over RTMP
# therefore asserts something that cannot reach the box on that path, and fails
# forever while reporting a sanitising bug that does not exist. It did exactly
# that on the box before this was corrected.
#
# So drive the layer where such a name CAN arrive: the notify callback, which
# is what nginx-rtmp itself sends and which SRT streamids also reach. The
# request goes from inside rtmp-ingest so it traverses the real route
# (guest-http.conf.in proxies /guest/publish to $arbiter/rtmp$request_uri),
# and every byte of the name is percent-encoded so nothing is reinterpreted on
# the way. test-srt-ingest.sh covers the streamid side.
# Echoes the HTTP status; the whole reply is left in ING_RAW for diagnostics.
#
# The status is taken from "HTTP/<ver> <code>" WHEREVER it sits on the line,
# not from field 2. Field 2 is the code only when the status line begins the
# line, and on the first nightly run in CI it did not: the suite reported
# "hostile name refused outright (HTTP HTTP/1.0)", which is not a status, and
# then threw away the reply that would have said what actually happened. A
# parse that can print a protocol version where a status code belongs cannot
# distinguish a refusal from a misread, which is the one thing this case exists
# to tell apart.
ing_claim() {  # ing_claim <raw-name> <addr>
    local enc; enc=$(printf %s "$1" | od -An -tx1 | tr -d '\n ' | sed 's/\(..\)/%\1/g')
    ING_RAW=$(docker compose exec -T rtmp-ingest wget -qSO- --timeout=5 \
        "http://telemetry:8090/rtmp/guest/publish?app=guest&name=${enc}&addr=$2" 2>&1)
    printf '%s\n' "$ING_RAW" | awk '
        match($0, /HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/) {
            s = substr($0, RSTART, RLENGTH); print substr(s, length(s) - 2); exit }'
}
wait_for "$label: slot free before the hostile claim" 90 st_is free \
    || fail "$label: slot not free, a refusal here would be ambiguous"
# Snapshot the CSV length BEFORE the claim, so assertion 4 below can tell this
# session's row from every earlier one.
csv0=$(docker compose exec -T telemetry sh -c \
    'wc -l < /data/guest_sessions.csv 2>/dev/null || echo 0' 2>/dev/null | tr -d '\r ')
csv0=${csv0:-0}
got=          # so a refused claim reports below instead of tripping `set -u`
st=$(ing_claim "$HOSTILE" 203.0.113.99)
if [ "$st" = "201" ]; then
    got=$(ep_name)
    log "$label: name as published had $(printf '%s' "$HOSTILE" | wc -c | tr -d ' ') chars; arbiter reports '$got'"
    # 1. allowlist held: nothing outside [A-Za-z0-9_-] survived anywhere it is shown
    case "$got" in
        *[!A-Za-z0-9_-]*) fail "$label: /api/live name carries characters outside the allowlist: '$got'" ;;
    esac
    # 2. length cap held, so a name cannot flood a log line, a CSV column or a UI
    [ "${#got}" -le 32 ] || fail "$label: /api/live name is ${#got} chars, cap is 32"
    # 3. and it is not empty, because an empty name would make sessions
    #    indistinguishable in the CSV and the dashboard
    [ -n "$got" ] || fail "$label: name sanitised away to nothing (telemetry should fall back to 'guest')"
else
    fail "$label: hostile name refused outright (HTTP ${st:-no status parsed}); it must be sanitised and admitted"
    # Without this the next occurrence is as undiagnosable as the first was.
    log "$label: the arbiter's reply in full:"
    printf '%s\n' "$ING_RAW" | sed 's/^/      | /'
fi
# End the session the same way nginx-rtmp would, so the slot is not left held.
ing_done() {
    local enc; enc=$(printf %s "$1" | od -An -tx1 | tr -d '\n ' | sed 's/\(..\)/%\1/g')
    docker compose exec -T rtmp-ingest wget -qO- --timeout=5 \
        "http://telemetry:8090/rtmp/guest/done?app=guest&name=${enc}&addr=$2" >/dev/null 2>&1 || true
}
ing_done "${got:-$HOSTILE}" 203.0.113.99

# 4. the persisted row must be clean too: /api/live is rendered with
#    textContent, but the CSV is read by whatever anyone points at it later.
#
# This read used to be `tail -1` taken as soon as the slot left live, and it
# was checking the WRONG ROW. The row is only appended when the session
# actually ends - reason "grace expired" - which is GUEST_GRACE_S after the
# publish stops, so at that moment the last line still belongs to the previous
# case. Both the 2026-08-11 nightly and a box run reported `CSV row records
# 'ra'`, i.e. this assertion passed against a name from a different test while
# appearing to vouch for the hostile one.
#
# Two things fix it. Wait for the row instead of sampling, and identify it by
# POSITION rather than by name: `tail -n +N` from the pre-case line count, so
# only rows this case produced are considered. Name alone is not enough - the
# CSV already holds several rows with the same sanitised name from earlier
# runs, which is exactly the collision that would let a stale row satisfy this.
st_not_live() { [ "$(ep_state)" != "live" ]; }
wait_for "$label: slot leaves live" 60 st_not_live || true

csv_rows() { docker compose exec -T telemetry sh -c \
    'wc -l < /data/guest_sessions.csv 2>/dev/null || echo 0' 2>/dev/null | tr -d '\r '; }
new_row() { [ "$(csv_rows)" -gt "${csv0:-0}" ]; }

# The append lands one grace window after the publish ends, so this has to
# outlast TG_GRACE with room for the collect cycle that notices.
if wait_for "$label: session recorded in guest_sessions.csv" $((TG_GRACE + 45)) new_row; then
    csv_line=$(docker compose exec -T telemetry sh -c \
        "tail -n +$((csv0 + 1)) /data/guest_sessions.csv 2>/dev/null" 2>/dev/null | head -1)
    csv_name=$(printf '%s' "$csv_line" | cut -d, -f2)
    case "$csv_name" in
        *[!A-Za-z0-9_-]*) fail "$label: guest_sessions.csv name carries characters outside the allowlist: '$csv_name'" ;;
    esac
    [ "${#csv_name}" -le 32 ] || fail "$label: CSV name is ${#csv_name} chars, cap is 32"
    # and it must be THIS session's row, not one that merely looks clean
    [ "$csv_name" = "${got:-}" ] \
        || fail "$label: CSV row is '$csv_name', expected this session's '${got:-<claim was refused, so there is no expected name>}'"
    log "$label: CSV row records '$csv_name' (reason: $(printf '%s' "$csv_line" | cut -d, -f6))"
else
    fail "$label: session never reached guest_sessions.csv; the persisted-row assertion cannot be made"
fi
if [ "$FAILS" -eq "$fails0" ]; then
    row "$label: hostile stream name sanitised to '$got' - allowlist and 32-char cap held at /api/live and in the CSV"
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
