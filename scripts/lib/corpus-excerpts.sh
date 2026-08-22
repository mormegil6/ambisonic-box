# shellcheck shell=sh
# Shared excerpt selection for the measurement harnesses. Sourced, not run.
#
# WHY THIS IS ONE FILE. Both studies measure the same five items from the same
# corpus. Holding that mapping in two places is a defect waiting to happen, so
# the corpus path, the five recordings and the picker call live here and each
# harness sources them.
#
# WHAT A HARNESS STILL OWNS: the actual cut. The AAC study cuts inside the
# earshot image (its ffmpeg is the one that can write 16-channel AAC), the
# Opus study cuts on the host, so the ffmpeg invocation cannot be shared - only
# the decision about WHAT to cut.
#
# NEVER default an offset. A 2026-08-15 run parsed the picker's output with a
# pattern it never emits, silently fell back to offset 0 for all five excerpts,
# and published a curve measured partly on near-silence. pick_start() exits
# rather than guess.

CORPUS=${CORPUS_DIR:-"/Volumes/Scratch/A Seven-Year Corpus of Higher-Order Ambisonics Recordings"}

# The picker needs soundfile+numpy, which a system python generally lacks; the
# AMBIQUAL venv has both. Getting this wrong is not loud - the import error
# goes to stderr and an unchecked caller sees an empty answer.
PICK_PY=${PICK_PY:-${AMBIQUAL_DIR:-$HOME/Downloads-repos/Ambiqual}/.venv/bin/python}

# ITEM -> SOURCE, relative to $CORPUS/sessions/. Verified against the corpus on
# disk. Two are not the obvious pick and should not be "corrected": `piano` is
# Grainger's Bridal Lullaby rather than the more prominent Chopin recording, and
# `quarry` uses the first of its two takes, the one the published corpus carries.
ITEM_piano=${ITEM_piano:-"2021-03-27_aula-pg_solo-piano/audio/3OA_ZM1_PGrainger-BridalLullaby.wav"}
ITEM_orchestra=${ITEM_orchestra:-"2022-03-10_gut-lobby_choir-orchestra/audio/3OA_ZM1_JubileeConcertPt1.wav"}
ITEM_deusexmachina=${ITEM_deusexmachina:-"2023-06-03_aula-pg_choir-contemporary/audio/3OA_ZM1_JNeske-DeusExMachina.wav"}
ITEM_carnival=${ITEM_carnival:-"2023-02-21_gut-lobby_choir-jazz-band/audio/3OA_ZM1_Concert.wav"}
ITEM_quarry=${ITEM_quarry:-"2024-07-27_piechcin-quarry_vr-production-outdoor/audio/3OA_ZM1_scena1.wav"}
ITEMS=${ITEMS:-"piano orchestra deusexmachina carnival quarry"}

# require_corpus - refuse to start without the recordings, and say where to get
# them. The corpus is public, so a stranger can reproduce either study.
require_corpus() {
    [ -d "$CORPUS" ] || {
        echo "corpus not found: $CORPUS" >&2
        echo "  This study measures the HOA seven-year corpus, which is public:" >&2
        echo "    https://doi.org/10.34808/w8bx-2094" >&2
        echo "  Point CORPUS_DIR at your copy (the directory holding sessions/):" >&2
        echo "    CORPUS_DIR=/path/to/corpus $0" >&2
        exit 2
    }
    [ -x "$PICK_PY" ] || {
        echo "no python with soundfile+numpy at $PICK_PY (set PICK_PY)" >&2
        exit 2
    }
}

# item_source <item> - the corpus-relative path for an item.
item_source() {
    eval "printf '%s' \"\${ITEM_$1}\""
}

# pick_start <item> <length_s> - sets PICK_START to the content-chosen window
# offset in seconds. Exits on any failure: there is no sane default, and offset
# 0 has already been published once by accident.
#
# It sets a VARIABLE rather than printing, deliberately. Called as
# `start=$(pick_start ...)` the refusal below would exit only the command
# substitution's subshell, the caller would read an empty string, and a harness
# that then defaulted it would repeat the exact bug this guards against.
#
# Assumes the caller has cd'd to the repo root, as both harnesses do: a sourced
# file cannot portably find its own path, and $0 here is the caller.
pick_start() {
    _item=$1; _len=$2
    _src="$CORPUS/sessions/$(item_source "$_item")"
    [ -f "$_src" ] || { echo "missing source for $_item: $_src" >&2; exit 3; }
    [ -f scripts/pick-excerpt.py ] || { echo "run this from the repo root" >&2; exit 3; }
    _out=$("$PICK_PY" scripts/pick-excerpt.py "$_src" --length "$_len" --top 1 2>&1) || {
        echo "picker failed for $_item:" >&2; printf '%s\n' "$_out" >&2; exit 3; }
    # The picker prints "PICK <t>s  (level ...)".
    PICK_START=$(printf '%s\n' "$_out" | awk '/^PICK /{gsub(/s$/,"",$2); print $2; exit}')
    [ -n "$PICK_START" ] || {
        echo "no PICK line for $_item - refusing to guess an offset" >&2
        printf '%s\n' "$_out" >&2; exit 3; }
}

# manifest_init <file> / manifest_add <file> <item> <src> <start> <len>
# The windows behind a published figure, recorded so they stay checkable after
# a work directory is deleted - which is how the Opus study lost its own.
manifest_init() { printf 'item\tsource\tstart_s\tlength_s\n' > "$1"; }
manifest_add()  { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$1"; }
