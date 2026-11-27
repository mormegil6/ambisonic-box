#!/usr/bin/env python3
"""Offset from the screen recording (screencap): the flash is timed from the captured picture and the beep from the
captured system audio, both on the host clock, so neither side depends on what the browser reports.
usage: python3 analyze-screen.py <tag>   (reads runs/<tag>.sc.luma.tsv, .sc.audio.f32, .sc.audio.json)
offset = beep - flash in ms, positive = audio late. Each flash is the first captured frame whose luma rises past the
midpoint between dark and bright; the capture runs at 60 fps, so a flash is timed to within one 16.7 ms display frame."""
import json, sys, numpy as np
tag = sys.argv[1]; p = f'runs/{tag}.sc'
L = np.loadtxt(p + '.luma.tsv'); t, y = L[:, 0], L[:, 1]
meta = json.load(open(p + '.audio.json')); sr = meta['sampleRate']
a = np.fromfile(p + '.audio.f32', dtype=np.float32).astype(np.float64)
lo, hi = np.percentile(y, 5), y.max()
if hi - lo < 0.05: sys.exit(f'{tag}: no flashes on the captured screen (luma {lo:.3f} to {hi:.3f}); was the window visible?')
mid = (lo + hi) / 2
# A flash lasts 0.5 s: keep rises whose bright run lasts 0.4 to 0.6 s, which drops a window appearing or a page repaint.
rise = [i for i in range(1, len(y)) if y[i] > mid and y[i - 1] <= mid]
flashes = []
for i in rise:
    j = i
    while j < len(y) and y[j] > mid: j += 1
    if j < len(y) and 0.4 < t[j] - t[i] < 0.6: flashes.append(t[i])
W = 240
def env(f):
    z = a * np.exp(-2j * np.pi * f * np.arange(len(a)) / sr); c = np.cumsum(np.concatenate([[0], z])); return np.abs((c[W:] - c[:-W]) / W) * 2
e = env(1000); thr = e.max() * 0.5; beeps = []; last = -10**9
for i in np.where(e > thr)[0]:
    if i - last > 2 * sr:
        seg = e[max(0, i - W):i + int(0.1 * sr)]; j = max(0, i - W) + int(np.argmax(seg > seg.max() * 0.5))
        beeps.append(meta['firstAudioHost'] + j / sr)
    last = i
rows = []
for b in beeps:
    f = min(flashes, key=lambda x: abs(x - b)) if flashes else None
    if f is not None and abs(f - b) < 2: rows.append((b - f) * 1000)
r = np.array(rows)
if not len(r): sys.exit(f'{tag}: no pairs (beeps={len(beeps)} flashes={len(flashes)})')
print(f"{tag}\tscreen\tpairs={len(r)}(beeps={len(beeps)},flashes={len(flashes)})\toffset_ms mean={r.mean():.1f} sd={r.std():.1f} min={r.min():.0f} max={r.max():.0f}")
