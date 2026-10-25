#!/usr/bin/env bash
# Peak level of an ambisonic clip as the player plays it on headphones: the
# HOAST360 binaural decoder at the player's default volume, with the sound
# field turned to eight headings. That is the level that clips, not the level
# of any one channel: the directions master of 2026-08-08 peaks at -1.8 dBFS in
# W, yet reaches +5.3 dBFS on headphones facing 90 degrees, and the browser
# clips everything above 0.
#
# The decoder is rebuilt here from the player's own filters (hoast360/irs/):
# one FIR per ambisonic channel, the channels with m >= 0 summed into mid and
# the rest into side, left = mid + side and right = mid - side, as in
# hoast360/dependencies/HoastBinauralDecoder.js. Headings are a turn of the
# sound field about the vertical axis; tilting the view moves the peak by a few
# tenths of a dB on the directions clip, so the headings stand in for all views.
# On that master it agrees with a separate numpy model of the player's audio
# graph to within 0.05 dB at every heading.
#
# Usage: scripts/binaural-peak.sh CLIP
#   CLIP: any file ffmpeg reads whose first audio stream is ACN ambisonics of
#   order 1 to 4 (4, 9, 16 or 25 channels)
# Prints the peak per heading and the worst, in dBFS. Exits 1 if the worst is
# above 0 dBFS, i.e. if the clip would clip on headphones, and 2 if it cannot
# measure: no such file, no ambisonic audio, no filters for the order, an
# ffmpeg older than 7.0 (whose afir has no irnorm), or an ffmpeg error.
set -euo pipefail
# ffmpeg and python print a decimal point whatever the locale; bash's printf
# reads numbers the locale's way and rejects them under a comma locale
export LC_ALL=C

[ $# -eq 1 ] || { echo "usage: scripts/binaural-peak.sh CLIP" >&2; exit 2; }
CLIP=$1
IRDIR="$(cd "$(dirname "$0")/.." && pwd)/hoast360/irs"
[ -f "$CLIP" ] || { echo "missing: $CLIP" >&2; exit 2; }

CH=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$CLIP") || CH=
case "$CH" in ''|*[!0-9]*) echo "$CLIP: no audio stream ffprobe can read" >&2; exit 2 ;; esac
ORDER=$(python3 -c "import math; n = math.isqrt($CH); print(n - 1 if n * n == $CH and 2 <= n <= 5 else '')")
[ -n "$ORDER" ] || { echo "$CLIP: $CH channels is not an ambisonic order from 1 to 4" >&2; exit 2; }

IRS=()
for f in "$IRDIR"/hoast_o"${ORDER}"_*ch.wav; do [ -f "$f" ] && IRS+=("$f"); done
[ "${#IRS[@]}" -gt 0 ] || { echo "no decoder filters for order $ORDER in $IRDIR" >&2; exit 2; }
ffmpeg -hide_banner -h filter=afir 2>/dev/null | grep -q irnorm \
    || { echo "needs FFmpeg 7.0 or later: this ffmpeg's afir has no irnorm option" >&2; exit 2; }

# the filter graph for one heading: turn the field, filter each channel with its
# FIR, sum to mid and side, and measure. Every channel is taken out as a mono
# stream by index before it meets its filter, because afir pairs a multichannel
# input with a multichannel filter set by channel NAME when their layouts
# differ: with a 16-channel layout on one side and 9.1.6 on the other, channel
# 12 was filtered with filter 10.
graph () {
    python3 - "$CH" "${#IRS[@]}" "$1" <<'EOF'
import math, sys
ch, nirs, yaw = int(sys.argv[1]), int(sys.argv[2]), math.radians(float(sys.argv[3]))
order = math.isqrt(ch) - 1
# a yaw turn mixes each degree's cos (m > 0) and sin (m < 0) pair by m times the angle
coef = {i: [(i, 1.0)] for i in range(ch)}
for n in range(1, order + 1):
    for m in range(1, n + 1):
        c, s = n * n + n + m, n * n + n - m
        cm, sm = math.cos(m * yaw), math.sin(m * yaw)
        coef[c] = [(c, cm), (s, -sm)]
        coef[s] = [(c, sm), (s, cm)]
def term(pairs):
    return '+'.join(f'{g:.9f}*c{k}' for k, g in pairs).replace('+-', '-')
mid = [i for i in range(ch) if i - math.isqrt(i) ** 2 - math.isqrt(i) >= 0]
side = [i for i in range(ch) if i not in mid]
irs = ''.join(f'[{k + 1}:a]' for k in range(nirs))
g = [f'[0:a:0]aresample=48000,asplit={ch}' + ''.join(f'[a{i}]' for i in range(ch)),
     f'{irs}amerge=inputs={nirs},aresample=48000,asplit={ch}' + ''.join(f'[h{i}]' for i in range(ch))]
for i in range(ch):
    g.append(f'[a{i}]pan=mono|c0={term(coef[i])}[r{i}]')
    g.append(f'[h{i}]pan=mono|c0=c{i}[f{i}]')
    g.append(f'[r{i}][f{i}]afir=irnorm=-1[y{i}]')
for name, idx in (('mid', mid), ('side', side)):
    g.append(''.join(f'[y{i}]' for i in idx) + f'amix=inputs={len(idx)}:normalize=0[{name}]')
g.append('[mid][side]join=inputs=2:channel_layout=stereo,pan=stereo|c0=c0+c1|c1=c0-c1,'
         'astats=measure_perchannel=none:measure_overall=Peak_level[out]')
print(';'.join(g))
EOF
}

INPUTS=()
for f in "${IRS[@]}"; do INPUTS+=(-i "$f"); done
worst=""
for yaw in 0 45 90 135 180 225 270 315; do
    # astats, not volumedetect: volumedetect measures in 16-bit and so never
    # reports anything above 0 dBFS, which is the whole question here
    log=$(ffmpeg -nostdin -hide_banner -nostats -i "$CLIP" "${INPUTS[@]}" -filter_complex "$(graph "$yaw")" \
              -map '[out]' -f null - 2>&1) \
        || { printf '%s\n' "$log" | tail -5 >&2; echo "ffmpeg failed at heading $yaw" >&2; exit 2; }
    # a number, or -inf for digital silence
    peak=$(printf '%s\n' "$log" | sed -n 's/.*Peak level dB: //p' | tail -1)
    [ -n "$peak" ] || { echo "ffmpeg reported no peak at heading $yaw" >&2; exit 2; }
    printf 'heading %3s deg: %5.1f dBFS\n' "$yaw" "$peak"
    worst=$(python3 -c "print(max(float('$peak'), float('${worst:-$peak}')))")
done
printf 'worst: %.1f dBFS on headphones (order %s)\n' "$worst" "$ORDER"
python3 -c "import sys; sys.exit(1 if float('$worst') > 0 else 0)" \
    || { echo "above 0 dBFS: this clip clips on headphones" >&2; exit 1; }
