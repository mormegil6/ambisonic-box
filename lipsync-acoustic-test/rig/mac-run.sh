#!/bin/bash
# One run on this Mac timed by the photodiode rig: the usual driver plays the clip, with every browser window at the
# same place so the video box covers the sensor, while the Pi records the photodiode and the Mac's headphone output.
# usage: rig/mac-run.sh <tag> <chrome|canary|safari|firefox> <clip>     then: python3 analyze-rig.py <tag>
# Needs: the sensor taped at the video box of a window at (80,60) 1100 wide (open one with rig/mac-show.mjs), the Mac's
# sound output set to the headphone port, wired to the Pi's card as input 1 right, 2 left, 3 photodiode.
cd "$(dirname "$0")/.." || exit 1
tag=$1 eng=$2 clip=$3 DUR=${DUR:-40} PI=${PI:-pi-hole} CARD=${PI_CARD:-hw:3,0}
ssh "$PI" "arecord -q -D $CARD -c 4 -r 48000 -f S16_LE -d $((DUR + 30)) /tmp/$tag.wav" &
rec=$!
sleep 1
case $eng in
  chrome) WINDOW_POS=80,60 node measure.cjs "$tag" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$clip" ;;
  canary) WINDOW_POS=80,60 node measure.cjs "$tag" "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" "$clip" ;;
  safari|firefox) WINDOW_RECT=80,60,1100,800 BOX_AT=202,326 node measure-wd.mjs "$tag" "$eng" "$clip" ;;
esac > "runs/$tag.log" 2>&1
wait $rec
scp -q "$PI:/tmp/$tag.wav" "runs/$tag.rig.wav"
