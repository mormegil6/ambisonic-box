#!/usr/bin/env bash
# Encode a VOD master (video + 16-ch audio) into an 8-rung AV1 ABR ladder plus a
# single 16-channel Opus audio rendition, ready for scripts/package-vod-dash.sh.
#
# All rungs are 2:1 equirectangular. GOP = 2 s so the DASH packager
# cuts segments on keyframes. Audio is 16-ch Opus (mapping_family 255), NEVER
# downmixed.
#
# PRESET defaults to 4 because slower presets measured better on BOTH size and
# fidelity at every rung - not the usual trade. Full 120 s directions clip,
# SSIM against the source over a 30 s window.
#
# READ THESE AS RATIOS, NOT AS TARGETS. They were measured 2026-07-23
# against the then-current near-lossless master, a 593 MB AV1 CRF 18 encode
# carrying the OLD test card. That master was superseded on 2026-08-05 when
# ac85744 swapped make-directions-clip.sh to libsvtav1 CRF 28, and deleted on
# 2026-08-27 once the old card made it unusable. Today's ladder is cut from
# the 173 MB CRF 28 master, so absolute byte counts here no longer match what
# a run produces. The preset comparison they were taken for still holds.
#
# The live clips were cut at the default CRF below, with no override: PLAN's
# 2026-08-08 entry records the 8 rungs and the 8K preset floor and no CRF.
# A ladder found on the box at 3x these sizes was an earlier generation from
# the near-lossless master, not a different CRF policy.
#
#   7680x3840   p6 169.5 MB 25.419 dB  ->  p5 147.1 MB 25.974 dB   -13.2 %, +0.55 dB
#   5760x2880   p6 122.9 MB 25.749 dB  ->  p4 102.5 MB 26.255 dB   -16.6 %, +0.51 dB
#   3840x1920   p6  56.3 MB 24.777 dB  ->  p4  44.7 MB 25.122 dB   -20.5 %, +0.35 dB
#   1920x960    p6  19.8 MB 24.236 dB  ->  p4  16.6 MB 24.523 dB   -16.2 %, +0.29 dB
#
# Cost is 1.2-1.7x encode time. Fewer bytes on the top rung matter beyond
# bandwidth: the 8K rung is what pushed dash.js past the MSE buffer quota and
# forced the cap in the player fork.
#
# SVT-AV1 refuses 8K below a preset floor, and the floor MOVES between versions:
# v1.7 allows only M8 and faster, v4.2 allows M5 and faster. The rung fails
# outright rather than degrading. So each rung is attempted at PRESET, and on
# refusal the floor is read straight out of the error text
# ("8k+ resolution support is limited to M5 and faster presets") and retried
# there - which keeps the best preset each library actually permits instead of
# pinning to the oldest one's floor. current distro ffmpeg builds still ship SVT-AV1 v1.7, so
# this path is live, not theoretical.
#
# Measure again for other content, and full length: a 10 s excerpt of this same
# source once pointed the opposite way from the 120 s encode.
#
# LOOP_TO repeats a short master until the given number of seconds, which is how
# the `directions` clip is built: its master is exactly one 11.083 s loop of the
# spoken reads, and the delivered clip is 2 min of it. Looping happens at read
# time rather than by writing an intermediate, which for an 8K ProRes master
# would be tens of gigabytes. Video and audio are looped in separate ffmpeg runs,
# which is only safe because both streams are an exact whole number of samples
# long (266 frames at 24 fps, 532000 samples at 48 kHz - both exactly 11.083333 s),
# so the two never drift apart at the seams. Check that before reusing this on
# another master.
#
# CODEC=h264 ADDS THE SECOND LADDER, IT DOES NOT REPLACE THE FIRST. The AV1
# ladder is the primary one and stays the highest-priority AdaptationSet; the
# H.264 ladder exists because no iPhone below an A17 Pro decodes AV1 at all, and
# dash.js drops an AdaptationSet whose codec the device cannot handle, so an
# AV1-only manifest leaves those devices with no video track whatsoever. Rungs
# stop at 3840x1920 because phone H.264 decoders do, and the AV1 ladder keeps
# the 5760 and 7680 rungs for devices that can use them.
#
# The two branches encode differently on purpose. SVT-AV1 refuses some rungs
# below a preset floor and has to be retried per rung, so the AV1 branch runs
# one ffmpeg per rung. x264 has no such constraint, so the H.264 branch decodes
# the master ONCE and splits it to every rung in a single pass, which matters
# when the master is 8K AV1 and decoding it is the expensive half of the job.
#
# Usage: scripts/encode-vod-ladder.sh <master.(webm|mov|mp4)> <out-dir> [crf] [fps] [loop-to-seconds]
#   defaults: crf 30 (av1) / 21 (h264), fps 24, no looping
#   CODEC=av1 (default) | h264
set -euo pipefail
SRC="${1:?usage: encode-vod-ladder.sh <master> <out-dir> [crf] [fps] [loop-to-seconds]}"
OUT="${2:?output dir required}"
CODEC="${CODEC:-av1}"
case "$CODEC" in av1) CRF_DEFAULT=30 ;; h264) CRF_DEFAULT=21 ;; *) echo "CODEC must be av1 or h264" >&2; exit 1 ;; esac
CRF="${3:-$CRF_DEFAULT}"
# FPS IS READ FROM THE MASTER UNLESS GIVEN. It exists only to set the GOP, and
# the GOP is what makes the packager's 2 s segments land on keyframes: at 24 fps
# that is 48 frames, at 30 fps it is 60. Defaulting it to a constant meant a
# 30 fps master silently got a 1.6 s GOP, whereupon the segmenter cuts at the
# first keyframe at or after 2 s and emits 3.2 s segments instead. The clips in
# this project are 24 AND 30 fps, so the constant was a trap for whoever forgot
# which was which. An explicit argument still wins, for a master whose container
# lies about its rate.
FPS="${4:-auto}"
if [ "$FPS" = "auto" ]; then
    FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
              -of default=nw=1:nk=1 "$SRC" | awk -F/ '{ printf "%.0f", ($2 ? $1/$2 : $1) }')
    [ -n "$FPS" ] && [ "$FPS" -gt 0 ] 2>/dev/null || { echo "could not read frame rate from $SRC; pass it explicitly" >&2; exit 1; }
    echo "frame rate read from master: ${FPS} fps"
