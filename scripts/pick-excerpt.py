#!/usr/bin/env python3
"""Choose a representative excerpt from a long ambisonic recording, by content.

WHY THIS EXISTS. The first pass of the -compression_level measurement cut every
excerpt at a fixed 60 s offset. On a live concert recording that is a lottery:
one landed squarely in the pre-concert audience (spectral flatness 0.33 at
-49 dBFS - applause and chatter, not music) and another was two-thirds silence.
Neither tells you anything about how a codec handles music, and an A/B run on
them would have produced confident numbers about the wrong signal.

WHAT IT SCORES. Sliding windows over the W channel (ACN 0), which carries the
omnidirectional sum and therefore the whole energy of the scene:

  level      mean dBFS. Rejects silence and near-silence outright.
  flatness   spectral flatness (geometric mean over arithmetic mean of the
             magnitude spectrum). Noise-like signals - applause, crowd, rain -
             sit high; tonal music sits low. This is the discriminator that
             would have caught the applause excerpt.
  steadiness standard deviation of per-second level. Speech and applause swing;
             sustained music does not. Catches announcements and gaps.

The score prefers loud, tonal and steady, in that order of weight. It is a
heuristic and it is meant to be checked: the chosen window is printed with its
numbers so a human can disagree, and --preview writes a stereo fold-down to
listen to before committing a measurement to it.

Usage:
  pick-excerpt.py <file.wav> [--length 30] [--hop 5] [--preview out.wav]
"""
import argparse
import sys

import numpy as np
import soundfile as sf


def spectral_flatness(x):
    """1.0 = white noise, toward 0 = tonal. Applause lands high, music low."""
    mag = np.abs(np.fft.rfft(x * np.hanning(len(x)))) + 1e-12
    return float(np.exp(np.mean(np.log(mag))) / np.mean(mag))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--length", type=float, default=30.0, help="excerpt seconds")
    ap.add_argument("--hop", type=float, default=5.0, help="window step seconds")
    ap.add_argument("--preview", help="write a stereo fold-down of the winner here")
    ap.add_argument("--top", type=int, default=5, help="how many candidates to print")
    a = ap.parse_args()

    info = sf.info(a.path)
    sr = info.samplerate
    win = int(a.length * sr)
    hop = int(a.hop * sr)
    if info.frames < win:
        print(f"file is shorter than {a.length}s ({info.frames/sr:.1f}s)", file=sys.stderr)
        sys.exit(2)

    # W only: one channel is enough to judge content, and reading 16 channels of
    # a 90-minute concert to pick a 30 s window is not.
    w, _ = sf.read(a.path, always_2d=True, dtype="float32")
    w = w[:, 0]

    rows = []
    for start in range(0, len(w) - win + 1, hop):
        seg = w[start:start + win]
        # per-second levels, for steadiness and for a silence share
        secs = seg[:len(seg) // sr * sr].reshape(-1, sr)
        db = 20 * np.log10(np.sqrt((secs ** 2).mean(axis=1)) + 1e-12)
        level = float(db.mean())
        steadiness = float(db.std())
        flat = spectral_flatness(seg[:sr * 4])          # 4 s is plenty for a spectrum
        quiet = float((db < db.max() - 25).mean())
        # Loud and tonal and steady. Flatness dominates because it is the one
        # that separates applause from music, which is the failure that
        # motivated this script.
        score = level - 120.0 * flat - 1.5 * steadiness - 40.0 * quiet
        rows.append((score, start / sr, level, flat, steadiness, quiet))

    rows.sort(reverse=True)
    print(f"{'start':>8} {'level':>8} {'flatness':>9} {'steady':>8} {'quiet':>7}  {'score':>8}")
    for s, t, lv, fl, st, q in rows[:a.top]:
        print(f"{t:8.1f} {lv:8.1f} {fl:9.4f} {st:8.1f} {q:7.0%}  {s:8.1f}")

    best = rows[0]
    print(f"\nPICK {best[1]:.1f}s  (level {best[2]:.1f} dBFS, flatness {best[3]:.4f}, "
          f"steadiness {best[4]:.1f} dB, {best[5]:.0%} quiet)")
    print(f"ffmpeg -ss {best[1]:.1f} -t {a.length:g} -i <file> -c:a pcm_s24le excerpt.wav")

    if a.preview:
        seg, _ = sf.read(a.path, start=int(best[1] * sr), frames=win,
                         always_2d=True, dtype="float32")
        # crude but adequate: W plus/minus Y gives a listenable left/right
        wch = seg[:, 0]
        y = seg[:, 1] if seg.shape[1] > 1 else np.zeros_like(wch)
        sf.write(a.preview, np.stack([wch + 0.5 * y, wch - 0.5 * y], axis=1), sr)
        print(f"preview: {a.preview}")


if __name__ == "__main__":
    main()
