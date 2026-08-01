#!/usr/bin/env bash
# Merge a stock-OBS multitrack recording into a single multichannel file the
# stack can use, or push it straight to the RTMP ingest.
#
# Why this exists: stock OBS (macOS verified 2026-07-31, 32.2.1) records
# discrete multichannel audio PER TRACK from a multichannel Core Audio device
# with the global layout set to 4.0 (quad; four full-band channels per track,
# NEVER an LFE-bearing layout - 7.1 mutes the LFE slot outright, which would
# erase ambisonic ACN 3) - but it cannot merge its own tracks, and it tags
# each one with surround semantics. So a 16-channel ambisonic capture arrives
# as four 4-channel AAC tracks (FFmpeg AAC encoder, not CoreAudio - see the
# README recipe) whose channel ORDER is right and whose layout TAG is wrong.
# This script concatenates the tracks in container order (OBS track order is
# preserved in the file) and replaces the surround tag:
#   - default: a PCM master (.mov, video stream copied). It carries the same
#     named layout when one exists (16 -> hexadecagonal, 4 -> quad), because
#     that is what any later AAC encode of the master needs anyway; other
#     counts stay as an untagged N-channel layout
#   - --push:  live-shaped FLV to the ingest, H.264 copied, audio re-encoded
#     to AAC with the NAMED layout the channel count requires (hexadecagonal
#     for 16, quad for 4), because a named layout is what makes ffmpeg's AAC
#     encoder emit the PCE that the RTMP contribution leg needs. Counts with
#     no AAC-named layout (9, 25) are refused for --push, same rule as the
#     rest of the stack; 2nd-order sources must be zero-padded to 16 by the
#     sender.
#
# The merge is 1:1 channel mapping only - never a downmix.
#
# Usage:
#   merge-obs-tracks.sh --check <obs-recording>
#   merge-obs-tracks.sh <obs-recording> [merged.mov] [--channels N]
#   merge-obs-tracks.sh <obs-recording> --push rtmp://<host>:1935/live/<key> [--channels N]
#
#   --channels N   keep only the first N merged channels (default: all).
#                  Use 16 when capturing 3OA across 4-channel tracks.
#   --check        probe and report the recording's track/channel shape, then exit.
#   --loop         (push mode) loop the input endlessly, so a short capture can
#                  drive a longer live test; stop with ctrl-C.
#
# Exit codes: 0 OK, 1 failure, 2 bad invocation / unusable input.

set -euo pipefail

INPUT="" OUTPUT="" PUSH_URL="" CHANNELS="" CHECK=0 LOOP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check)    CHECK=1 ;;
        --loop)     LOOP=1 ;;
        --push)     PUSH_URL="${2:?--push needs a URL}"; shift ;;
        --channels) CHANNELS="${2:?--channels needs a number}"; shift ;;
        -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "unknown option: $1" >&2; exit 2 ;;
        *)  if [ -z "$INPUT" ]; then INPUT="$1"
            elif [ -z "$OUTPUT" ]; then OUTPUT="$1"
            else echo "unexpected argument: $1" >&2; exit 2; fi ;;
    esac
    shift
done

[ -n "$INPUT" ] || { echo "usage: $0 [--check] <obs-recording> [merged.mov] [--push URL] [--channels N]" >&2; exit 2; }
[ -f "$INPUT" ] || { echo "no such file: $INPUT" >&2; exit 2; }
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
    || { echo "ffmpeg/ffprobe not found in PATH" >&2; exit 2; }

# --- probe the track shape ------------------------------------------------
# stream order in the container is OBS track order; channels concatenate in
# that order (track 1 -> merged 1..8, track 2 -> merged 9..16, ...).
TRACK_CH=() ; TOTAL=0
while IFS= read -r ch; do
    TRACK_CH+=("$ch"); TOTAL=$((TOTAL + ch))
done < <(ffprobe -v error -select_streams a -show_entries stream=channels \
                 -of default=noprint_wrappers=1:nokey=1 "$INPUT")
NTRACKS=${#TRACK_CH[@]}
VCODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                 -of default=noprint_wrappers=1:nokey=1 "$INPUT" || true)

echo "input:  $INPUT"
echo "video:  ${VCODEC:-none}"
echo "audio:  $NTRACKS track(s), channels per track: ${TRACK_CH[*]:-none} (total $TOTAL)"

[ "$CHECK" -eq 1 ] && exit 0
[ "$NTRACKS" -ge 1 ] || { echo "no audio tracks - nothing to merge" >&2; exit 2; }

C="${CHANNELS:-$TOTAL}"
[ "$C" -le "$TOTAL" ] || { echo "--channels $C exceeds the $TOTAL channels present" >&2; exit 2; }

