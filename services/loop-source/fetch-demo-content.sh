#!/bin/sh
# Fetch the VOD reference masters from the PINNED vod-clips GitHub release
# into the content volume. Runs in the loop-source container (busybox sh).
#
# - Pinned tag, never "latest"; pinned SHA-256 per asset, checked IN THIS REPO
#   rather than fetched from the release, so a silently replaced asset cannot
#   ride in: a mismatch is a loud failure, never "use whatever arrived".
# - Cache: a file that already exists is never re-fetched.
# - Fail-soft per file: log clearly and continue; the demo loop never depends
#   on this fetch (it is synthesised locally), so network trouble costs only
#   the /vod/ masters.
# - Progress: a poller logs downloaded size every 5 s; 185 MB on a first run
#   must not look like a hang.
#
# DEMO_BASE_URL overrides the release base URL (used by the test harness with
# a local fixture server). When the repo is private, anonymous fetches return
# 404: expected, handled by the fail-soft path (a 404 lands in the fail-soft path
# check).
set -u

BASE="${DEMO_BASE_URL:-https://github.com/mormegil6/ambisonic-box/releases/download/vod-clips}"
DEST="${DEMO_VOD_DIR:-/content/vod/masters}"

# asset<TAB>sha256, one per line. Update BOTH the release asset and this list
# together (verify size + SHA-256 by re-downloading after upload).
ASSETS="colortones_8k360_16ch.webm bf9bb0b70e9ab0851e31847ee92cce2b9f278ed6091de2c2bbe5c62619720057
directions_8k360_16ch.webm f1fbf5ae47fae066c79f4fde6136ce00530958f57b937b185fb0f74d8076cc28"

log() { echo "[demo-fetch] $*"; }

mkdir -p "$DEST" 2>/dev/null || { log "cannot create $DEST; skipping fetch"; exit 0; }

echo "$ASSETS" | while read -r name sha; do
    [ -n "$name" ] || continue
    out="$DEST/$name"
    tmp="$out.fetch.tmp"
    if [ -f "$out" ]; then
        log "$name: present, skipping (cache hit)"
        continue
    fi
    log "$name: fetching from $BASE"
    rm -f "$tmp"
    # progress poller: report growth every 5 s until the tmp file goes away
    (
        while [ -e "$tmp.marker" ]; do
            if [ -f "$tmp" ]; then
                sz=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
                log "$name: downloaded $((sz / 1048576)) MiB..."
            fi
            sleep 5
        done
    ) &
    poller=$!
    : > "$tmp.marker"
    if curl -fsSL --connect-timeout 10 --retry 2 -o "$tmp" "$BASE/$name"; then
        got=$(sha256sum "$tmp" | cut -d' ' -f1)
        if [ "$got" = "$sha" ]; then
            mv "$tmp" "$out"
            log "$name: OK ($(stat -c %s "$out" 2>/dev/null || echo '?') bytes, sha256 verified)"
        else
            log "$name: SHA-256 MISMATCH (expected $sha, got $got); discarding download"
            rm -f "$tmp"
        fi
    else
        log "$name: fetch FAILED (network/404); the /vod/ page will lack this master until it succeeds"
        rm -f "$tmp"
    fi
    rm -f "$tmp.marker"
    kill "$poller" 2>/dev/null
done
log "done"
