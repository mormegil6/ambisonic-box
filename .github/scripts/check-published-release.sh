#!/usr/bin/env bash
# Checks that the release a fresh install gets is whole and current:
#
#   .github/scripts/check-published-release.sh
#
#  - PIN_TAG (scripts/setup.sh) is the newest release that has been published.
#    An old copy of ghcr-publish, such as a re-run of an older release's run,
#    moves PIN_TAG and `latest` back without failing, and nothing else would
#    notice.
#  - `latest` is the same images as PIN_TAG for every published image, since
#    both should name that release.
#  - every image docker-compose.pull.yml names exists at PIN_TAG for amd64 and
#    arm64.
#
# Only a development tree (telemetry/VERSION ending in -dev) is checked. A
# release or pre-release tree is the one being published: its PIN_TAG is the
# previous release by construction, the registry changes under it while the
# release runs, and it may name an image that it is about to publish for the
# first time. Development pushes and the nightly run keep the coverage.
#
# integration.yml runs it in the defaults job: on pushes to main that change
# more than docs, on pull requests, on release tags, and every night. Run from
# the repository root; needs GITHUB_REPOSITORY and GH_TOKEN (for
# newest-release.sh), and the two publish credentials in .env or the
# environment, since compose interpolates the files.
set -euo pipefail
here=$(dirname "$0")
fail=0

version=$(tr -d ' \t\r\n' < telemetry/VERSION)
case "$version" in
    *-dev) ;;
    *) echo "  $version is a release tree, published by its own run: nothing to check here"; exit 0 ;;
esac

pin=$(sed -n 's|^PIN_TAG="\(v.*\)"|\1|p' scripts/setup.sh)
[ -n "$pin" ] || { echo "::error::no PIN_TAG in scripts/setup.sh"; exit 1; }
images=$(docker compose -f docker-compose.yml -f docker-compose.pull.yml config --format json \
           | jq -r '[.services[].image // empty | select(startswith("ghcr.io/")) | sub(":[^/:]*$"; "")] | unique | .[]')
[ -n "$images" ] || { echo "::error::docker-compose.pull.yml names no ghcr.io image"; exit 1; }

# the digest a tag names, asked anonymously, as a first-time user pulls
digest() {
    local r=${1#ghcr.io/} token
    token=$(curl -sfS "https://ghcr.io/token?scope=repository:$r:pull" | jq -er .token) || return 1
    curl -sfS -I -H "Authorization: Bearer $token" \
         -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
         "https://ghcr.io/v2/$r/manifests/$2" | tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }'
}

# every image complete at PIN_TAG, and `latest` the same images
reference=''
for image in $images; do
    "$here/anonymous-pull.sh" "$image" "$pin" || { fail=1; continue; }
    [ -n "$reference" ] || reference=$image
    p=$(digest "$image" "$pin" || true)
    l=$(digest "$image" latest || true)
    if [ -z "$p" ] || [ "$p" != "$l" ]; then
        echo "::error::$image: latest is ${l:-missing} but $pin is ${p:-missing}; they should be the same release (if a release is publishing right now, re-run this after its pin commit lands)"
        fail=1
    fi
done

# PIN_TAG the newest release anyone can install, asked of an image it has
if [ -n "$reference" ]; then
    rc=0; "$here/newest-release.sh" --published-as "$reference" "$pin" || rc=$?
    case "$rc" in
        0) ;;
        1) echo "::error::PIN_TAG $pin is not the newest published release (if a release is publishing right now, re-run this after its pin commit lands). If the newest release's ghcr-publish run has a tag job and is under 30 days old, re-run that job and its pin follows; otherwise retag latest from that release with docker buildx imagetools create and set PIN_TAG in scripts/setup.sh by hand"
           fail=1 ;;
        *) echo "::error::could not tell which release is the newest"; exit 1 ;;
    esac
fi

exit "$fail"
