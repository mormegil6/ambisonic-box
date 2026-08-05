#!/usr/bin/env bash
# ONE-OFF: WebVTT captions for the `directions` VOD clip ONLY.
#
# This is NOT a general caption generator, and it is not part of the VOD
# toolchain. The `directions` clip is not produced by this repository the way
# colortones is (make-colortones.sh generates that one outright); its two
# audio inputs are recordings, so its captions cannot be derived from a
# generator. Point this at any other clip and it will emit confidently wrong
# timings.
#
# 2026-08-05: REWRITTEN for the six-direction recording (front, back, left,
# right, top, bottom), which replaced the four-direction one.
#
# The timings are now MEASURED rather than reconstructed, and that is the
# substantive change. The old clip existed only as a finished mix, so its cue
# times had to be recovered by correlating the W channel against X/Y/Z to find
# both WHEN each word occurred and WHICH direction it was panned to - level
# thresholding alone could not separate reads sitting on a continuous musical
# bed. The new recording ships as a dry voice stem, so the onsets below come
# straight off it by silence detection at -45 dB, and were then checked
# against the energy-map render: every blob lands on the card label that names
# it.
#
# Structure: one loop unit repeated until 120 s. The unit is the bed, whose
# period (11.0833 s = 266 frames at 24 fps) was measured by autocorrelating
# the published master, with the voice starting OFFSET into each unit. See
# scripts/make-directions-clip.sh for how the master is built.
#
# It lives in the repo only so that measurement survives in readable form. The
# .vtt files themselves are NOT tracked - like the clip masters and the two
# source recordings, they ship as release assets (see .gitignore).
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
LOOP   = 11.0833   # s  loop period (autocorrelation of the published master)
OFFSET = 1.0       # s  the voice starts this late in each loop unit
TOTAL  = 120.0     # s  clip duration
HOLD   = 1.6       # s  max a cue stays up when the next word is far off

# onset of each read WITHIN the dry voice stem, silence-detected at -45 dB
WORDS = [('F', 0.18), ('B', 1.94), ('L', 3.45),
         ('R', 4.86), ('T', 6.23), ('D', 7.59)]

EN_DIR = {'F': 'Front', 'B': 'Back', 'L': 'Left',
          'R': 'Right', 'T': 'Top',  'D': 'Bottom'}
PL_DIR = {'F': 'Przód', 'B': 'Tył',  'L': 'Lewo',
          'R': 'Prawo', 'T': 'Góra', 'D': 'Dół'}

# The clip doubles as a captions test, so the second line cycles through the
# things worth exercising: the language switch and Polish diacritics.
EN_HELP = ["Captions test — press CC ▸ to switch language",
           "English captions · choose Polski in the CC menu",
           "Diacritics: Gdańsk, Wrocław, łóżko",
           "Reads are panned in 3rd-order Ambisonics (16 ch)",
           "The glow marks where the sound is coming from",
           "Six directions: front, back, left, right, top, bottom"]
PL_HELP = ["Test napisów — naciśnij CC ▸, aby zmienić język",
           "Napisy po polsku · wybierz English w menu CC",
           "Znaki diakrytyczne: Gdańsk, Wrocław, łóżko",
           "Odczyty panoramowane w Ambisonice 3. rzędu (16 kan.)",
           "Poświata pokazuje, skąd dochodzi dźwięk",
           "Sześć kierunków: przód, tył, lewo, prawo, góra, dół"]

cues = []
n = 0
while LOOP * n + OFFSET < TOTAL:          # loop units until the clip ends
    base = LOOP * n + OFFSET
    for grp, (key, off) in enumerate(WORDS):
        t = base + off
        if 0 <= t < TOTAL:
            cues.append((round(t, 2), key, grp))
    n += 1
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
                dirmap[key], helps[grp % len(helps)], ""]
    return "\n".join(out) + "\n"

for lang, dirmap, helps in (("en", EN_DIR, EN_HELP), ("pl", PL_DIR, PL_HELP)):
    # named to pair with the master release asset, directions_8k360_16ch.webm
    path = os.path.join(outdir, "directions_8k360_16ch_captions_%s.vtt" % lang)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(build(dirmap, helps))
    print("wrote %s (%d cues)" % (path, len(cues)))
PY

echo "Deploy: copy these into the clip's DASH dir as captions_<lang>.vtt"
