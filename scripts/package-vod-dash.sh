#!/usr/bin/env bash
# Package the ABR ladders (from scripts/encode-vod-ladder.sh) into on-demand
# MPEG-DASH with Shaka Packager. Runs Shaka via docker (the compose `shaka`
# service mounts ./content read-only, so this uses a plain writable `docker run`).
#
# BOTH LADDERS GO INTO ONE MANIFEST: v_*.mp4 is the AV1 ladder, h_*.mp4 the
# H.264 one, and Shaka puts them in separate AdaptationSets because their codecs
# differ. That is the whole point. No iPhone below an A17 Pro decodes AV1, and
# dash.js removes an AdaptationSet the device cannot decode, so an AV1-only
# manifest leaves those devices with no video track at all. With both present
# the same filter picks the ladder the device can actually play.
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

# The packager is built here, not pulled, because the official image writes a
# malformed Opus dOps box (see below). Say so plainly if it is missing: docker's
# own "image not found" sends people looking for a typo or a registry outage.
if ! docker image inspect ambi-box-shaka:local >/dev/null 2>&1; then
    cat >&2 <<'MSG'
ERROR: the image ambi-box-shaka:local is not built.

  docker compose --profile tools build shaka

This project builds Shaka Packager rather than pulling it, because the official
image writes the Opus dOps box little-endian and Chromium's MSE then refuses the
audio it produces. See services/shaka/README.md and
https://github.com/shaka-project/shaka-packager/issues/1627
MSG
    exit 1
fi

args=""
have_h264=0
for f in "$LADDER"/v_*.mp4 "$LADDER"/h_*.mp4; do
  [ -e "$f" ] || continue          # h_* is optional; a clip may be AV1 only
  b="$(basename "$f")"; n="${b%.mp4}"
  case "$b" in h_*) have_h264=1 ;; esac
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
# shaka-packager#1627, unfixed in every release including v3.9.3. Build it with
# `docker compose --profile tools build shaka` (see services/shaka/README.md),
# and go back to the official image the moment a release carries the fix.
#
# --user: Shaka runs as root in its container, so without this every output
# lands root-owned in the bind mount, which nginx and rclone both trip over.
#
# --generate_static_live_mpd: a segment template otherwise produces
# type="dynamic" with a minimumUpdatePeriod and no duration, and dash.js then
# plays a 120 s clip as a live stream, starting it near the live edge about
# 90 s in.
docker run --rm --user "$(id -u):$(id -g)" -v "$ROOT":/content ambi-box-shaka:local packager \
  $args --segment_duration 2 --generate_static_live_mpd --mpd_output "/content/$drel/$MPD"

# selectionPriority, WITHOUT WHICH THE SECOND LADDER IS A DOWNGRADE. Shaka has
# no flag for the attribute, so it is written here. dash.js defaults
# selectionModeForInitialTrack to highestSelectionPriority and reads this off
# the AdaptationSet, defaulting to 1 when absent; with both ladders at the
# default it picked avc1 over av01, which would have silently dropped every
# AV1-capable device from the 8K rungs to the 4K H.264 ones. Marking AV1 as 2
# keeps those devices where they were, while a device that cannot decode AV1
# never sees that set at all because the capability filter removed it first.
if [ "$have_h264" = "1" ]; then
  python3 - "$DASH/$MPD" <<'PYMPD'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# Decide per AdaptationSet block, by the codecs of the Representations inside
# it: Shaka writes codecs on the Representation, not on the set.
out, pos, written = [], 0, 0
for m in re.finditer(r'<AdaptationSet[^>]*>.*?</AdaptationSet>', s, re.S):
    block = m.group(0)
    out.append(s[pos:m.start()])
    if 'contentType="video"' in block or 'mimeType="video/' in block:
        val = '2' if 'codecs="av01' in block else '1'
        block, n = re.subn(r'<AdaptationSet', '<AdaptationSet selectionPriority="' + val + '"', block, count=1)
        written += n
    out.append(block)
    pos = m.end()
out.append(s[pos:])
if written < 2:
    # Never report success without checking. An earlier version of this step
    # printed a confident message while a corrupted pattern matched nothing,
    # which would have shipped a manifest where dash.js picks avc1 over av01 and
    # every AV1-capable device silently loses the 8K rungs.
    sys.exit('ERROR: expected 2 video AdaptationSets to mark, marked %d' % written)
open(p, 'w', encoding='utf-8').write(''.join(out))
print('  selectionPriority written: av01=2, avc1=1 (%d sets marked)' % written)
PYMPD
fi

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
