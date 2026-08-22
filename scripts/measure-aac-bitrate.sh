#!/usr/bin/env bash
# AAC contribution bitrate vs quality on 16-channel ambisonics, judged by AMBIQUAL.
#
# THE QUESTION. docs/BITRATE.md sets contribution at 96 kbit/s per channel and
# justifies it entirely by borrowed convention: AAC-LC's classic ~64/channel
# figure, EBU Tech 3324's 448 for 5.1 (~75/channel), YouTube's 256 for 4-channel
# ambisonics (64/channel). None of those is HIGHER-ORDER ambisonics, and the doc
# says so, calling 96 "a well-covered convention rather than a proven threshold".
# This measures the curve that convention is standing in for.
#
# WHAT IT CANNOT DO, stated up front so no reader takes more from it than it
# holds: this is an objective metric, not a listening test. It cannot establish
# transparency, which is a subjective ABX threshold. It can say where measurable
# degradation begins on this material, and whether 96 sits above or below it.
#
# TWO CURVES, because they answer different questions:
#   aac      contribution leg in isolation, which is what the 96/channel rule
#            literally governs.
#   cascade  AAC then Opus at the production 1536k, which is what a viewer
#            actually receives, since earshot re-encodes. If the two converge,
#            contribution bitrate stops mattering above that point because Opus
#            is the binding constraint - which would be the useful result.
#
# ENCODER IS FFMPEG'S NATIVE AAC, deliberately: that is what OBS and the
# contribution leg use. libfdk would measure a codec this project never runs.
#
# AND IT RUNS INSIDE THE EARSHOT IMAGE, which is not a convenience. Measured
# 2026-08-15: a host ffmpeg 9.0 CANNOT encode 16-channel AAC at all. `-ac 16`
# there resolves to layout "9.1.6", which the encoder refuses, and naming
# `hexadecagonal` explicitly is refused too. The earshot image's pinned
# FFmpeg 7.1 encodes it cleanly: aacenc lost the last aac_pce_configs[] entries
# above OCTAGONAL in c92c6cbf19, reported as FFmpeg#24218, and 8.1 is the last
# release that can still do it. So the 16-channel ceiling documented in
# docs/AMBISONIC-ORDER.md is version-dependent as well as layout-dependent, and
# a study run with a modern host ffmpeg would measure nothing at all. Using the
# container also means this measures the encoder the contribution leg really
# runs, rather than a newer one it does not.
#
# REFERENCE IS THE UNCOMPRESSED EXCERPT in every case, never one encode against
# another, the same discipline as measure-opus-compression.sh: the question is
# how much quality a setting gives up, so every setting needs the same reference.
set -uo pipefail
# pick_start() resolves scripts/pick-excerpt.py relative to $PWD, and the paths
# below are $PWD-relative, so this must come before both.
SELF=$(cd "$(dirname "$0")" && pwd)
cd "$SELF/.."

AQ=${AMBIQUAL_DIR:-$HOME/Downloads-repos/Ambiqual}
# The corpus path, the five recordings and the window picker are shared with
# measure-opus-compression.sh so the two studies cannot drift apart.
. "$SELF/lib/corpus-excerpts.sh" || { echo "cannot source lib/corpus-excerpts.sh" >&2; exit 2; }
W=${WORKDIR:-$PWD/aac-bitrate-test/work}
OUT=${OUTFILE:-$PWD/aac-bitrate-test/results.tsv}
MANIFEST=${MANIFEST:-$PWD/aac-bitrate-test/excerpts.tsv}
LEN=${EXCERPT_S:-30}
SR=48000   # every corpus source is 48 kHz (verified against corpus_statistics.csv)
END_SAMPLE=$(( LEN * SR ))

# Per-channel rates. 96 is production; 64 is where every published anchor sits;
# 32 and 48 bracket the low end where AAC should visibly fail, which is what
# makes the curve readable rather than a flat line of "fine everywhere".
RATES=${RATES:-"32 48 64 96 128 160"}


# All ffmpeg work runs in the earshot image (see the header for why). $W is
# mounted at /w and the corpus read-only at /c, so paths inside are stable.
FF() { docker run --rm -v "$W":/w -v "$CORPUS":/c:ro \
        --entrypoint ffmpeg ambi-box-earshot:local "$@"; }


# Frame count, verified rather than assumed. On 2026-08-15 the identical decode
# command, run seconds apart under Docker load from unrelated work, landed on
# the exact sample count three times and overshot by 768 samples (one AAC
# frame) twice - same ffmpeg invocation, different outcome. Not a filter bug:
# a batch of ~60 of these needs each one checked, or a silently truncated file
# would enter AMBIQUAL as if it were exact.
frame_count() { python3 -c "import wave,sys; print(wave.open(sys.argv[1]).getnframes())" "$1" 2>/dev/null; }

