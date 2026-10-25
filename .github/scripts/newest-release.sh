#!/usr/bin/env bash
# Is <tag> the newest release of this project? Exit 0 if it is, 1 if it is not,
# 2 if GitHub or the registry could not be asked:
#
#   .github/scripts/newest-release.sh v1.4.0
#   .github/scripts/newest-release.sh --published-as ghcr.io/mormegil6/ambisonic-box/earshot v1.3.9
#
# ghcr-publish uses the answer to decide whether a release moves `latest` and
# scripts/setup.sh's PIN_TAG, the two things a newcomer gets. Only a plain
# vX.Y.Z can be the newest; a pre-release such as v1.4.0-rc1 never is. A tag
# that sorts above <tag> counts against it only if it is a release of this
# project, meaning telemetry/VERSION at that tag names the same version.
# Anything else above it, another repository's tags pushed here by mistake or a
# mistyped one, is reported and skipped: counted, it would quietly stop every
# later release from becoming `latest`.
#
# With --published-as <image>, a higher release counts only once <image> has
# been published under its tag, so "newest" means the newest release anyone
# can install. integration.yml checks PIN_TAG that way every night, which an
# unfinished release in progress must not fail.
#
# Needs GITHUB_REPOSITORY, which a GitHub runner sets, and GH_TOKEN, which the
# calling step has to set (ghcr-publish passes github.token).
set -euo pipefail

published_as=''
if [ "${1:-}" = --published-as ]; then
    published_as=${2:?usage: newest-release.sh [--published-as <image>] <tag>}
    shift 2
fi
tag=${1:?usage: newest-release.sh [--published-as <image>] <tag>}
plain='^v[0-9]+\.[0-9]+\.[0-9]+$'
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}

if ! [[ $tag =~ $plain ]]; then
    echo "$tag is not a plain vX.Y.Z release, so it is never the newest"
    exit 1
fi

# Is $1 published as $published_as:$1? Anonymous, as a first-time user pulls,
# so an image GHCR refuses to name to anyone (a 403 on the token) is not
# published either.
published() {
    local r=${published_as#ghcr.io/} token code
    code=$(curl -s -o /dev/null -w '%{http_code}' "https://ghcr.io/token?scope=repository:$r:pull")
    case "$code" in
        200) ;;
        403) return 1 ;;
        *) echo "could not get a pull token for $published_as (HTTP $code)" >&2; return 2 ;;
    esac
    token=$(curl -sfS "https://ghcr.io/token?scope=repository:$r:pull" | jq -er .token) || return 2
    code=$(curl -s -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $token" \
                -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
                "https://ghcr.io/v2/$r/manifests/$1")
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *) echo "could not ask the registry about $published_as:$1 (HTTP $code)" >&2; return 2 ;;
    esac
}

refs=$(gh api --paginate "repos/$repo/git/matching-refs/tags/v" --jq '.[].ref') || exit 2
above=$( { printf '%s\n' "$refs" | sed 's|^refs/tags/||' | grep -E "$plain" || true; echo "$tag"; } \
           | sort -V -u | awk -v t="$tag" 'seen; $0 == t { seen = 1 }')

for t in $above; do
    if out=$(gh api -H 'Accept: application/vnd.github.raw' \
               "repos/$repo/contents/telemetry/VERSION?ref=refs/tags/$t" 2>&1); then
        v=$(printf '%s' "$out" | tr -d ' \t\r\n')
    elif printf '%s' "$out" | grep -q 'HTTP 404'; then
        v='(no telemetry/VERSION)'
    else
        echo "could not read telemetry/VERSION at $t: $out" >&2
        exit 2
    fi
    if [ "$v" != "${t#v}" ]; then
        echo "::warning::tag $t sorts above $tag but is not a release of this project (telemetry/VERSION there: $v), so it is ignored; if it does not belong here, delete it on GitHub and on GitLab"
        continue
    fi
    if [ -n "$published_as" ]; then
        rc=0; published "$t" || rc=$?
        if [ "$rc" = 1 ]; then
            echo "  $t is a newer release but $published_as:$t is not published (yet), so it does not count"
            continue
        fi
        [ "$rc" = 0 ] || exit 2
    fi
    echo "$t is a newer release of this project, so $tag is not the newest"
    exit 1
done

echo "$tag is the newest release${published_as:+ that has been published}"
