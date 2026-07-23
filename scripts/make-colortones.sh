#!/usr/bin/env bash
# Generate the "colortones" A/V-sync test pattern (matches the original
# colortones_4k_16ch.mp4 design, reverse-engineered from that file).
#
# A 2:1 equirectangular frame with a persistent centre crosshair (front/horizon
# marker). On a black baseline, every SLOT seconds a FLASH-second full-frame
# colour flash appears, each colour PAIRED with a distinct tone (beep) on
# channel 1. The colour<->tone pairing is the point: if audio lags video you see
# flash N while hearing beep N-1, and because every pair is unique the delay is
# unambiguous. The 10-colour spectral cycle (red..gray) with a 100 Hz tone
# staircase (300..1200 Hz) repeats to fill MINUTES.
#
# Original timing: 0.5 s flash every 4 s (10 markers, 40 s cycle). With a 40 s
# cycle, whole-minute totals are the EVEN minutes (2, 4, 6 ...); MINUTES=2 is
# the default (3 cycles). Audio is 16-channel (Opus, mapping_family 255): beep
# on channel 1, channels 2-16 silent but PRESERVED (never downmixed). This
# SCRIPT is the reproducible master.
#
# Usage: scripts/make-colortones.sh [--captions-only] [out.webm] [WIDTH] [HEIGHT] [MINUTES(even)] [LEAD_s]
#   defaults: content/vod/masters/colortones_8k360_16ch.webm 7680 3840 2 1
#   --captions-only re-emits just the .vtt sidecars and skips the (slow) encode
set -euo pipefail

CAPTIONS_ONLY=0
if [ "${1:-}" = "--captions-only" ]; then CAPTIONS_ONLY=1; shift; fi

OUT="${1:-content/vod/masters/colortones_8k360_16ch.webm}"
W="${2:-7680}"; H="${3:-3840}"; MIN="${4:-2}"; LEAD="${5:-1}"
FPS=30
SLOT=4                       # seconds per colour marker (original cadence)
FLASH="0.5"                  # flash/beep length; rest of the slot is black/silent
GAP="3.5"                    # SLOT - FLASH
LINE=$(( W / 960 ))          # crosshair thickness (~8 px @ 8K)
GOP=$(( FPS * 2 ))

# index-matched colour <-> beep-frequency (Hz), spectral order, 100 Hz staircase
colors=(red  orange yellow green cyan blue blueviolet magenta white gray)
freqs=( 300  400    500    600   700  800  900        1000    1100  1200)
N=${#colors[@]}
CYCLE=$(( N * SLOT ))                     # 40 s
if [ $(( MIN * 60 % CYCLE )) -ne 0 ]; then
  echo "ERROR: ${CYCLE}s cycle does not divide ${MIN} min. Use an even MINUTES (2,4,6...)." >&2
  exit 1
fi
LOOPS=$(( MIN * 60 / CYCLE ))

# build per-slot video (flash then black) and audio (beep then silence) segments
vfc=""; afc=""; vlab=""; alab=""; k=0
# LEAD s of black + silence so the clip opens on the bare crosshair, never
# mid-flash. An equal LEAD s is trimmed off the trailing gap (-t below), so the
# total stays a clean MIN*60 s AND the loop seam is rhythmically continuous: the
# trailing gap plus the next loop's lead add up to exactly one inter-slot gap.
# (Requires LEAD <= GAP so the trim only eats black, never a flash.)
if [ "$LEAD" != "0" ]; then
  vfc+="color=c=black:s=${W}x${H}:r=${FPS}:d=${LEAD},format=yuv420p[v${k}];"
  afc+="aevalsrc=0:s=48000:d=${LEAD}[a${k}];"
  vlab+="[v${k}]"; alab+="[a${k}]"; k=$((k+1))
fi
for ((l=0; l<LOOPS; l++)); do
  for ((i=0; i<N; i++)); do
    vfc+="color=c=${colors[$i]}:s=${W}x${H}:r=${FPS}:d=${FLASH},format=yuv420p[v${k}];"
    afc+="sine=frequency=${freqs[$i]}:sample_rate=48000:duration=${FLASH}[a${k}];"
    vlab+="[v${k}]"; alab+="[a${k}]"; k=$((k+1))
    vfc+="color=c=black:s=${W}x${H}:r=${FPS}:d=${GAP},format=yuv420p[v${k}];"
    afc+="aevalsrc=0:s=48000:d=${GAP}[a${k}];"
    vlab+="[v${k}]"; alab+="[a${k}]"; k=$((k+1))
  done
done

fc="${vfc}${afc}"
fc+="${vlab}concat=n=${k}:v=1:a=0,"
fc+="drawbox=x=(iw-${LINE})/2:y=0:w=${LINE}:h=ih:color=white@0.85:t=fill,"
fc+="drawbox=x=0:y=(ih-${LINE})/2:w=iw:h=${LINE}:color=white@0.85:t=fill[vout];"
fc+="${alab}concat=n=${k}:v=0:a=1,pan=hexadecagonal|c0=c0[aout]"

echo "colortones: ${W}x${H} ${FPS}fps  ${LEAD}s lead, clean ${MIN} min total (${LOOPS}x ${CYCLE}s cycle, tail trimmed by ${LEAD}s; ${N} colour+tone pairs 300-1200Hz)"
if [ "$CAPTIONS_ONLY" -eq 0 ]; then
  ffmpeg -y -hide_banner -filter_complex "$fc" \
    -map "[vout]" -map "[aout]" \
    -t $(( MIN * 60 )) \
    -c:v libsvtav1 -preset 8 -crf 12 -g "${GOP}" -pix_fmt yuv420p \
    -c:a libopus -mapping_family 255 -b:a 256k \
    "$OUT"

  echo "wrote $OUT"
  ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,channels \
    -show_entries format=duration -of default=noprint_wrappers=1 "$OUT"
fi

# Caption sidecars, built from the same colour<->tone table and cadence as the
# video above, so every cue lands exactly on its flash and names the pair you
# should be hearing. Like the master, these are NOT tracked in git - they ship
# as release assets alongside it (see .gitignore).
if [[ "$LEAD" =~ ^[0-9]+$ ]]; then
  en=(Red Orange Yellow Green Cyan Blue Violet Magenta White Gray)
  pl=(Czerwony Pomarańczowy Żółty Zielony Cyjan Niebieski Fioletowy Purpurowy Biały Szary)
  vtt_ts() { printf '00:%02d:%02d.000' $(( $1 / 60 )) $(( $1 % 60 )); }
  write_vtt() {
    local out="$1"; shift; local -a names=("$@")
    { printf 'WEBVTT\n\n'
      for ((l=0; l<LOOPS; l++)); do
        for ((i=0; i<N; i++)); do
          local st=$(( LEAD + l*N*SLOT + i*SLOT ))
          local fin=$(( st + SLOT )); (( fin > MIN*60 )) && fin=$(( MIN*60 ))
          printf '%s --> %s align:center\n%s · %s Hz\n\n' \
            "$(vtt_ts "$st")" "$(vtt_ts "$fin")" "${names[$i]}" "${freqs[$i]}"
        done
      done
    } >"$out"
    echo "wrote $out"
  }
  write_vtt "${OUT%.*}_captions_en.vtt" "${en[@]}"
  write_vtt "${OUT%.*}_captions_pl.vtt" "${pl[@]}"
else
  echo "note: non-integer LEAD, skipping caption sidecars (cue times would drift)"
fi
