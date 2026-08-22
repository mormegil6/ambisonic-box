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
# $0 is relative to the ORIGINAL cwd, so resolve it before cd'ing away:
# otherwise a run from any other directory re-resolves it against the repo root.
SELF=$(cd "$(dirname "$0")" && pwd)
cd "$SELF/.."
# AMBIQUAL is not vendored: it is a separate GPL-free research tool with its
# own dependencies, and it needs a local patch to run at all (see RESULTS.md).
AQ=${AMBIQUAL_DIR:-$HOME/Downloads-repos/Ambiqual}
W=${WORKDIR:-$PWD/opus-compression-test/work}
OUT=$PWD/opus-compression-test/results.tsv
MANIFEST=${MANIFEST:-$PWD/opus-compression-test/excerpts.tsv}
LEN=${EXCERPT_S:-30}
# Corpus path, the five recordings and the window picker, shared with
# measure-aac-bitrate.sh so the two studies cannot drift apart.
# A failed `.` only warns in bash and there is no set -e, so without this
# guard every helper below would be "command not found" and the run would
# still exit 0.
. "$SELF/lib/corpus-excerpts.sh" || { echo "cannot source lib/corpus-excerpts.sh" >&2; exit 2; }
mkdir -p "$W"

# Windows chosen by scripts/pick-excerpt.py rather than a fixed offset: an
# early pass cut everything at 60 s and put the live-concert excerpt in the
# pre-concert audience (spectral flatness 0.33 at -49 dBFS) and the ambience
# one at 66 % silence. Selection is part of the method, and this harness now
# does it itself. It used to require pre-cut reference WAVs and skip any item
# whose file was missing, which meant the windows behind the published numbers
# lived only in a work directory - and when that directory was deleted the
# study became unreproducible. The offsets are recorded in $MANIFEST now.
LEVELS="10 5 0"

require_corpus
printf 'item\tlevel\tLQ\tLA\n' > "$OUT"
manifest_init "$MANIFEST"
for it in $ITEMS; do
    src=$(item_source "$it")
    ref="$W/${it}_ref.wav"
    # The offset is cached beside the WAV so a REUSED ref still knows which
    # window it is. pick_start sets PICK_START as a plain global that outlives
    # the iteration, so without clearing it a cached item would be recorded
    # with the PREVIOUS item's offset, and a fully warm re-run would truncate
    # the manifest to nothing useful.
    off="$W/${it}_ref.start"
    unset PICK_START
    if [ ! -f "$ref" ] || [ ! -f "$off" ]; then
        echo "[opus] picking a ${LEN}s window in $it" >&2
        pick_start "$it" "$LEN"          # sets PICK_START, or exits
        ffmpeg -v error -y -ss "$PICK_START" -t "$LEN" -i "$CORPUS/sessions/$src" \
            -c:a pcm_s24le "$ref" || { echo "[opus] could not cut $it" >&2; exit 3; }
        printf '%s\n' "$PICK_START" > "$off"
        echo "[opus] $it ref cut at ${PICK_START}s" >&2
    fi
    start=${PICK_START:-$(cat "$off" 2>/dev/null)}
    [ -n "$start" ] || { echo "[opus] no recorded offset for $it" >&2; exit 3; }
    manifest_add "$MANIFEST" "$it" "$src" "$start" "$LEN"
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
