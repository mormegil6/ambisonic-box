#!/bin/bash
# The five DASH test clips, one directory each (fx-<name>/), differing only in the video track's edit list.
# Flash and beep present together, at 2.7 + 4k s (2.7193 + 4k s in `live`). The beep is a 1 kHz tone, 0.5 s long, on
# channel 1 of 16 (the other 15 stay silent); the flash is a full white frame, 0.5 s long, on black.
#
#   nob    no B-frames, so an edit list with one entry that trims nothing. The reference.
#   ctrl   x264 default (B-frames): ffmpeg writes a 67 ms trimming edit, as it does on every live stream.
#   trim   one 0.5 s trimming edit and no empty edit (the shape the 1.3.13 player mishandled). The flash is encoded
#          0.5 s later so that it presents at 2.7 s once the trim is applied.
#   live   the live stream's list: an empty edit of 53 ms, then the 67 ms trim (1029 track units). A flash can only
#          start on a frame, so it is encoded on frame 82 (2.7333 s) and presents at 2.7333 - 1029/15360 + 0.053 =
#          2.7193 s. The beep, which can start on any sample, is placed there too.
#   elst   a 1.7 s empty edit, then the 67 ms trim. The flash is encoded 1.7 s earlier.
#
# Both signals are built so that they start exactly where asked. The beep comes from aevalsrc, which is evaluated per
# sample (a volume filter with eval=frame starts it on a 1024-sample frame, 9 or 20 ms late). Both expressions add
# 1e-6 s before comparing, because t - start is not exact in floating point and mod() then misses a slot by one frame
# (the third flash, at 10.7 s, started at 10.733 s without it).
#
# Needs ffmpeg with libx264 and libopus, and python3. Edit lists are written with set-elst.py (durations in movie
# units of 1/1000 s, media times in track units of 1/15360 s; -1 is an empty edit).
set -euo pipefail
cd "$(dirname "$0")" || exit 1
mk() { # name flashStart beepStart [x264 args]
  local name=$1 v0=$2 b0=$3 xargs=${4:-}
  rm -rf "fx-$name"; mkdir "fx-$name"
  # shellcheck disable=SC2086 # $xargs is a list of x264 options and must split
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=960x480:r=30,format=yuv420p,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(t+0.000001,$v0)*lt(mod(t-$v0+0.000001,4),0.5)'" \
    -f lavfi -i "aevalsrc='sin(2*PI*1000*t)*gte(t+0.000001,$b0)*lt(mod(t-$b0+0.000001,4),0.5)':s=48000,pan=16c|c0=c0" \
    -t 44 -map 0:v -map 1:a \
    -c:v libx264 $xargs -preset veryfast -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p \
    -c:a libopus -mapping_family 255 -b:a 1536k \
    -f dash -seg_duration 2 -dash_segment_type mp4 -use_template 1 -use_timeline 1 \
    -adaptation_sets "id=0,streams=0 id=1,streams=1" "fx-$name/vod.mpd"
}
setlist() { # name "dur:media_time,..."
  mv "fx-$1/init-stream0.m4s" "fx-$1/init-stream0.orig.m4s"
  python3 set-elst.py "fx-$1/init-stream0.orig.m4s" "fx-$1/init-stream0.m4s" "$2" > /dev/null
  rm "fx-$1/init-stream0.orig.m4s"
}
mk nob  2.7 2.7 "-bf 0"
mk ctrl 2.7 2.7
mk trim 3.2 2.7 "-bf 0"
setlist trim "0:7680"
mk live 2.733333 2.719341 "-bf 0"
setlist live "53:-1,0:1029"
mk elst 1.0 2.7
setlist elst "1700:-1,0:1024"
ls -d fx-*
