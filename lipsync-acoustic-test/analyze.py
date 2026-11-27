#!/usr/bin/env python3
"""Pair the flash (video element) with the beep (system output capture). offset = beep - flash, ms; positive = audio late.
usage: python3 analyze.py <tag>      (reads runs/<tag>.json and runs/<tag>.wav, prints one tab-separated line)
The flash is timed from the frames' media time: its media time is the earliest slot position at which the flash was seen to
start or end at least twice, and media time is mapped to the page clock by the median of (frame time - media time) over the frames within
1 s of the flash. Timing it by the first callback that shows a bright frame instead reads one frame late whenever the
browser delivers no callback for that frame, which Firefox does for about one frame in five; that number is still
printed, as first_callback."""
import json, subprocess, sys, numpy as np
tag = sys.argv[1]
d = json.load(open(f'runs/{tag}.json'))
raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', f'runs/{tag}.wav', '-f', 'f32le', '-ac', '1', '-ar', '48000', '-'], capture_output=True).stdout
a = np.frombuffer(raw, dtype=np.float32).astype(np.float64); sr = 48000
W = 240  # 5 ms
def env(f):
    z = a * np.exp(-2j * np.pi * f * np.arange(len(a)) / sr)
    c = np.cumsum(np.concatenate([[0], z])); m = (c[W:] - c[:-W]) / W
    return np.abs(m) * 2   # index n = window ending at sample n+W
def onsets(e, frac, gap):
    thr = e.max() * frac; idx = []; last = -10**9
    above = np.where(e > thr)[0]
    for i in above:
        if i - last > gap * sr: idx.append(i)
        last = i
    # refine to the half-amplitude crossing of each event's local peak
    out = []
    for i in idx:
        seg = e[max(0, i - W):i + int(0.1 * sr)]; pk = seg.max()
        j = max(0, i - W) + int(np.argmax(seg > pk * 0.5))
        out.append(j / sr)
    return out
e3 = env(3000); e1 = env(1000)
clk = onsets(e3, 0.4, 0.3)[:3]
if len(clk) < 3: sys.exit(f'{tag}: only {len(clk)} calibration clicks found')
ep = d['clicks']['epochMs']
offs = [ep[i] - clk[i] * 1000 for i in range(3)]
cal = float(np.mean(offs)); calsd = float(np.std(offs))
beeps = [t for t in onsets(e1, 0.5, 2.0) if t > clk[-1] + 0.4]
beep_epoch = [t * 1000 + cal for t in beeps]
# Frame time: expectedDisplayTime, except in Safari, which reports it on another timebase; there the callback time is used.
F = np.array(sorted((d['timeOrigin'] + (edt if edt and abs(edt - now) < 1000 else now), md, y) for now, edt, md, y in d['lum']))
first = []   # per flash: time and media time of the first callback that shows a bright frame
fall = []    # media time of the first dark frame after each flash
prev_low = True; last = -1e9; bright = False
for t, md, y in F:
    if y < 0.2:
        if bright: fall.append(md); bright = False
        prev_low = True
    elif y > 0.5 and prev_low and t - last > 2000:
        first.append((t, md)); last = t; prev_low = False; bright = True
if not first: sys.exit(f'{tag}: no flashes found')
first = np.array(first)
SLOT, LEN = 4.0, 0.5   # slots repeat every 4 s of media time; a flash lasts 0.5 s
# Where in the slot the flash starts: every rising edge and every falling edge (minus the flash length) is one
# observation, late by a frame or two when a callback was skipped, so the start is the earliest value seen at least
# twice. A single earlier observation is treated as a mislabelled frame.
obs = np.sort(np.concatenate([first[:, 1] % SLOT, (np.array(fall) - LEN) % SLOT]))
twice = [x for i, x in enumerate(obs[:-1]) if obs[i + 1] - x < 0.002]
start = twice[0] if twice else obs[0]
flash = []
for t, md in first:
    m = start + SLOT * round((md - start) / SLOT)
    near = np.abs(F[:, 1] - m) < 1.0
    flash.append(m * 1000 + float(np.median(F[near, 0] - F[near, 1] * 1000)))
skipped = int(np.sum(first[:, 1] % SLOT > start + 0.002))
def pair(times):
    # An offset is only defined modulo the slot: pair each beep with its nearest flash within +-2 s.
    rows = []
    for be in beep_epoch:
        near = min(times, key=lambda f: abs(f - be))
        if abs(near - be) < 2000: rows.append(be - near)
    return np.array(rows)
r = pair(flash); r1 = pair(list(first[:, 0]))
if not len(r): sys.exit(f'{tag}: no beep/flash pairs (beeps={len(beeps)} flashes={len(first)})')
feed = d.get('feed') or {}
print(f"{tag}\t{d['version']}\t{d['clip']}\t{d['bundle'][-20:]}\tpairs={len(r)}(beeps={len(beeps)},flashes={len(first)},first_frame_skipped={skipped})"
      f"\toffset_ms mean={r.mean():.1f} sd={r.std():.1f} min={r.min():.0f} max={r.max():.0f} first_callback={r1.mean():.1f}"
      f"\tcal_sd={calsd:.1f}\tfeed_shift={feed.get('shiftMs')}\tengineEdit={json.dumps(feed.get('engineEdit'))}")
