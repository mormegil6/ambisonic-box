#!/usr/bin/env python3
"""Per-channel tone check for the OBS-merge harness, no numpy needed.

Reads interleaved s16le PCM on stdin (any channel count), runs a Goertzel
detector at each expected ladder frequency (200..1700 Hz, 100 Hz steps by
default) on every channel, and asserts channel k's dominant ladder tone is
tone k. This proves channel ORDER survived whatever chain produced the PCM,
which is the property the whole exercise exists to protect.

Usage: ffmpeg ... -f s16le - | check-tones.py <channels> [samplerate] [base] [step] [stagger_dB]
With stagger_dB the level ramp is asserted too, relative to channel 0.
Exit: 0 all channels carry their expected tone (and level), 1 a real fault,
      2 the input was not the tone ladder at all.
"""
import sys, math, struct

ch = int(sys.argv[1])
sr = int(sys.argv[2]) if len(sys.argv) > 2 else 48000
base = int(sys.argv[3]) if len(sys.argv) > 3 else 200
step = int(sys.argv[4]) if len(sys.argv) > 4 else 100
# Optional 5th argument: dB per channel of an intended level stagger, so channel
# k is expected k*stagger below channel 0. Omit it and levels are reported but
# not asserted, which is how every caller behaved before 2026-08-10.
#
# WHY IT EXISTS. Frequency alone catches a swap, a duplicate or a dropped
# channel, because all three change WHICH tone lands WHERE. It cannot see a
# per-channel GAIN fault: sixteen tones each in the right slot at the wrong
# level pass green. That is not hypothetical here - merge-obs-tracks.sh writes
# pan=...|c0=c0|c1=c1|... by hand and the gateway builds a 16-entry join map, so
# a single wrong coefficient in either is exactly that fault. The operator's
# REAPER fixture has always carried a 6 dB stagger and caught it; the synthetic
# ladders generated every tone at one amplitude and did not.
#
# RELATIVE to channel 0 on purpose, never absolute dBFS: an overall gain change
# anywhere in the chain is not the fault being hunted, and asserting absolute
# levels would turn every encoder-setting change into a false failure.
stagger = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
# Measured through the real chain (16 tones, 2 dB apart, libopus mapping_family
# 255 at 512k, decoded back): worst deviation 0.07 dB. 2 dB of tolerance is
# about thirty times that, so this fails on a wiring fault and not on the codec.
STAGGER_TOL_DB = 2.0

N = sr  # 1 s of audio: 1 Hz bins, far finer than the 100 Hz ladder spacing
raw = sys.stdin.buffer.read(N * ch * 2)
# drain the rest: exiting mid-stream SIGPIPEs the feeding ffmpeg, which reads
# as a pipeline failure under `set -o pipefail` in the calling harness
while sys.stdin.buffer.read(1 << 20):
    pass
n = len(raw) // (ch * 2)
if n < sr // 2:
    print(f"FAIL: only {n} samples per channel, need >= {sr//2}")
    sys.exit(1)
samples = struct.unpack(f"<{n*ch}h", raw[: n * ch * 2])

freqs = [base + i * step for i in range(ch)]

def goertzel(xs, f):
    w = 2.0 * math.pi * f / sr
    coeff = 2.0 * math.cos(w)
    s0 = s1 = s2 = 0.0
    for x in xs:
        s0 = x + coeff * s1 - s2
        s2, s1 = s1, s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2

# Is the input a tone ladder AT ALL? This detector only measures power at the
# expected ladder frequencies, so fed ordinary programme material every channel
# still has an argmax - whichever ladder bin caught the most leakage - and the
# report reads as a confident channel-ORDER failure. On 2026-08-10 that is
# exactly what a live music stream produced: sixteen "WRONG (dominant 400 Hz)"
# lines for a stack that was working perfectly.
#
# A real tone is sharply dominant; broadband material is not. Peak-to-median
# power across the ladder bins separates them, calibrated on real signals rather
# than guessed:
#
#   ladder through the actual Opus chain   min ratio 1.4e8
#   live music from the DASH output        max ratio 2.1e3
#
# 1e5 sits 50x above the worst music and 1400x below the weakest real ladder.
TONE_RATIO_MIN = 1e5

ok = True
tonal = 0
levels = {}
for c in range(ch):
    xs = samples[c::ch]
    rms = math.sqrt(sum(x * x for x in xs) / len(xs)) / 32768.0
    rms_db = 20 * math.log10(rms) if rms > 0 else -200.0
    # a silent channel still has an argmax over leakage from its neighbours,
    # which once produced a false PASS on a channel OBS had muted - so silence
    # is its own loud failure, checked before any frequency reasoning
    if rms_db < -60.0:
        print(f"  ch{c:02d} expect {freqs[c]:4d} Hz: SILENT ({rms_db:.0f} dBFS)")
        ok = False
        continue
    powers = [goertzel(xs, f) for f in freqs]
    best = powers.index(max(powers))
    ranked = sorted(powers)
    median = ranked[len(ranked) // 2]
    ratio = (max(powers) / median) if median > 0 else float("inf")
    if ratio >= TONE_RATIO_MIN:
        tonal += 1
    status = "ok" if best == c else f"WRONG (dominant {freqs[best]} Hz)"
    if best != c:
        ok = False
    levels[c] = rms_db
    print(f"  ch{c:02d} expect {freqs[c]:4d} Hz: {status} ({rms_db:.0f} dBFS)")

# Report the wrong-input case as its own thing, with its own exit code, so a
# harness and a human both stop looking for a channel-mapping bug that is not
# there. Half is a deliberately loose bar: a genuinely scrambled ladder is still
# sixteen tones and stays well clear of it.
if tonal < ch / 2:
    print(f"NOT A TONE LADDER: only {tonal}/{ch} channels carry a dominant "
          f"ladder tone, so this is not the {base}-{base + (ch - 1) * step} Hz "
          f"test signal. Channel order was NOT tested. Check the input is the "
          f"harness clip rather than live content, and that base/step match it.")
    sys.exit(2)

# Level ramp, only when the caller says one was generated. Checked after the
# not-a-ladder verdict above, so an unrelated input is never reported as a gain
# fault - the same misdiagnosis this file already exists to prevent.
if stagger and ok:
    if 0 not in levels:
        print("LEVEL CHECK SKIPPED: channel 0 was silent, so there is no reference")
    else:
        worst = 0.0
        for c in sorted(levels):
            expected = levels[0] - stagger * c
            err = levels[c] - expected
            if abs(err) > abs(worst):
                worst = err
            if abs(err) > STAGGER_TOL_DB:
                print(f"  ch{c:02d} level {levels[c]:.1f} dBFS, expected {expected:.1f} "
                      f"({stagger:g} dB/ch below ch00): off by {err:+.1f} dB")
                ok = False
        if ok:
            print(f"  level ramp ok: {stagger:g} dB per channel held to {abs(worst):.2f} dB")
        else:
            print("LEVEL RAMP FAIL: tones are in the right channels at the WRONG levels, "
                  "which is a per-channel gain fault rather than a mapping one")

print("TONE CHECK " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
