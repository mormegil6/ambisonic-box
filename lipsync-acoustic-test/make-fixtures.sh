#!/bin/bash
# The five DASH test clips, one directory each (fx-<name>/), differing only in the video track's edit list.
# Flash and beep are both intended to present at 2.7 + 4k s. The beep is a 1 kHz tone, 0.5 s long, on channel 1 of 16
# (the other 15 stay silent); the flash is a full white frame, 0.5 s long, on black.
#
#   nob    no B-frames, so an edit list with one entry that trims nothing. The reference.
#   ctrl   x264 default (B-frames): ffmpeg writes a 67 ms trimming edit, as it does on every live stream.
#   trim   one 0.5 s trimming edit and no empty edit (the shape the 1.3.13 player mishandled). The flash is encoded
#          0.5 s later so that it presents at 2.7 s once the trim is applied.
#   live   the live stream's list: an empty edit of 53 ms, then the 67 ms trim. The flash is asked for 14 ms later
#          (2.714 s), which is not on the 30 fps grid: it starts on the next frame, 2.733 s, and so presents at
#          2.719 s, 19 ms after the beep. Read this clip against -19 ms.
#   elst   a 1.7 s empty edit, then the 67 ms trim. The flash is encoded 1.7 s earlier.
#
# Needs ffmpeg with libx264 and libopus, and python3. Edit lists are written with set-elst.py (durations in movie
# units of 1/1000 s, media times in track units of 1/15360 s; -1 is an empty edit).
set -euo pipefail
cd "$(dirname "$0")" || exit 1
mk() { # name flashStart [x264 args]
  local name=$1 v0=$2 xargs=${3:-}
  rm -rf "fx-$name"; mkdir "fx-$name"
  # shellcheck disable=SC2086 # $xargs is a list of x264 options and must split
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=960x480:r=30,format=yuv420p,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(t,$v0)*lt(mod(t-$v0,4),0.5)'" \
    -f lavfi -i "sine=f=1000:r=48000,volume='gte(t,2.7)*lt(mod(t-2.7,4),0.5)':eval=frame,pan=16c|c0=c0" \
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
mk nob  2.7 "-bf 0"
mk ctrl 2.7
mk trim 3.2 "-bf 0"
setlist trim "0:7680"
mk live 2.714 "-bf 0"
setlist live "53:-1,0:1029"
mk elst 1.0
setlist elst "1700:-1,0:1024"
ls -d fx-*
