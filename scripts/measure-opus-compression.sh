#!/usr/bin/env bash
# libopus -compression_level A/B on real ambisonic material, judged by AMBIQUAL.
#
# Reference is the uncompressed excerpt in every case, never the other encode:
# the question is "how much quality does level N give up", so both settings need
# the same uncompressed reference. Comparing the two encodes to each other would
# measure their difference from one another, which is a different number.
#
# Production settings, read off services/earshot/src/nginx-transcoder/
# direct-dash-gate.sh rather than assumed: libopus, mapping_family 255, 1536k
# for 16 channels (96 kbit/s per channel). Only -compression_level varies.
#
# 0 is included to bracket the answer. If 5 and 10 are indistinguishable, 0
# says whether the metric can see ANY difference at all on this material - a
# guard against concluding "transparent" from a metric that is simply blind
# here.
set -uo pipefail
cd "$(dirname "$0")/.."
# AMBIQUAL is not vendored: it is a separate GPL-free research tool with its
# own dependencies, and it needs a local patch to run at all (see RESULTS.md).
AQ=${AMBIQUAL_DIR:-$HOME/Downloads-repos/Ambiqual}
W=${WORKDIR:-$PWD/opus-compression-test/work}
OUT=$PWD/opus-compression-test/results.tsv
mkdir -p "$W"

# Windows chosen by scripts/pick-excerpt.py rather than a fixed offset: the
# first pass cut everything at 60 s and put the live-concert excerpt in the
# pre-concert audience (spectral flatness 0.33 at -49 dBFS) and the ambience
# one at 66 % silence. Selection is part of the method.
ITEMS="piano orchestra deusexmachina carnival quarry"
LEVELS="10 5 0"

printf 'item\tlevel\tLQ\tLA\n' > "$OUT"
for it in $ITEMS; do
    ref="$W/${it}_ref.wav"
    [ -f "$ref" ] || { echo "missing $ref" >&2; continue; }
    for lvl in $LEVELS; do
        enc="$W/${it}_c${lvl}.webm"; deg="$W/${it}_c${lvl}.wav"
        if [ ! -f "$deg" ]; then
            ffmpeg -v error -y -i "$ref" -c:a libopus -mapping_family 255 \
                -b:a 1536k -compression_level "$lvl" "$enc" || continue
            ffmpeg -v error -y -i "$enc" -c:a pcm_s24le "$deg" || continue
        fi
        # `python -m ambiqual` needs ITS OWN directory on sys.path, so run from
        # there with absolute paths. Resolving $ref/$deg before the subshell
        # matters: $PWD inside it is already the Ambiqual directory.
        raw=$(cd "$AQ" && ./.venv/bin/python -m ambiqual --ref "$ref" --deg "$deg" 2>&1)
        lq=$(printf '%s' "$raw" | awk '/^LQ:/{print $2}')
        la=$(printf '%s' "$raw" | awk '/^LA:/{print $2}')
        printf '%s\t%s\t%s\t%s\n' "$it" "$lvl" "${lq:-ERR}" "${la:-ERR}" | tee -a "$OUT"
    done
done
echo "--- done ---"
