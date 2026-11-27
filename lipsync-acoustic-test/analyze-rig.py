#!/usr/bin/env python3
"""Offset from the photodiode rig: the flash is timed from the light on the screen and the beep from the phone's sound
output, both on one sound card's clock, so nothing the browser reports is involved.
usage: python3 analyze-rig.py <tag>      (reads runs/<tag>.rig.wav: input 1 phone right, 2 phone left, 3 photodiode)
offset = beep - flash in ms, positive = audio late.
The sound card's inputs block a steady voltage, so the photodiode shows each change of light as a spike: one polarity
when the screen turns white, the other when it turns black. A flash starts at the first spike of each pair 0.5 s apart,
timed at half of that spike's height. The beep is timed at half of its 1 kHz envelope, on the left channel."""
import json, sys, wave, numpy as np
tag = sys.argv[1]
w = wave.open(f'runs/{tag}.rig.wav'); sr = w.getframerate(); ch = w.getnchannels()
x = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').reshape(-1, ch).astype(np.float64) / 32768
right, left, light = x[:, 0], x[:, 1], x[:, 2]
light = light - np.median(light)

# Light events: excursions past 40 % of the largest one, at least 0.25 s apart.
a = np.abs(light); thr = 0.4 * a.max(); ev = []; last = -10**9
for i in np.where(a > thr)[0]:
    if i - last > 0.25 * sr: ev.append(i)
    last = i
def edge(i):   # half-height crossing of the event that starts near i, with the event's sign
    seg = light[max(0, i - int(0.005 * sr)):i + int(0.02 * sr)]; k = int(np.argmax(np.abs(seg))); s = np.sign(seg[k])
    j = int(np.argmax(s * seg >= 0.5 * abs(seg[k])))
    return (max(0, i - int(0.005 * sr)) + j) / sr, s
edges = [edge(i) for i in ev]
# The flash's own polarity: the sign of the first event of each pair that is 0.4 to 0.6 s apart.
on_sign = None; flashes = []
for (t0, s0), (t1, s1) in zip(edges, edges[1:]):
    if 0.4 < t1 - t0 < 0.6 and s0 != s1:
        on_sign = on_sign or s0
        if s0 == on_sign: flashes.append(t0)
if not flashes: sys.exit(f'{tag}: no flashes found on the photodiode ({len(edges)} light events); is the sensor over the video?')

W = int(0.005 * sr)
def env(sig, f):
    z = sig * np.exp(-2j * np.pi * f * np.arange(len(sig)) / sr); c = np.cumsum(np.concatenate([[0], z])); return np.abs((c[W:] - c[:-W]) / W) * 2
e = env(left, 1000); thr = 0.5 * e.max(); beeps = []; last = -10**9
for i in np.where(e > thr)[0]:
    if i - last > 2 * sr:
        seg = e[max(0, i - W):i + int(0.1 * sr)]; j = max(0, i - W) + int(np.argmax(seg > seg.max() * 0.5))
        beeps.append(j / sr)
    last = i
rows = []
for b in beeps:
    f = min(flashes, key=lambda t: abs(t - b))
    if abs(f - b) < 2: rows.append((b - f) * 1000)
if not rows: sys.exit(f'{tag}: no pairs (beeps={len(beeps)} flashes={len(flashes)})')
r = np.array(rows)
meta = {}
try: meta = json.load(open(f'runs/{tag}.json'))
except OSError: pass
lr = 20 * np.log10(np.sqrt(np.mean(right ** 2)) / max(np.sqrt(np.mean(left ** 2)), 1e-12))
print(f"{tag}\t{meta.get('version', '')}\t{meta.get('clip', '')}\t{str(meta.get('bundle', ''))[-20:]}\trig pairs={len(r)}(beeps={len(beeps)},flashes={len(flashes)})"
      f"\toffset_ms mean={r.mean():.1f} sd={r.std():.1f} min={r.min():.0f} max={r.max():.0f}\tright_vs_left_dB={lr:.1f}\tfeed_shift={(meta.get('feed') or {}).get('shiftMs')}")
