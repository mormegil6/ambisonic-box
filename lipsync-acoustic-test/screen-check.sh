#!/bin/bash
# The same runs as run-matrix.sh, with the screen and the system audio recorded alongside by screencap (ScreenCaptureKit),
# so that the flash can be timed from the captured picture instead of from the browser's frame callback.
# usage: ./screen-check.sh <prefix> [engine ...]   (default engines: chrome safari; CLIPS default: nob)
# Needs Screen Recording permission for the app that runs it (System Settings, Privacy & Security, Screen & System Audio
# Recording), and ./screencap built with: swiftc -O screencap.swift -o screencap
cd "$(dirname "$0")" || exit 1
PREFIX=${1:?usage: screen-check.sh <prefix> [engine ...]}; shift
ENGINES=${*:-chrome safari}
CLIPS=${CLIPS:-nob}
DUR=${DUR:-40}
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
mkdir -p runs
./screencap 1 runs/.sc-permission-check > /dev/null 2>&1 || { echo "screencap cannot record: grant Screen Recording to this terminal app, quit and reopen it, then run again"; exit 1; }
for e in $ENGINES; do
  for c in $CLIPS; do
    tag=$PREFIX-$e-$c
    ./screencap $((DUR + 25)) "runs/$tag.sc" 2> "runs/$tag.sc.log" &
    sc=$!
    sleep 1
    case $e in
      chrome) node measure.cjs "$tag" "$CHROME" "$c" > "runs/$tag.log" 2>&1 ;;
      safari|firefox) node measure-wd.mjs "$tag" "$e" "$c" > "runs/$tag.log" 2>&1 ;;
      *) echo "unknown engine $e"; kill $sc; exit 2 ;;
    esac
    wait $sc
    echo "$tag: $(tail -1 "runs/$tag.sc.log")"
  done
done
echo "finished; tell Claude the prefix: $PREFIX"
