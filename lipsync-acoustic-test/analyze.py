#!/usr/bin/env python3
"""Pair the flash (video element) with the beep (system output capture). offset = beep - flash, ms; positive = audio late."""
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
L = sorted(d['lum'], key=lambda r: r[0]); fl = []
prev_low = True; last = -1e9
for now, edt, md, y in L:
    t = d['timeOrigin'] + (edt if edt and abs(edt - now) < 1000 else now)   # Safari reports expectedDisplayTime on another timebase: use the callback time there
    if y < 0.2: prev_low = True
    elif y > 0.5 and prev_low and t - last > 2000:
        fl.append((t, md)); last = t; prev_low = False
rows = []
# Slots repeat every 4 s, so an offset is only defined modulo 4 s: pair each beep with its nearest flash within +-2 s.
for be in beep_epoch:
    near = min(fl, key=lambda f: abs(f[0] - be)) if fl else None
    if near and abs(near[0] - be) < 2000: rows.append(be - near[0])
pairing = 'nearest'
if not rows: sys.exit(f'{tag}: no beep/flash pairs (beeps={len(beeps)} flashes={len(fl)})')
r = np.array(rows)
feed = d.get('feed') or {}
print(f"{tag}\t{d['version']}\t{d['clip']}\t{d['bundle'][-20:]}\tpairs={len(r)}({pairing},beeps={len(beeps)},flashes={len(fl)})\toffset_ms mean={r.mean():.1f} sd={r.std():.1f} min={r.min():.0f} max={r.max():.0f}\tcal_sd={calsd:.1f}\tfeed_shift={feed.get('shiftMs')}\tengineEdit={json.dumps(feed.get('engineEdit'))}")
