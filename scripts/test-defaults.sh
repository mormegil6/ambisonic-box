#!/usr/bin/env bash
# Does a stack with NO .env overrides behave the way the README promises?
#
# WHY THIS EXISTS. Every other suite in this repo sets GUEST_ENABLED=1, and so
# does every CI job, because they are all there to exercise the guest endpoint.
# The reference deployment also runs it enabled. So the DEFAULT - guests off,
# which is the security posture every clone inherits - had never been executed
# by anything, anywhere, while README.md states as fact that "off means the
# guest application does not exist".
#
# That is the structural consequence of having one long-running deployment: the
# configuration a stranger downloads is the least exercised path in the project.
# It is how the SRT suite spent weeks asserting a route it was not running, and
# it is why the republish route - the default - turned out to carry an
# unasserted URL-injection surface.
#
# Runs against a stack brought up with the defaults. Cheap: no guest cycles, no
# media, just the assertions that the off-branch is genuinely off.
#
# These assertions need no mutation entry to prove they can fail, because the
# two real configurations are each other's negative control: the reference box
# runs guests ON and VOD ON, where every check below inverts - /vod/ answers
# 200, /vod-dash/ 403, the nav pill is present and the guest application exists.
# Measured on the box 2026-08-11.
#
# Usage: ./scripts/test-defaults.sh
# Exit: 0 the defaults hold, 1 an assertion failed, 2 precondition.
set -uo pipefail
cd "$(dirname "$0")/.."

PROJECT="${COMPOSE_PROJECT_NAME:-ambi-box}"
TEL=http://127.0.0.1:8090
FAILS=0
ok()   { printf '  PASS  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }

docker compose ps >/dev/null 2>&1 || { echo "compose stack not reachable" >&2; exit 2; }
docker compose ps --format '{{.Service}} {{.State}}' | grep -q "rtmp-ingest running" \
    || { echo "rtmp-ingest not running (docker compose up -d)" >&2; exit 2; }

# The assertions below are meaningless if the stack under test has guests ON,
# and that mistake would LOOK like a pass on the wrong thing. Refuse instead.
eff=$(docker inspect "${PROJECT}-rtmp-ingest-1" \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep -m1 '^GUEST_ENABLED=' | cut -d= -f2)
if [ "${eff:-0}" = "1" ]; then
    echo "this stack runs GUEST_ENABLED=1; these assertions only mean something on the default" >&2
    echo "bring the stack up without that override and re-run" >&2
    exit 2
fi
echo "[1/5] stack is running the default (GUEST_ENABLED=${eff:-unset})"

# 1. The claim in README.md's configuration table, in the rendered config that
#    nginx actually loads - not the template, and not the file on disk.
echo "[2/5] the guest application does not exist in the ingest config"
if docker compose exec -T rtmp-ingest sh -c 'cat /run/nginx/nginx.conf 2>/dev/null' 2>/dev/null \
        | grep -qE '^\s*application\s+guest\s*\{'; then
    bad "a 'guest' application IS declared in the running nginx config"
else
    ok "no guest application in the config nginx loaded"
fi

# 2. And it is refused in practice, not merely absent from a file. An RTMP
#    publish to /guest must not be accepted.
echo "[3/5] a guest publish is refused"
if docker compose run --rm --no-deps -T --entrypoint ffmpeg loop-source \
        -hide_banner -loglevel error -f lavfi -i "sine=d=1" -c:a aac -t 1 \
        -f flv "rtmp://rtmp-ingest:1935/guest/probe" >/dev/null 2>&1; then
    bad "an unauthenticated guest publish SUCCEEDED with guests disabled"
else
    ok "guest publish refused"
fi

# 3. Nothing about guests leaks into what the box reports. The private page and
#    the curated public one are separate surfaces; check the one that is meant
#    to be publishable.
echo "[4/5] the status surfaces carry no guest trace"
live=$(curl -s --max-time 5 "$TEL/api/live" 2>/dev/null)
if [ -z "$live" ]; then
    bad "telemetry did not answer; cannot check the status surface"
else
    st=$(printf '%s' "$live" | python3 -c 'import json,sys
try:
    e = json.load(sys.stdin).get("endpoint") or {}
    print(e.get("state", "MISSING"))
except Exception:
    print("UNPARSEABLE")')
    case "$st" in
        off|MISSING) ok "endpoint reports '$st' (not advertised)" ;;
        *)           bad "endpoint state is '$st' with guests disabled; it should be off/absent" ;;
    esac
fi

# 4. VOD is the other opt-in feature, off by default, and nothing in this repo
#    referenced VOD_ENABLED at all before 2026-08-11 - no script, no workflow,
#    on either branch. The off-branch matters more than it looks: the 404s are
#    explicit STUBS, because without them /vod-dash/ falls through to
#    `location /` and serves the mounted tree with default MIME types, no
#    Expose-Headers and no Cache-Control (see 15-vod-enabled.sh). So "absent"
#    and "404" are different outcomes here, and only one of them is safe.
echo "[5/5] VOD is off and leaves no route behind"
PLAYER=http://127.0.0.1:8080
if ! curl -sf --max-time 5 "$PLAYER/" >/dev/null 2>&1; then
    bad "hoast-player did not answer on 8080; cannot check the VOD routes"
else
    for path in /vod/ /vod-dash/ ; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PLAYER$path" 2>/dev/null)
        if [ "$code" = "404" ]; then
            ok "$path returns 404"
        else
            bad "$path returns $code, expected 404 (a fall-through would serve the mounted tree unguarded)"
        fi
    done
    # the nav pill is stripped from the served page, so the feature leaves no
    # visible trace either
    if curl -s --max-time 5 "$PLAYER/" 2>/dev/null | grep -q 'href="/vod/"'; then
        bad "the served page still advertises a VOD link"
    else
        ok "no VOD link on the served page"
    fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: the shipped default is what the README says it is"
    exit 0
fi
echo "FAIL: $FAILS assertion(s) - a clone does NOT get the documented posture"
exit 1
