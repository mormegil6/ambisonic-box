#!/usr/bin/env bash
# Checks that an image can be pulled anonymously, as a first-time user pulls
# it, for both linux/amd64 and linux/arm64:
#
#   .github/scripts/anonymous-pull.sh ghcr.io/mormegil6/ambisonic-box/earshot v1.4.0
#
# Exits 1 with an explanation otherwise. ghcr-publish runs it before it moves
# `latest` and again before PIN_TAG, so a package that GHCR created private
# stops the release there instead of breaking every fresh install.
set -uo pipefail

image=${1:?usage: anonymous-pull.sh <ghcr.io/owner/name> <tag>}
tag=${2:?usage: anonymous-pull.sh <ghcr.io/owner/name> <tag>}
repo=${image#ghcr.io/}

if ! token=$(curl -sfS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -er .token); then
    echo "::error::GHCR refused an anonymous pull token for $repo: the package is private or missing (its Package settings, Change visibility)"
    exit 1
fi
if ! index=$(curl -sfS -H "Authorization: Bearer $token" \
                  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
                  "https://ghcr.io/v2/$repo/manifests/$tag"); then
    echo "::error::$repo:$tag cannot be pulled anonymously"
    exit 1
fi
got=$(jq -r '[.manifests[]? | select(.platform.os == "linux") | .platform.architecture] | sort | join(" ")' <<< "$index")
if [ "$got" != "amd64 arm64" ]; then
    echo "::error::$repo:$tag carries [$got] for an anonymous pull, not amd64 and arm64"
    exit 1
fi
echo "  $repo:$tag: amd64 and arm64, anonymously"