fi
LOOP_TO="${5:-0}"
PRESET="${PRESET:-4}"          # SVT-AV1 preset; rungs the library refuses fall
                               # back to the floor it names (see the loop below)
mkdir -p "$OUT"
GOP=$(( FPS * 2 ))

LOOP_IN=(); LOOP_OUT=()
if [ "$LOOP_TO" != "0" ]; then
  LOOP_IN=(-stream_loop -1); LOOP_OUT=(-t "$LOOP_TO")
  echo "looping ${SRC##*/} to ${LOOP_TO}s"
fi

encode_rung () {   # W H preset outfile errfile
  ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
    -an -map 0:v:0 -vf "scale=${1}:${2}:flags=lanczos" \
    -c:v libsvtav1 -preset "$3" -crf "$CRF" -g "$GOP" -pix_fmt yuv420p \
    "${LOOP_OUT[@]}" "$4" 2>"$5"
}

rungs=("7680 3840" "5760 2880" "3840 1920" "2880 1440" "1920 960" "1440 720" "1080 540" "720 360")
err=$(mktemp); trap 'rm -f "$err"' EXIT

if [ "$CODEC" = "h264" ]; then
  # One decode, every rung. Named h_ rather than v_ so both ladders can live in
  # one directory and one package run: the packager keys AdaptationSets off the
  # codec it finds, and the manifest post-step keys selectionPriority off these
  # names.
  h_rungs=("3840 1920" "2880 1440" "1920 960" "1440 720" "1080 540" "720 360")
  n=${#h_rungs[@]}
  fc="[0:v]split=${n}"; i=0
  for r in "${h_rungs[@]}"; do fc="${fc}[s$i]"; i=$((i+1)); done
  fc="${fc};"
  i=0
  for r in "${h_rungs[@]}"; do
    set -- $r
    fc="${fc}[s$i]scale=$1:$2:flags=lanczos[v$i];"
    i=$((i+1))
  done
  fc="${fc%;}"
  outs=(); i=0
  for r in "${h_rungs[@]}"; do
    set -- $r
    # High profile: the baseline every iOS device since the 4S decodes in
    # hardware. No explicit -level: x264 computes the lowest one that fits, and
    # forcing a level only risks declaring a stream the device then refuses.
    # Closed GOP with scenecut off so every rung cuts keyframes at the same
    # frames, which is what lets the segmenter emit aligned 2 s segments.
    outs+=(-map "[v$i]" -c:v libx264 -preset slow -crf "$CRF" -profile:v high
           -pix_fmt yuv420p -g "$GOP" -keyint_min "$GOP" -sc_threshold 0
           "${LOOP_OUT[@]}" "$OUT/h_$1x$2.mp4")
    i=$((i+1))
  done
  echo ">>> H.264 ladder, ${n} rungs, one decode pass (crf $CRF gop $GOP)"
  ffmpeg -y -hide_banner -loglevel error -stats "${LOOP_IN[@]}" -i "$SRC" \
    -an -filter_complex "$fc" "${outs[@]}"
  echo "H.264 ladder written to $OUT"; ls -lh "$OUT"/h_*.mp4
  # Audio belongs to the AV1 run: it is one 16-channel Opus rendition shared by
  # both ladders, and re-encoding it here would only produce a second identical
  # file under the same name.
  exit 0
fi

for r in "${rungs[@]}"; do
  set -- $r; W=$1; H=$2; name="v_${W}x${H}"
  echo ">>> $name (crf $CRF preset $PRESET gop $GOP)"
  if ! encode_rung "$W" "$H" "$PRESET" "$OUT/${name}.mp4" "$err"; then
    # SVT-AV1 refuses 8K below a preset floor and fails the rung outright:
    #   Svt[error]: 8k+ resolution support is limited to M5 and faster presets.
    # The floor differs by version (M8 on v1.7, M5 on v4.2), so read it out of
    # the message rather than hard-coding either one. Anything else is a real
    # error and must not be retried.
    floor=$(grep -oiE "limited to M[0-9]+" "$err" | grep -oE "[0-9]+" | head -1)
    if [ -n "$floor" ]; then
      echo "    SVT-AV1 on this build refuses ${W}x${H} below M${floor}; retrying at preset ${floor}"
      encode_rung "$W" "$H" "$floor" "$OUT/${name}.mp4" "$err" || { cat "$err" >&2; exit 1; }
    else
      cat "$err" >&2; exit 1
    fi
  fi
done

echo ">>> audio 16-ch Opus"
ffmpeg -y -hide_banner -loglevel error "${LOOP_IN[@]}" -i "$SRC" \
  -vn -map 0:a:0 -c:a libopus -mapping_family 255 -b:a 1024k \
  "${LOOP_OUT[@]}" "$OUT/audio_16ch.webm"

echo "ladder written to $OUT"; ls -lh "$OUT"
