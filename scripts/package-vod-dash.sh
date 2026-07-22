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
  b="$(basename "$f")"
  args="$args in=/content/$lrel/$b,stream=video,output=/content/$drel/$b"
done
args="$args in=/content/$lrel/audio_16ch.webm,stream=audio,output=/content/$drel/audio_16ch.webm"

docker run --rm -v "$ROOT":/content google/shaka-packager:v3.7.2 packager \
  $args --mpd_output "/content/$drel/$MPD"

echo "packaged: $DASH/$MPD"; ls -lh "$DASH"
