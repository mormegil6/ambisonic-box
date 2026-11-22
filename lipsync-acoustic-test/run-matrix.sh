#!/bin/bash
# Measure the offset for every browser and clip, one run each, and append one line per run to runs/results.tsv.
# usage: ./run-matrix.sh <prefix> [engine ...]       engines: chrome canary canaryKS safari firefox firefoxNightly (default: chrome canary canaryKS safari)
# env:   BUNDLE=/path/to/hoast360.bundle.js to test a build that is not deployed; BASE, DEVICE, DUR as in measure.cjs;
#        CHROME and CANARY (browser executables), PY (python3 with numpy), CLIPS (default: nob trim ctrl live elst).
# Needs: the output of ./make-fixtures.sh, the compiled ./cap (swiftc -O cap.swift -o cap), and the Mac's sound output set to the
#        capture device. canaryKS is Canary started with --disable-features=MP4ApplyEmptyEditList.
cd "$(dirname "$0")" || exit 1
PREFIX=${1:?usage: run-matrix.sh <prefix> [engine ...]}; shift
ENGINES=${*:-chrome canary canaryKS safari}
CLIPS=${CLIPS:-nob trim ctrl live elst}
PY=${PY:-python3}
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
CANARY=${CANARY:-"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"}
mkdir -p runs
one() { # tag command...
  local tag=$1; shift
  "$@" > "runs/$tag.log" 2>&1 || { echo "$tag: run failed, see runs/$tag.log"; return; }
  $PY analyze.py "$tag" >> runs/results.tsv 2>> runs/results.err
  tail -1 runs/results.tsv | awk -F'\t' '{printf "%-26s %-6s %s | %s\n", $1, $3, $5, $6}'
}
for e in $ENGINES; do
  for c in $CLIPS; do
    tag=$PREFIX-$e-$c
    case $e in
      chrome)   one "$tag" node measure.cjs "$tag" "$CHROME" "$c" ;;
      canary)   one "$tag" node measure.cjs "$tag" "$CANARY" "$c" ;;
      canaryKS) one "$tag" env ARGS=--disable-features=MP4ApplyEmptyEditList node measure.cjs "$tag" "$CANARY" "$c" ;;
      firefoxNightly) one "$tag" env FIREFOX_BIN="${FIREFOX_NIGHTLY:-/Applications/Firefox Nightly.app/Contents/MacOS/firefox}" node measure-wd.mjs "$tag" firefox "$c" ;;
      safari|firefox) one "$tag" node measure-wd.mjs "$tag" "$e" "$c" ;;
      *) echo "unknown engine $e"; exit 2 ;;
    esac
  done
done
