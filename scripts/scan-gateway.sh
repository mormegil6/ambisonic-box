#!/bin/sh
# Vulnerability scan for srt-gateway, split by what is actually REACHABLE.
#
# Why this is not just `trivy image`: the gateway needs GStreamer's `srtsrc`,
# which Debian ships only inside gstreamer1.0-plugins-bad. That package depends
# on an ML inference runtime (ONNX), a printing library (CUPS), image codecs
# (OpenEXR, TIFF, libde265) and an audio server (PipeWire), none of which an SRT
# terminator touches. They are installed, so a plain scan counts their CVEs, and
# the total reads far worse than the exposure is.
#
# So this prints two lists. The second one is the one to read.
#
# Usage:  ./scripts/scan-gateway.sh            (scans the local image)
#         ./scripts/scan-gateway.sh ssh box    (scans on a remote docker host)
set -eu

IMAGE="${GATEWAY_IMAGE:-ambi-box-srt-gateway:local}"
CACHE="${TRIVY_CACHE:-\$HOME/.cache/trivy}"   # expanded on the TARGET host, not here
CACHE_MAX_MB="${TRIVY_CACHE_MAX_MB:-2000}"    # see the note below before lowering this
CONTAINER="${GATEWAY_CONTAINER:-ambi-box-srt-gateway-1}"
RUN="${*:-}"          # optional prefix, e.g. "ssh box"

d() { if [ -n "$RUN" ]; then $RUN "$@"; else sh -c "$*"; fi; }

# BOUND THE CACHE, and own it. Two problems, one line each.
#
# Ownership: docker CREATES a missing bind-mount source as root, and the trivy
# container then runs as root inside it, so the whole cache ends up root:root
# and the box user cannot clean it - which is how it silently reached 1.2 GB.
# Creating the directory first, and running the container as the invoking user,
# keeps every byte prunable without sudo. NOTE the two must change TOGETHER:
# a non-root uid has no passwd entry in this image, so \$HOME resolves to / and
# trivy tries to create /.cache, which fails with 'permission denied'. Hence the
# mount moves to /tmp/trivycache and TRIVY_CACHE_DIR points at it.
#
# Size: NOT because this grows without bound - it does not. Measured 2026-08-08:
# db/ is 1.2 GB and fanal/ (per-scan results) is 1.3 MB, and trivy replaces the
# DB in place rather than accumulating versions. 1.2 GB is simply what the
# vulnerability database weighs. The ceiling exists to catch the case where that
# stops being true - a half-written update, a second DB copy - on a box whose
# disk is finite. Keep it comfortably ABOVE one DB: set it to 800 and the guard
# fires on every single run, wiping the cache it exists to protect.
d "mkdir -p $CACHE"
# Run as the invoking UID but with docker's GID, not the user's. --user alone
# drops the supplementary groups, so the container loses access to a socket that
# is root:docker 0660 and every scan dies on "permission denied ... docker.sock".
# Falls back to the user's own gid where there is no docker group (Docker Desktop).
DGID=$(d "getent group docker 2>/dev/null | cut -d: -f3" || true)
[ -n "$DGID" ] || DGID=$(d "id -g")
CACHE_MB=$(d "du -sm $CACHE 2>/dev/null | cut -f1" || echo 0)
case "$CACHE_MB" in ''|*[!0-9]*) CACHE_MB=0 ;; esac
if [ "$CACHE_MB" -gt "$CACHE_MAX_MB" ]; then
    echo "== trivy cache ${CACHE_MB} MB > ${CACHE_MAX_MB} MB, clearing it (the DB re-downloads) =="
    d "rm -rf $CACHE" && d "mkdir -p $CACHE"
fi

echo "== scanning $IMAGE for HIGH/CRITICAL =="
REPORT=$(d "docker run --rm \
    --user \$(id -u):'"$DGID"' \
    -e TRIVY_CACHE_DIR=/tmp/trivycache \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $CACHE:/tmp/trivycache \
    aquasec/trivy:latest image --scanners vuln --severity HIGH,CRITICAL \
    --quiet '$IMAGE'" 2>/dev/null) || {
        echo "scan failed (is docker reachable, and the image built?)" >&2; exit 1; }
echo "   trivy cache after: $(d "du -sh $CACHE 2>/dev/null | cut -f1")"

echo "$REPORT" | grep -m1 '^Total:' || true

# Which shared libraries does the RUNNING gateway actually map? A CVE in a
# package whose code is never loaded has no path to execution here. PID 1 is
# docker-init (compose sets init: true), so find the python process instead.
echo
echo "== cross-referencing against libraries the running gateway actually loads =="
PID=$(d "docker exec $CONTAINER sh -c 'for p in /proc/[0-9]*; do [ \"\$(cat \$p/comm 2>/dev/null)\" = python3 ] && basename \$p && break; done'" 2>/dev/null || true)
if [ -z "$PID" ]; then
    echo "container not running: cannot tell loaded from merely installed."
    echo "start it and re-run, or treat every finding above as unclassified."
    exit 0
fi

LOADED=$(d "docker exec $CONTAINER sh -c 'grep -oE \"/usr/lib/[^ ]*\\.so[^ ]*\" /proc/$PID/maps | xargs -n1 basename | sed \"s/\\.so.*//\" | sort -u'" 2>/dev/null || true)
echo "  gateway maps $(printf '%s\n' "$LOADED" | grep -c . ) distinct libraries"
echo
echo "  REACHABLE findings (package matches a loaded library) - these matter:"
HITS=0
# Match on the ALPHABETIC stem only. A mapped file is libglib-2.0.so.0 while
# its package is libglib2.0-0t64, so digits and punctuation differ on the two
# sides and cannot be compared directly; the stem ("glib") is what is stable.
# Plain string search, not a regex, because names like libstdc++ carry
# characters a regex would read as operators.
for lib in $LOADED; do
    stem=$(printf '%s' "$lib" | sed 's/^lib//' | tr -cd 'a-z')
    [ ${#stem} -lt 3 ] && continue          # too short to identify a package
    line=$(printf '%s\n' "$REPORT" | grep -iF "$stem" | grep -E 'CVE-|GHSA-' | head -3 || true)
    if [ -n "$line" ]; then
        printf '%s\n' "$line" | cut -c1-118 | sed 's/^/    /'
        HITS=1
    fi
done
[ "$HITS" = 0 ] && echo "    (none: every finding is in a package this process never loads)"

echo
echo "  libsrt specifically - the ONE pre-auth parser, so watch this line:"
printf '%s\n' "$REPORT" | grep -iF 'libsrt' | sed 's/^/    /' || true
printf '%s\n' "$REPORT" | grep -qiF 'libsrt' || echo "    clean"
