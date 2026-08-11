#!/usr/bin/env bash
# Do the test suites actually assert anything?
#
# WHY THIS EXISTS. On 2026-08-10 three assertions in this repo were found to be
# passing while checking nothing:
#   - test-guest-endpoint.sh IN-input pushed a hostile name over RTMP, which the
#     client refuses to send, so the case could never go live and never ran;
#   - its CSV assertion read `tail -1` before the row was written and validated
#     a DIFFERENT test's row;
#   - test-srt-ingest.sh's hostile-streamid case grepped a log line that only the
#     accept branch emits, in a position where the caller is always refused, so
#     it matched an earlier step's own line.
# All three were green in CI. More tests would not have found them, because the
# tests WERE the problem. What was missing is the question this script asks:
# break the thing on purpose, and check the suite notices.
#
# Each entry mutates PRODUCT code, never test code - a test that only fails when
# you break the test proves nothing.
#
# SLOW and DISRUPTIVE by nature: every entry is a rebuild plus a full suite run,
# and while it runs the stack is deliberately broken. Nightly or on demand, not
# per push. Never point it at a deployment that is serving anyone.
#
# Usage:
#   ./scripts/verify-tests-can-fail.sh            all entries
#   ./scripts/verify-tests-can-fail.sh play       entries whose id matches
#   LIST=1 ./scripts/verify-tests-can-fail.sh     print the table and exit
# Exit: 0 every mutation was caught, 1 one or more were NOT, 2 precondition.
set -uo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"

# id | file to mutate | python expression rewriting the text | service to rebuild | suite | what the suite must say
#
# The rewrite runs as: text = <expr>, with `t` bound to the original text.
# Keep each mutation MINIMAL and obviously wrong; a subtle one that the suite
# legitimately cannot see teaches nothing.
ENTRIES=(
"play|services/rtmp-ingest/nginx.conf.template|t.replace('            deny play all;\n', '')|rtmp-ingest|./scripts/test-pipeline.sh|UNAUTHENTICATED PLAY SUCCEEDED"
"sanitise|services/srt-gateway/gateway.py|t.replace('    name = re.sub(r\"[^A-Za-z0-9_-]\", \"\", name or \"\")[:32]', '    name = name or \"\"')|srt-gateway|./scripts/test-srt-ingest.sh|sanitiser passed characters outside the allowlist"
)

if [ -n "${LIST:-}" ]; then
    printf '%-10s %-46s %s\n' ID MUTATES SUITE
    for e in "${ENTRIES[@]}"; do
        IFS='|' read -r id file _ _ suite _ <<<"$e"
        printf '%-10s %-46s %s\n' "$id" "$file" "$suite"
    done
    exit 0
fi

command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }
docker compose ps >/dev/null 2>&1 || { echo "compose stack not reachable" >&2; exit 2; }

# A dirty tree makes "restore" ambiguous: this script cannot tell its own
# mutation from an edit in progress, and restoring the wrong one loses work.
if [ -n "$(git status --porcelain -- services/ 2>/dev/null)" ]; then
    echo "services/ has uncommitted changes; commit or stash first so restore is unambiguous" >&2
    exit 2
fi

RESTORE=()
restore_all() {
    for f in "${RESTORE[@]}"; do
        git checkout -- "$f" 2>/dev/null || true
    done
    [ ${#RESTORE[@]} -gt 0 ] && echo "  [restored ${#RESTORE[@]} file(s); rebuilding to match]"
    for s in $(printf '%s\n' "${REBUILT[@]:-}" | sort -u); do
        [ -n "$s" ] && docker compose build "$s" >/dev/null 2>&1 && \
            docker compose up -d --no-deps "$s" >/dev/null 2>&1
    done
    return 0
}
REBUILT=()
trap restore_all EXIT

PASS=0; MISS=0
for e in "${ENTRIES[@]}"; do
    IFS='|' read -r id file expr svc suite expect <<<"$e"
    [ -n "$FILTER" ] && case "$id" in *"$FILTER"*) ;; *) continue ;; esac

    echo "=== $id: mutating $file, expecting $suite to fail ==="
    [ -f "$file" ] || { echo "  SKIP: $file missing"; continue; }

    RESTORE+=("$file"); REBUILT+=("$svc")
    if ! python3 - "$file" "$expr" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); t = p.read_text()
out = eval(sys.argv[2], {"t": t})
if out == t:
    sys.stderr.write("  MUTATION DID NOT APPLY: the target text was not found. "
                     "The product changed and this entry is stale.\n")
    sys.exit(3)
p.write_text(out)
PY
    then
        echo "  FAIL: could not apply the mutation (stale entry) - counted as a miss"
        MISS=$((MISS+1)); git checkout -- "$file" 2>/dev/null || true; continue
    fi

    docker compose build "$svc" >/dev/null 2>&1 \
        && docker compose up -d --no-deps "$svc" >/dev/null 2>&1
    sleep 6

    out=$($suite 2>&1); rc=$?
    git checkout -- "$file" 2>/dev/null || true
    docker compose build "$svc" >/dev/null 2>&1 \
        && docker compose up -d --no-deps "$svc" >/dev/null 2>&1

    if [ "$rc" -eq 0 ]; then
        echo "  *** NOT CAUGHT: $suite passed with the product deliberately broken."
        echo "      The assertion for '$expect' is not doing anything."
        MISS=$((MISS+1))
    elif printf '%s' "$out" | grep -qF "$expect"; then
        echo "  caught, and for the right reason ($expect)"
        PASS=$((PASS+1))
    else
        echo "  *** CAUGHT FOR THE WRONG REASON: the suite failed, but not with"
        echo "      '$expect'. It may be failing on collateral damage rather than"
        echo "      on the assertion this entry is testing. Last lines:"
        printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
        MISS=$((MISS+1))
    fi
    sleep 5
done

echo
echo "================ can-fail report ================"
echo "  assertions proven able to fail: $PASS"
echo "  mutations NOT caught:           $MISS"
[ "$MISS" -eq 0 ] || echo "  A mutation that is not caught means the assertion is decoration."
[ "$MISS" -eq 0 ]
