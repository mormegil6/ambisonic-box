#!/bin/sh
# BAM-Q + GPSMq second opinion on the AAC bitrate study: render, pair, score,
# plot. One command, because doing it by hand is four steps and three of them
# have a trap.
#
# WHY THIS EXISTS. Until 2026-08-22 this half of aac-bitrate-test/RESULTS.md was
# run by hand and only the two endpoints were in the repo (binauralize.js and
# run_bamq.m). Everything between them - which conditions get rendered, what is
# compared against what, and what those comparisons are called - lived in a
# throwaway snippet. Each of those bit once in a single evening:
#   - binauralize.js defaults to MODES=fixed, so the buggy-decoder renders are
#     silently skipped and the decoder-defect section has no data.
#   - the pair labels must read <item>_DECODERBUG, because plot-bamq.py greps
#     for exactly that; lowercase produced a KeyError after the MATLAB run.
#   - nothing checked that work/ held the excerpts the study claims to measure.
#
# WHAT IS MEASURED IS NOT CHOSEN HERE. This script scores whatever
# aac-bitrate-test/work/ contains, which measure-aac-bitrate.sh put there from
# the corpus at the offsets recorded in aac-bitrate-test/excerpts.tsv. Both
# metrics therefore judge identical material by construction. Run
# measure-aac-bitrate.sh first; this refuses to start without its manifest,
# because scoring a stale work directory is the one failure that looks like a
# result.
set -eu

cd "$(dirname "$0")/.."

