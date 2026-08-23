#!/bin/sh
# Set the version this source tree claims to be, in the two places that claim it.
#
# WHY THIS EXISTS. A running stack reports its version on /api/live, which the
# dashboard and the player show and which the bug report form asks for. That
# number comes from telemetry/VERSION, baked into the image at build time. There
# is deliberately no deploy-time plumbing: an AMBI_VERSION environment override
# exists for `git describe` precision, but it froze stale into a container
# within a day of being introduced, which is the whole argument for the file
# being primary. The file is only honest if something keeps it in step, and
# "remember to bump it" is not something.
#
# So: this script bumps telemetry/VERSION and CITATION.cff together, and the
# hygiene workflow refuses a push where they disagree or where a tag does not
# match what the files say.
#
# Usage:
#   ./scripts/set-version.sh 1.0.0        cutting a release
#   ./scripts/set-version.sh 1.0.1-dev    the bump straight after one
#
# It edits files and nothing else. It does not commit, tag or push; those stay
# deliberate acts.
set -eu

cd "$(dirname "$0")/.."

VERSION_FILE="telemetry/VERSION"
CFF_FILE="CITATION.cff"

usage() {
    cat >&2 <<EOF
usage: $0 <version>

  <version>   X.Y.Z for a release, or X.Y.Z-<marker> for anything unreleased.
              A -dev marker means "past the last release, not itself released";
              the hygiene gate refuses to see one on a tag.

examples:
  $0 1.0.0        cut 1.0.0: sets date-released to today
  $0 1.0.1-dev    the commit after: leaves date-released on the last release

current: $(cat "$VERSION_FILE" 2>/dev/null || echo "unreadable")
EOF
    exit 2
}

[ $# -eq 1 ] || usage
NEW="$1"

# Semver-ish. Strict about the numeric core because the CI gate parses it, and
# permissive about the marker because -dev, -rc1 and -beta.2 are all reasonable.
echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || {
    echo "refusing: '$NEW' is not X.Y.Z or X.Y.Z-marker" >&2
    exit 1
}

[ -f "$VERSION_FILE" ] || { echo "missing $VERSION_FILE" >&2; exit 1; }
[ -f "$CFF_FILE" ]     || { echo "missing $CFF_FILE" >&2; exit 1; }

OLD=$(tr -d ' \t\r\n' < "$VERSION_FILE")

# A release version gets today's date; a marked one does not, because nothing
# was released today. Between releases CITATION.cff therefore reads as "the
# development tree after the <date-released> release", which is what it is.
case "$NEW" in
    *-*) RELEASE=0 ;;
    *)   RELEASE=1 ;;
esac

printf '%s\n' "$NEW" > "$VERSION_FILE"

# The scratch file lands in the repository root, so clean it up rather than
# leaving an untracked CITATION.cff.tmp behind if a sed fails under set -e.
trap 'rm -f "$CFF_FILE.tmp"' EXIT INT TERM

# Anchored at column 0 on purpose: preferred-citation's nested keys are indented
# and must not be touched. No sed -i, which takes an argument on macOS and none
# on GNU; this script runs on both.
if [ "$RELEASE" -eq 1 ]; then
    TODAY=$(date -u +%Y-%m-%d)
    CFF_NOTE="version and date-released ($TODAY)"
    sed -e "s|^version: .*|version: \"$NEW\"|" \
        -e "s|^date-released: .*|date-released: \"$TODAY\"|" \
        "$CFF_FILE" > "$CFF_FILE.tmp"
    # PIN_TAG (scripts/setup.sh) is NOT touched here, deliberately. It is the
    # image tag a fresh install pulls, so it must never name a tag with no
    # images - and at this point in a release there are none yet: the tag that
    # triggers the build has not even been pushed. Bumping it here made every
    # release fail its own integration run until the images finished building.
    # The ghcr-publish workflow bumps it once the images exist.
else
    CFF_NOTE="version (date-released left on the last release)"
    sed -e "s|^version: .*|version: \"$NEW\"|" "$CFF_FILE" > "$CFF_FILE.tmp"
fi
mv "$CFF_FILE.tmp" "$CFF_FILE"

grep -q "^version: \"$NEW\"\$" "$CFF_FILE" || {
    echo "failed: $CFF_FILE has no top-level version: line to rewrite" >&2
    exit 1
}

echo "$OLD -> $NEW"
echo "  $VERSION_FILE"
echo "  $CFF_FILE: $CFF_NOTE"
echo

if [ "$RELEASE" -eq 1 ]; then
    cat <<EOF
next, to cut it:
  git commit -am "Release $NEW"
  git tag -a "v$NEW" -m "v$NEW"
  git push origin main "v$NEW"
  gh release create "v$NEW" --verify-tag --notes-from-tag   # this is what mirrors it to GitLab

then bump straight past it, so main never claims to BE a release it has moved on from:
  ./scripts/set-version.sh <next>-dev

scripts/setup.sh PIN_TAG is not yours to touch: ghcr-publish bumps it once the
images for this tag exist, so a fresh install never pulls a tag with no images.
EOF
else
    echo "next: git commit -am \"Back to development on $NEW\""
fi
