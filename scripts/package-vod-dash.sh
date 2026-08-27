#!/usr/bin/env bash
# Package an AV1 ABR ladder (from scripts/encode-vod-ladder.sh) into on-demand
# MPEG-DASH with Shaka Packager. Runs Shaka via docker (the compose `shaka`
# service mounts ./content read-only, so this uses a plain writable `docker run`).
#
# The 16-channel Opus audio's <AudioChannelConfiguration value="16"/> survives
# into the manifest (verify: grep AudioChannelConfiguration <mpd>).
#
# Usage: scripts/package-vod-dash.sh <ladder-dir> <dash-out-dir> [mpd-basename]
#   <ladder-dir> and <dash-out-dir> must share a parent (mounted at /content).
set -euo pipefail
LADDER="$(cd "${1:?ladder dir}" && pwd)"
DASHARG="${2:?dash out dir}"
MPD="${3:-vod}.mpd"
mkdir -p "$DASHARG"
DASH="$(cd "$DASHARG" && pwd)"

ROOT="$(cd "$LADDER/.." && pwd)"
case "$DASH" in "$ROOT"/*) ;; *) echo "ERROR: ladder and dash dirs must share a parent" >&2; exit 1;; esac
lrel="${LADDER#"$ROOT"/}"; drel="${DASH#"$ROOT"/}"

args=""
for f in "$LADDER"/v_*.mp4; do
  b="$(basename "$f")"; n="${b%.mp4}"
  args="$args in=/content/$lrel/$b,stream=video"
  args="$args,init_segment=/content/$drel/${n}_init.m4s"
  args="$args,segment_template=/content/$drel/${n}_\$Number\$.m4s"
done
# SEGMENTED AND fMP4, both load-bearing, and neither is free to change alone.
#
# Safari cannot let dash.js carry this audio at all: its CapabilitiesFilter
# drops the 16-channel Opus set, so the player fetches and decodes it itself.
# That self-fetch addresses segments through a SegmentTemplate, which a
# single-file on-demand package does not have; packaged that way the clips
# played nowhere in Safari. Video is templated too because Shaka refuses a
# mixed descriptor set ("segment_template should be specified for none or all
# stream descriptors"), not because anything needed it.
#
# The container is fMP4 rather than WebM because the output extension is what
# Shaka reads it from, and .webm here against .mp4 for video made every clip
# manifest mixed-container, which this project forbids.
args="$args in=/content/$lrel/audio_16ch.webm,stream=audio"
args="$args,init_segment=/content/$drel/audio_init.m4s"
args="$args,segment_template=/content/$drel/audio_\$Number\$.m4s"

# PATCHED PACKAGER, NOT THE OFFICIAL IMAGE. Shaka writes the Opus dOps box
# little-endian, so a stock build produces audio Chromium's MSE refuses:
# InputSampleRate 48000 comes out as 2159738880. Reported as
# shaka-packager#1627, unfixed in every release including v3.9.3. Build the
# image from ambisonic-box-deployment/shaka-dops-fix, and go back to the
# official one the moment a release carries the fix.
#
# --user: Shaka runs as root in its container, so without this every output
# lands root-owned in the bind mount, which nginx and rclone both trip over.
#
# --generate_static_live_mpd: a segment template otherwise produces
# type="dynamic" with a minimumUpdatePeriod and no duration, and dash.js then
# plays a 120 s clip as a live stream, starting it near the live edge about
# 90 s in.
docker run --rm --user "$(id -u):$(id -g)" -v "$ROOT":/content shaka-packager:dops-fix packager \
  $args --segment_duration 2 --generate_static_live_mpd --mpd_output "/content/$drel/$MPD"

echo "packaged: $DASH/$MPD"; ls -lh "$DASH"

# Caption sidecars, if the clip has any. These are NOT packaged into the MPD
# (side-loaded native text tracks are used deliberately),
# so nothing else copies them, and a repackage into an existing directory
# would otherwise leave the PREVIOUS clip's captions in place. That is exactly
# what happened on the 2026-08-05 six-direction rebuild: the manifest and every
# rendition were new, the captions still said front/right/left/top.
CLIP_BASE="$(basename "$DASH")"
for _vtt in "$(dirname "$LADDER")"/masters/*"${CLIP_BASE}"*_captions_*.vtt; do
    [ -e "$_vtt" ] || continue
    _lang="${_vtt##*_captions_}"; _lang="${_lang%.vtt}"
    cp "$_vtt" "$DASH/captions_${_lang}.vtt"
    echo "  captions: $(basename "$_vtt") -> captions_${_lang}.vtt"
done