WORK=${WORKDIR:-aac-bitrate-test/work}
BINAURAL=${BINAURAL_DIR:-aac-bitrate-test/binaural}
MANIFEST=${MANIFEST:-aac-bitrate-test/excerpts.tsv}
OUT=${OUTFILE:-aac-bitrate-test/bamq.tsv}
PAIRS=${PAIRS:-aac-bitrate-test/bamq-pairs.tsv}
BAMQ_DIR=${BAMQ_DIR:-$HOME/Downloads-repos/bamq-binaqual/combinedaudioqualitymodel-master}
PLOT_PY=${PLOT_PY:-$HOME/Downloads-repos/Ambiqual/.venv/bin/python}
TAG=${TAG:-2026-08}
ITEMS=${ITEMS:-"piano orchestra deusexmachina carnival quarry"}
# The four codec conditions BAM-Q scores. The full ladder is six rates; these
# are the two that bracket the production setting, in both chains, which is
# what the second opinion is for - not a re-run of the whole curve.
CONDS=${CONDS:-"aac96 aac128 casc96 casc128"}
# binauralize.js reaches everything over HTTP (the page is an ES module and it
# fetches the study WAVs), so file:// cannot work.
PORT=${PORT:-8099}
BASE=${BASE:-http://127.0.0.1:$PORT}

die() { echo "measure-bamq: $*" >&2; exit 1; }

[ -f "$MANIFEST" ] || die "no $MANIFEST - run scripts/measure-aac-bitrate.sh first, so the excerpts are recorded"
# Probe only when the caller supplied nothing: the old form ran its right-hand
# side whenever matlab was off PATH, overwriting an explicit MATLAB= and, with
# no app installed, building the phantom path "/bin/matlab" out of an empty ls.
if [ -z "${MATLAB:-}" ] && ! command -v matlab >/dev/null 2>&1; then
    app=$(ls -d /Applications/MATLAB_R20*.app 2>/dev/null | tail -1)
    [ -n "$app" ] && MATLAB=$app/bin/matlab
fi
MATLAB=${MATLAB:-matlab}
[ -x "$MATLAB" ] || command -v "$MATLAB" >/dev/null 2>&1 || die "no MATLAB found (set MATLAB=/path/to/matlab)"
[ -d "$BAMQ_DIR" ] || die "BAM-Q model not at $BAMQ_DIR (set BAMQ_DIR)"
# plot-bamq.py hardcodes the full 5x4 grid and indexes bamq.tsv by
# "<item>_<cond>", so a narrowed run cannot be plotted and must not be allowed
# to overwrite the published table with a partial one.
if [ "$ITEMS" != "piano orchestra deusexmachina carnival quarry" ] || \
   [ "$CONDS" != "aac96 aac128 casc96 casc128" ]; then
    [ "$OUT" = "aac-bitrate-test/bamq.tsv" ] && die "narrowed ITEMS/CONDS cannot be plotted and would overwrite the published $OUT - set OUTFILE to something else"
    PLOT=0
else
    PLOT=1
fi
[ -x "$PLOT_PY" ] || die "no python with matplotlib at $PLOT_PY (set PLOT_PY)"

echo "measure-bamq: scoring the excerpts recorded in $MANIFEST"
sed -n '2,$p' "$MANIFEST" | while IFS="$(printf '\t')" read -r item src start len; do
    printf '  %-15s %ss + %ss  %s\n' "$item" "$start" "$len" "$src"
done

missing=0
for it in $ITEMS; do
    for c in ref $CONDS; do
        [ -f "$WORK/${it}_${c}.wav" ] || { echo "  MISSING $WORK/${it}_${c}.wav" >&2; missing=1; }
    done
done
[ "$missing" -eq 0 ] || die "work directory does not hold the study's conditions; re-run measure-aac-bitrate.sh"

# 1. Render to binaural through HOAST360's own decoder. BOTH modes: 'buggy'
#    reproduces the pre-fix filter loading, and the decoder-defect section of
#    RESULTS.md is measured from it, so it is not optional here.
# Serve the repo root ourselves, as measure-lipsync.js does, and stop it on the
# way out however we leave.
if curl -sf -o /dev/null "$BASE/scripts/binauralize.html" 2>/dev/null; then
    echo "measure-bamq: reusing the server already on $BASE"
else
    echo "measure-bamq: serving the repo on $BASE"
    python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
    SRV=$!
    trap 'kill $SRV 2>/dev/null' EXIT INT TERM
    i=0
    while [ $i -lt 40 ]; do
        curl -sf -o /dev/null "$BASE/scripts/binauralize.html" 2>/dev/null && break
        i=$((i + 1))
    done
    [ $i -lt 40 ] || die "static server did not come up on $BASE"
fi

echo "measure-bamq: rendering (fixed + buggy)"
MODES="fixed buggy" CONDS="ref $CONDS" WORK="$WORK" OUTDIR="$BINAURAL" node scripts/binauralize.js

# 2. The comparison list. BAM-Q is full-reference: every row is one
#    reference-against-test judgement. Labels are the contract with
#    plot-bamq.py - <item>_DECODERBUG in caps, codec conditions as named above.
echo "measure-bamq: writing $PAIRS"
: > "$PAIRS"
abs=$(cd "$BINAURAL" && pwd)
for it in $ITEMS; do
    for c in $CONDS; do
        printf '%s_%s\t%s/%s_ref_binaural.wav\t%s/%s_%s_binaural.wav\n' \
            "$it" "$c" "$abs" "$it" "$abs" "$it" "$c" >> "$PAIRS"
    done
    # Both sides uncoded: the same reference decoded correctly and through the
    # 2020 filter-loading defect, so no codec confound sits in the comparison.
    printf '%s_DECODERBUG\t%s/%s_ref_binaural.wav\t%s/%s_ref_buggy_binaural.wav\n' \
        "$it" "$abs" "$it" "$abs" "$it" >> "$PAIRS"
done
echo "  $(wc -l < "$PAIRS") comparisons"

# 3. Score. -batch so it runs headless and returns a real exit code.
echo "measure-bamq: running BAM-Q in MATLAB"
"$MATLAB" -nodisplay -nosplash -batch \
    "addpath('scripts'); run_bamq('$PWD/$PAIRS','$BAMQ_DIR','$PWD/$OUT')"

# 4. Figure.
if [ "$PLOT" -eq 1 ]; then
    echo "measure-bamq: plotting"
    "$PLOT_PY" scripts/plot-bamq.py "$TAG"
else
    echo "measure-bamq: narrowed run - table only, no figure"
fi

echo "measure-bamq: done - $OUT and the $TAG figure are current"
