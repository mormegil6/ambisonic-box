#!/usr/bin/env bash
# ONE-OFF: WebVTT captions for the `directions` VOD clip ONLY.
#
# This is NOT a general caption generator, and it is not part of the VOD
# toolchain. The `directions` clip is not produced by this repository (unlike
# colortones, which make-colortones.sh generates); it is a recording, so its
# captions cannot be derived from a generator the way colortones' can.
#
# The cue times below were MEASURED from that one recording
# (16chAmbiX_FrontRightLeftTop). The spoken reads were located by correlating
# the W channel against the X/Y/Z channels of the third-order Ambisonic mix,
# which recovers both WHEN each word occurs and WHICH direction it is panned to
# (Right = -Y, Left = +Y, Top = +Z, Front = +X). That analysis yielded an
# 11.08 s loop period, a first "Right" onset at 3.0 s, and the per-word offsets
# hard-coded below. Point this at any other clip and it will emit confidently
# wrong timings.
#
# It lives in the repo only so that measurement survives in readable form. The
# .vtt files themselves are NOT tracked - like the clip masters, they ship as
# release assets (see .gitignore).
#
# Usage: scripts/make-directions-captions.sh [outdir]
#   default outdir: content/vod/masters
set -euo pipefail

OUTDIR="${1:-content/vod/masters}"
mkdir -p "$OUTDIR"

python3 - "$OUTDIR" <<'PY'
import sys, os
outdir = sys.argv[1]

# ---- measured from the recording; see header before changing anything ------
LOOP  = 11.08   # s  loop period (Right->Right within a pair 0.96 s, then 10.12 s)
R0    = 3.0     # s  onset of the first "Right"
NLOOP = 11      # loops that fall inside the clip
TOTAL = 120.0   # s  clip duration
HOLD  = 1.6     # s  max a cue stays up when the next word is far off

# (direction, offset from that loop's first Right, helper-line group)
WORDS = [('F', -2.7, 0), ('F', -1.7, 0),
         ('R',  0.0, 1), ('R',  1.0, 1),
         ('L',  2.0, 2), ('L',  2.8, 2),
         ('T',  4.0, 3), ('T',  4.8, 3)]

EN_DIR = {'F': 'Front', 'R': 'Right', 'L': 'Left', 'T': 'Top'}
PL_DIR = {'F': 'Przód', 'R': 'Prawo', 'L': 'Lewo', 'T': 'Góra'}

EN_HELP = ["Captions test — press CC ▸ to switch language",
           "English captions · choose Polski in the CC menu",
           "Diacritics: Gdańsk, Wrocław, łóżko",
           "Reads are panned in 3rd-order Ambisonics (16 ch)"]
PL_HELP = ["Test napisów — naciśnij CC ▸, aby zmienić język",
           "Napisy po polsku · wybierz English w menu CC",
           "Znaki diakrytyczne: Gdańsk, Wrocław, łóżko",
           "Odczyty panoramowane w Ambisonice 3. rzędu (16 kan.)"]

cues = []
for n in range(NLOOP):
    R = R0 + LOOP * n
    for key, off, grp in WORDS:
        t = R + off
        if 0 <= t < TOTAL:
            cues.append((round(t, 2), key, grp))
cues.sort()

def ts(t):
    m = int(t) // 60
    return "00:%02d:%06.3f" % (m, t - 60 * m)

def build(dirmap, helps):
    out = ["WEBVTT", ""]
    for i, (t, key, grp) in enumerate(cues):
        nxt = cues[i + 1][0] if i + 1 < len(cues) else TOTAL
        end = min(nxt, t + HOLD, TOTAL)
        out += ["%s --> %s align:center" % (ts(t), ts(end)),
                dirmap[key], helps[grp], ""]
    return "\n".join(out) + "\n"

for lang, dirmap, helps in (("en", EN_DIR, EN_HELP), ("pl", PL_DIR, PL_HELP)):
    path = os.path.join(outdir, "directions_captions_%s.vtt" % lang)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(build(dirmap, helps))
    print("wrote %s (%d cues)" % (path, len(cues)))
PY

echo "Deploy: copy these into the clip's DASH dir as captions_<lang>.vtt"
