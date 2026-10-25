#!/usr/bin/env bash
# Waits until a release tag's commit has passed its hygiene, build and
# integration runs; exits 1 as soon as one fails, or when they have not all
# finished by the deadline:
#
#   .github/scripts/wait-for-ci.sh <tag> <commit> [minutes, default 35]
#
# ghcr-publish's tagging job uses it, so a release publishes only a commit
# whose own CI passed. The three workflows run on the tag push itself, which is
# the run this waits for, and every one of them on main for the same commit
# must have passed too. Runs of the commit on any other branch are not counted.
# security is left out on purpose: its scan takes longer than a whole publish
# and fails on upstream CVEs nobody here can fix.
#
# Needs GITHUB_REPOSITORY, which a GitHub runner sets, and GH_TOKEN, which the
# calling step has to set, with actions: read.
set -euo pipefail

tag=${1:?usage: wait-for-ci.sh <tag> <commit> [minutes]}
sha=${2:?usage: wait-for-ci.sh <tag> <commit> [minutes]}
minutes=${3:-35}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
deadline=$(( $(date +%s) + minutes * 60 ))

while :; do
    if ! json=$(gh api "repos/$repo/actions/runs?head_sha=$sha&event=push&per_page=100"); then
        echo "  could not list the runs for $sha; trying again"
        [ "$(date +%s)" -lt "$deadline" ] || { echo "::error::could not list the CI runs for $sha"; exit 1; }
        sleep 30
        continue
    fi
    # one line per run: workflow, where it ran, status, conclusion, link
    runs=$(jq -r --arg tag "$tag" '.workflow_runs[]
             | select(.head_branch == "main" or .head_branch == $tag)
             | select(.name == "hygiene" or .name == "build" or .name == "integration")
             | "\(.name) \(if .head_branch == $tag then "tag" else "main" end) \(.status) \(.conclusion // "-") \(.html_url)"' <<< "$json")
    pending=0
    for wf in hygiene build integration; do
        mine=$(grep "^$wf " <<< "$runs" || true)
        if ! grep -q "^$wf tag " <<< "$mine"; then
            pending=1; echo "  $wf: no run for $tag yet"
        elif grep -qv '^[^ ]* [^ ]* completed ' <<< "$mine"; then
            pending=1; echo "  $wf: still running"
        elif bad=$(grep -v '^[^ ]* [^ ]* completed success ' <<< "$mine"); then
            echo "::error::$wf did not pass for $sha: $bad"
            exit 1
        fi
    done
    if [ "$pending" = 0 ]; then
        echo "  hygiene, build and integration all passed for $tag ($sha)"
        exit 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "::error::the CI for $tag ($sha) did not finish within $minutes minutes"
        exit 1
    fi
    sleep 30
done