# decode_exact <container-in> <out-wav-on-host> - decode + pad/trim to
# END_SAMPLE, retrying the WHOLE step (not just the trim) up to 3 times if the
# result is not sample-exact, since the same command can succeed on a retry.
decode_exact() {
    local cin=$1 out=$2 i
    for i in 1 2 3; do
        FF -v error -y -i "$cin" -af "apad,atrim=end_sample=$END_SAMPLE" \
            -c:a pcm_s24le "/w/$(basename "$out")" || return 1
        [ "$(frame_count "$out")" = "$END_SAMPLE" ] && return 0
        echo "[aac] $(basename "$out"): got $(frame_count "$out") frames, wanted $END_SAMPLE, retry $i/3" >&2
    done
    echo "[aac] $(basename "$out"): would not land on $END_SAMPLE after 3 tries" >&2
    return 1
}

mkdir -p "$W" "$(dirname "$OUT")"
require_corpus
[ -x "$AQ/.venv/bin/python" ] || { echo "AMBIQUAL venv missing: $AQ/.venv" >&2; exit 2; }

printf 'item\tchain\tkbps_per_ch\tLQ\tLA\n' > "$OUT"
manifest_init "$MANIFEST"

for it in $ITEMS; do
    src=$(item_source "$it")
    full="$CORPUS/sessions/$src"
    [ -f "$full" ] || { echo "missing source for $it: $full" >&2; continue; }

    # Excerpt chosen by CONTENT, not by clock. A fixed offset put the Opus
    # study's concert excerpt in the pre-concert audience and left its ambience
    # item mostly silent; selection is part of the method, not a detail.
    ref="$W/${it}_ref.wav"; off="$W/${it}_ref.start"
    # The offset is cached beside the WAV. manifest_init truncated the manifest
    # at the start of this run, and a warm work directory skips the cut, so
    # writing the row only when cutting would leave a published study with a
    # header-only excerpts.tsv.
    unset PICK_START
    if [ ! -f "$ref" ] || [ ! -f "$off" ]; then
        echo "[aac] picking a ${LEN}s window in $it" >&2
        pick_start "$it" "$LEN"          # sets PICK_START, or exits
        start=$PICK_START
        FF -v error -y -ss "$start" -t "$LEN" -i "/c/sessions/$src" \
            -c:a pcm_s24le "/w/${it}_ref.wav" || continue
        printf '%s\n' "$start" > "$off"
        echo "[aac] $it ref cut at ${start}s" >&2
    fi
    start=${PICK_START:-$(cat "$off" 2>/dev/null)}
    [ -n "$start" ] || { echo "[aac] no recorded offset for $it" >&2; exit 3; }
    # Record what was actually measured, so the windows behind a published
    # figure stay checkable after the work directory is gone.
    manifest_add "$MANIFEST" "$it" "$src" "$start" "$LEN"

    for kb in $RATES; do
        total=$(( kb * 16 ))

        # --- curve 1: the contribution leg alone ---
        enc="$W/${it}_aac${kb}.m4a"; deg="$W/${it}_aac${kb}.wav"
        if [ ! -f "$deg" ]; then
            FF -v error -y -i "/w/${it}_ref.wav" \
                -af "channelmap=channel_layout=hexadecagonal" \
                -c:a aac -strict -2 -b:a "${total}k" -f mp4 "/w/${it}_aac${kb}.m4a" || continue
            # apad,atrim=end_sample=N - not `-t N` and not `apad=whole_dur=N`. AAC
            # decode comes back a few samples short OR long depending on encoder
            # priming, and AMBIQUAL needs sample-exact equality with the
            # reference or it throws on the broadcast. Two time-based attempts
            # failed silently on this ffmpeg build: `apad -t 30` produced
            # 29.9935s, `apad=whole_dur=30` produced 30.016s. atrim's end_sample
            # cuts by sample INDEX and is exact - but see decode_exact() above:
            # even this exact command was seen to occasionally overshoot under
            # load, so it is retried and checked, not trusted once.
            decode_exact "/w/${it}_aac${kb}.m4a" "$deg" || continue
        fi
        raw=$(cd "$AQ" && ./.venv/bin/python -m ambiqual --ref "$ref" --deg "$deg" 2>&1)
        lq=$(printf '%s' "$raw" | awk '/^LQ:/{print $2}')
        la=$(printf '%s' "$raw" | awk '/^LA:/{print $2}')
        printf '%s\taac\t%s\t%s\t%s\n' "$it" "$kb" "${lq:-ERR}" "${la:-ERR}" | tee -a "$OUT"

        # --- curve 2: what the viewer actually gets (AAC then Opus) ---
        cenc="$W/${it}_casc${kb}.webm"; cdeg="$W/${it}_casc${kb}.wav"
        if [ ! -f "$cdeg" ]; then
            FF -v error -y -i "/w/${it}_aac${kb}.wav" -c:a libopus \
                -mapping_family 255 -b:a 1536k "/w/${it}_casc${kb}.webm" || continue
            decode_exact "/w/${it}_casc${kb}.webm" "$cdeg" || continue
        fi
        raw=$(cd "$AQ" && ./.venv/bin/python -m ambiqual --ref "$ref" --deg "$cdeg" 2>&1)
        lq=$(printf '%s' "$raw" | awk '/^LQ:/{print $2}')
        la=$(printf '%s' "$raw" | awk '/^LA:/{print $2}')
        printf '%s\tcascade\t%s\t%s\t%s\n' "$it" "$kb" "${lq:-ERR}" "${la:-ERR}" | tee -a "$OUT"
    done
done

echo "--- done, results in $OUT ---"
