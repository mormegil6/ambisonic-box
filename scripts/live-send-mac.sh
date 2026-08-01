#!/usr/bin/env bash
# True-live sender: a real capture device (OBS Virtual Camera, or any camera/
# capture card) plus a multichannel audio device (BlackHole) as ONE
# avfoundation input, so video and audio share a single capture-session
# clock instead of two independently-paced ffmpeg pipelines racing apart.
#
# Why this exists, and why the obvious two-input version failed (2026-07-31):
# a synthetic lavfi video source paced with -re alongside a live avfoundation
# audio capture has NO shared clock - the two drift apart without bound
# (measured: video fell 82s behind and still climbing within two minutes),
# and the segmenter never sees a coherent frame. Two devices captured through
# ONE avfoundation input ("video:audio") share the OS capture session's clock
# and do not exhibit this.
#
# Also: video segment duration MUST stay locked to the stack's 2s grid
# (README: keyframe interval divides segment duration, equality preferred).
# earshot runs -c:v copy by default, so THIS sender's GOP is what actually
# determines live segment cut points. Get it wrong (the first version of
# this experiment used an undisciplined frame rate and produced 6s video
# segments against ~4.8s audio) and the player never advances, with no
# error anywhere to point at why.
#
# Usage:
#   live-send-mac.sh <video-device> <audio-device> rtmp://<host>:1935/live/<key> \
#       [--channels N] [--fps N]
#
#   <video-device>/<audio-device>  avfoundation device names, e.g.
#       "OBS Virtual Camera" "BlackHole 64ch" - see what's available:
#       ffmpeg -f avfoundation -list_devices true -i ""
#   --channels N   audio channels to keep, positionally from the device's
#                  first N (default 16). Must be 4 or 16 (AAC named layout,
#                  same rule as merge-obs-tracks.sh and the rest of the stack).
#   --fps N        output frame rate, default 30. -g is fixed at 2*fps so
#                  segments land on the stack's 2s grid; the OUTPUT is forced
#                  to constant frame rate at this value regardless of what
#                  the capture device natively delivers, so the GOP's frame
#                  count is a true 2 seconds of wall clock.
#
# Exit codes: 0 clean stop (ctrl-C), 1 ffmpeg error, 2 bad invocation.

set -euo pipefail

CHANNELS=16 FPS=30
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --channels) CHANNELS="${2:?--channels needs a number}"; shift ;;
        --fps)      FPS="${2:?--fps needs a number}"; shift ;;
        -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "unknown option: $1" >&2; exit 2 ;;
        *)          POSITIONAL+=("$1") ;;
    esac
    shift
done
set -- "${POSITIONAL[@]}"
[ $# -eq 3 ] || { echo "usage: $0 <video-device> <audio-device> rtmp://<host>:1935/live/<key> [--channels N] [--fps N]" >&2; exit 2; }
VIDEO_DEV="$1" AUDIO_DEV="$2" PUSH_URL="$3"

case "$CHANNELS" in
    16) NAMED=hexadecagonal ;;
    4)  NAMED=quad ;;
    *)  echo "--channels must be 4 or 16 (AAC named layout requirement)" >&2; exit 2 ;;
esac

GOP=$((FPS * 2))   # 2s segments, per the stack's segment-duration/GOP rule
ABITRATE=$((96 * CHANNELS))k

PAN="pan=${NAMED}"
for i in $(seq 0 $((CHANNELS - 1))); do PAN="${PAN}|c${i}=c${i}"; done

echo "video:  $VIDEO_DEV"
echo "audio:  $AUDIO_DEV -> first $CHANNELS ch ($NAMED)"
echo "fps: $FPS (forced CFR), GOP: $GOP frames (2s), audio: AAC $ABITRATE PCE"
echo "-> $PUSH_URL"

exec ffmpeg -hide_banner -loglevel warning -stats \
    -f avfoundation -i "${VIDEO_DEV}:${AUDIO_DEV}" \
    -filter_complex "[0:a]${PAN}[a]" \
    -map 0:v -map "[a]" \
    -r "$FPS" -fps_mode cfr -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 \
    -c:a aac -b:a "$ABITRATE" \
    -f flv "$PUSH_URL"
