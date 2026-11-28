#!/usr/bin/env python3
"""Draw rig-offsets.png and rig-offsets.svg from rig-results.tsv: the offset at the screen, timed by the photodiode rig,
for each screen and browser, with the browser's own playback, this player and the bare page side by side.
usage: python3 plot-rig.py        (needs matplotlib)
Each dot is the mean of one run of ten flash/beep pairs. Positive means the audio is late."""
import os, re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

here = os.path.dirname(os.path.abspath(__file__))
ROWS = [('MacBook', 'Chrome', 'MacBook Pro, Chrome 157'), ('MacBook', 'Safari', 'MacBook Pro, Safari 27.2'),
        ('MacBook', 'Firefox', 'MacBook Pro, Firefox 161'), ('ASUS', 'Chrome', 'ASUS monitor, Chrome 157'),
        ('ASUS', 'Safari', 'ASUS monitor, Safari 27.2'), ('S25', 'Chrome', 'Galaxy S25, Chrome 158')]
KINDS = [('own', "browser's own playback of a plain MP4"), ('player', 'this player (v1.3.14, clip nob)'),
         ('bare', 'bare page: painted flash and Web Audio beep')]

def parse():
    pts = []
    for line in open(os.path.join(here, 'rig-results.tsv')):
        f = line.rstrip('\n').split('\t')
        if len(f) < 6 or f[0] == 'tag':
            continue
        m = re.search(r'offset_ms mean=(-?[\d.]+)', f[5])
        if not m:
            continue
        where = f[3]
        screen = 'MacBook' if 'MacBook' in where else 'ASUS' if 'ASUS' in where else 'S25' if '-s25' in f[0] else None
        kind = 'own' if "own playback" in where else 'bare' if ('bare page' in where or f[2] == 'diag') else 'player' if f[2] == 'nob' else None
        browser = next((b for b in ('Chrome', 'Safari', 'Firefox') if b in f[1]), 'Chrome' if f[1].startswith('diag') else None)
        if screen and kind and browser:
            pts.append((screen, browser, kind, float(m.group(1))))
    return pts

def main():
    pts = parse()
    surface, ink, ink2, grid = '#fcfcfb', '#0b0b0b', '#52514e', '#e3e2de'
    style = {'own': ('#52514e', 's'), 'player': ('#2a78d6', 'o'), 'bare': ('#3f9a6b', '^')}
    fig, ax = plt.subplots(figsize=(7.4, 3.9), facecolor=surface)
    ax.set_facecolor(surface)
    n = len(ROWS)
    for i, (scr, br, _) in enumerate(ROWS):
        y0 = n - 1 - i
        for k, (kind, _) in enumerate(KINDS):
            for (s, b, kd, v) in pts:
                if (s, b, kd) == (scr, br, kind):
                    c, mk = style[kind]
                    ax.plot(v, y0 + (1 - k) * 0.18, marker=mk, ms=6.5, color=c, mec=surface, mew=1.2, ls='none', alpha=0.92, zorder=3)
    for y in (n - 3.5, n - 5.5):   # between the screens
        ax.axhline(y, color=grid, lw=0.9, zorder=1)
    ax.set_xlim(-100, 10)
    ax.set_xticks(range(-100, 1, 10))
    ax.axvline(0, color=ink2, lw=0.9, zorder=1)
    for x, t in ((-45, 'detectable'), (-90, 'acceptable')):
        ax.axvline(x, color=ink2, lw=0.8, ls=(0, (3, 3)), zorder=1)
        ax.text(x + 1, n - 0.45, 'BT.1359: ' + t + ' limit', fontsize=6.8, color=ink2, va='bottom', ha='left')
    ax.set_ylim(-0.6, n - 0.2)
    ax.set_yticks(range(n))
    ax.set_yticklabels([t for _, _, t in reversed(ROWS)], fontsize=8, color=ink2)
    ax.grid(axis='x', color=grid, lw=0.7)
    ax.set_axisbelow(True)
    ax.tick_params(length=0, colors=ink2, labelsize=8)
    for sp in ax.spines.values():
        sp.set_visible(False)
    ax.set_xlabel('audio offset in ms at the screen (negative: the sound comes first)', fontsize=7.5, color=ink2)
    handles = [Line2D([], [], marker=style[k][1], ls='none', ms=6.5, color=style[k][0], mec=surface, label=l) for k, l in KINDS]
    fig.legend(handles=handles, ncol=3, loc='upper left', frameon=False, fontsize=7.5, labelcolor=ink, handlelength=1.0,
               handletextpad=0.3, columnspacing=1.2, borderaxespad=0, borderpad=0, bbox_to_anchor=(0.01, 0.905))
    fig.suptitle('Audio offset at the screen, timed by a photodiode', x=0.01, y=0.995, ha='left', va='top', fontsize=10, color=ink)
    fig.subplots_adjust(left=0.25, right=0.99, top=0.80, bottom=0.13)
    for ext in ('png', 'svg'):
        fig.savefig(os.path.join(here, 'rig-offsets.' + ext), dpi=150, facecolor=surface)
    print('wrote rig-offsets.png and rig-offsets.svg,', len(pts), 'runs')
    for p in sorted(pts): print(' ', p)

main()
