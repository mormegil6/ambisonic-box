#!/usr/bin/env bash
# Prints the commit a tag names on GitHub, peeling an annotated tag:
#
#   .github/scripts/tag-commit.sh v1.4.0
#
# ghcr-publish compares it with the commit its run builds, so a run whose tag
# has since been moved to another commit (v1.3.4 was re-tagged twice) stops
# instead of publishing the old commit under the new tag's name.
#
# Needs GITHUB_REPOSITORY, which a GitHub runner sets, and GH_TOKEN, which the
# calling step has to set (ghcr-publish passes github.token).
set -euo pipefail

tag=${1:?usage: tag-commit.sh <tag>}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}

obj=$(gh api "repos/$repo/git/ref/tags/$tag" --jq '.object | "\(.type) \(.sha)"')
read -r type sha <<< "$obj"
# an annotated tag points at a tag object, which in turn names the commit
while [ "$type" = tag ]; do
    obj=$(gh api "repos/$repo/git/tags/$sha" --jq '.object | "\(.type) \(.sha)"')
    read -r type sha <<< "$obj"
done
[ "$type" = commit ] || { echo "$tag names a $type, not a commit" >&2; exit 1; }
echo "$sha"
