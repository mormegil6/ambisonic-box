#!/usr/bin/env bash
# Prints the commit an already-published image was built from, or nothing if
# the tag does not exist:
#
#   .github/scripts/published-revision.sh ghcr.io/mormegil6/ambisonic-box/earshot:v1.4.0
#
# The commit is the org.opencontainers.image.revision label of every platform
# under the tag; if they disagree, all of them are printed, space-separated.
# Exits 2 when the registry cannot be asked, so a caller never mistakes an
# outage for "not published". ghcr-publish uses this to refuse a release tag
# that already names images from another commit, because a published release
# is never re-tagged.
set -euo pipefail

ref=${1:?usage: published-revision.sh <image>:<tag>}

if ! out=$(docker buildx imagetools inspect "$ref" --format '{{json .Image}}' 2>&1); then
    # A missing tag is "not found". A package that does not exist yet, which is
    # every image's state before its first release, answers 403 like a private
    # one; either way nothing is published under the tag there.
    if grep -qiE 'not found|403 Forbidden|denied' <<< "$out"; then
        exit 0
    fi
    echo "could not inspect $ref: $out" >&2
    exit 2
fi
# one platform gives the image config itself, several give a map of them
jq -r 'if has("config") then [.] else [.[]] end
       | [.[].config.Labels["org.opencontainers.image.revision"] // "unlabelled"]
       | unique | join(" ")' <<< "$out"
