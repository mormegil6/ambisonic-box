#!/usr/bin/env bash
# Prints docker/bake-action `set` lines that give every bake target in
# docker-compose.yml its own GitHub Actions cache scope, per architecture:
#
#   .github/scripts/bake-cache-scopes.sh <arch> read         cache-from only
#   .github/scripts/bake-cache-scopes.sh <arch> read-write   cache-from and cache-to
#
# build.yml writes these scopes on both architectures and integration.yml reads
# the amd64 ones. One scope per image is the point: with the single default
# scope, each image's cache export replaced the others', so a run could reuse at
# most one image's cache and rebuilt the rest (6 to 24 minutes a push for
# build.yml on 2026-10-24 and 25). The list comes from bake itself, so an image
# added to docker-compose.yml gets its own scopes automatically.
#
# Every image caches all its build stages (mode=max) except those in MIN below,
# which cache only their final image. shaka is one: its builder stage is about
# 1.8 GB per architecture against a 10 GB repository limit, and the slow step in
# it, the cmake build, is that stage's last, so it re-runs on any change to the
# stage whatever is cached before it. An unchanged shaka still comes back whole.
#
# Run from the repository root. bake interpolates the compose file first, so the
# mandatory variables (RTMP_OWNER_KEY, LOOP_SOURCE_KEY) must be set or in .env.
set -euo pipefail

MIN='["shaka"]'

arch=${1:?usage: bake-cache-scopes.sh <arch> read|read-write}
mode=${2:?usage: bake-cache-scopes.sh <arch> read|read-write}
case "$mode" in
    read|read-write) ;;
    *) echo "mode must be read or read-write, not '$mode'" >&2; exit 2 ;;
esac

docker buildx bake -f docker-compose.yml --print 2>/dev/null \
    | jq -r --arg a "$arch" --arg m "$mode" --argjson min "$MIN" '.target | keys[] as $t
        | "\($t).cache-from=type=gha,scope=build-\($a)-\($t)",
          (if $m == "read-write"
           then "\($t).cache-to=type=gha,mode=\(if ($min | index($t)) then "min" else "max" end),scope=build-\($a)-\($t)"
           else empty end)'