# --- choose the output layout --------------------------------------------
# pan does the 1:1 mapping AND the layout re-tag in one filter. A named
# layout only where AAC needs one; the PCM master stays unnamed on purpose.
case "$C" in
    16) NAMED=hexadecagonal ;;
    4)  NAMED=quad ;;
    *)  NAMED="" ;;
esac
if [ -n "$PUSH_URL" ] && [ -z "$NAMED" ]; then
    echo "--push needs an AAC-named layout: 4 or 16 channels (got $C)." >&2
    echo "2nd order (9 ch): zero-pad to 16 at the sender. 4th order (25 ch): the RTMP leg cannot carry it." >&2
    exit 2
fi

# amerge is the wrong tool for tagged tracks: it reorders channels
# SEMANTICALLY when the inputs carry named surround layouts (two 7.1 tracks
# come out grouped by speaker position, not concatenated) - measured, not
# theoretical. Two safe routes:
#   named target (16/4):  join with an explicit map - merged channel g IS
#     track t's channel o, positionally. join's map addresses output channels
#     by NAME, so the names are read from `ffmpeg -layouts` in layout order.
#   unnamed target:       strip each track to "<N>C" (capital C: count-only,
#     no semantics) so amerge has nothing to reorder, then trim/tag with pan.
PAN_LAYOUT="${NAMED:-${C}C}"
if [ "$NTRACKS" -gt 1 ] && [ -n "$NAMED" ]; then
    CH_NAMES=$(ffmpeg -hide_banner -layouts 2>/dev/null \
               | awk -v L="$NAMED" '$1==L {print $2}' | tr '+' ' ')
    read -r -a NAME_ARR <<< "$CH_NAMES"
    [ "${#NAME_ARR[@]}" -eq "$C" ] \
        || { echo "internal: layout $NAMED has ${#NAME_ARR[@]} channels, expected $C" >&2; exit 1; }
    MAP="" ; g=0 ; t=0
    for n in "${TRACK_CH[@]}"; do
        for o in $(seq 0 $((n - 1))); do
            [ "$g" -ge "$C" ] && break 2
            MAP="${MAP}${MAP:+|}${t}.${o}-${NAME_ARR[$g]}"
            g=$((g + 1))
        done
        t=$((t + 1))
    done
    LABELS=""
    for i in $(seq 0 $((NTRACKS - 1))); do LABELS="${LABELS}[0:a:${i}]"; done
    FILTER="${LABELS}join=inputs=${NTRACKS}:channel_layout=${NAMED}:map=${MAP}[a]"
elif [ "$NTRACKS" -gt 1 ]; then
    FILTER="" ; LABELS=""
    for i in $(seq 0 $((NTRACKS - 1))); do
        n=${TRACK_CH[$i]}
        STRIP="pan=${n}C"
        for j in $(seq 0 $((n - 1))); do STRIP="${STRIP}|c${j}=c${j}"; done
        FILTER="${FILTER}[0:a:${i}]${STRIP}[u${i}];"
        LABELS="${LABELS}[u${i}]"
    done
    PAN="pan=${C}C"
    for i in $(seq 0 $((C - 1))); do PAN="${PAN}|c${i}=c${i}"; done
    FILTER="${FILTER}${LABELS}amerge=inputs=${NTRACKS},${PAN}[a]"
else
    PAN="pan=${PAN_LAYOUT}"
    for i in $(seq 0 $((C - 1))); do PAN="${PAN}|c${i}=c${i}"; done
    FILTER="[0:a:0]${PAN}[a]"
fi

# --- run ------------------------------------------------------------------
if [ -n "$PUSH_URL" ]; then
    ABITRATE=$((96 * C))k   # 96 kbit/s per channel on the contribution leg
    LOOPARGS=()
    [ "$LOOP" -eq 1 ] && LOOPARGS=(-stream_loop -1)
    echo "pushing: $C ch AAC ($PAN_LAYOUT, PCE) @ $ABITRATE + copied video -> $PUSH_URL"
    exec ffmpeg -hide_banner -loglevel warning -stats -re "${LOOPARGS[@]}" -i "$INPUT" \
        -filter_complex "$FILTER" \
        -map 0:v:0? -map '[a]' \
        -c:v copy -c:a aac -b:a "$ABITRATE" \
        -f flv "$PUSH_URL"
else
    OUTPUT="${OUTPUT:-${INPUT%.*}-merged.mov}"
    echo "writing: $C ch PCM master ($PAN_LAYOUT) + copied video -> $OUTPUT"
    ffmpeg -hide_banner -loglevel warning -stats -y -i "$INPUT" \
        -filter_complex "$FILTER" \
        -map 0:v:0? -map '[a]' \
        -c:v copy -c:a pcm_s24le \
        "$OUTPUT"
    echo "result:"
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=channels,channel_layout,codec_name \
        -of default=noprint_wrappers=1 "$OUTPUT" | sed 's/^/  /'
fi
