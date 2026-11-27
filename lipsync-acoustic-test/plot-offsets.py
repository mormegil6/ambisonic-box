#!/usr/bin/env python3
"""Draw offsets.png and offsets.svg from results.tsv: the audio offset of v1.3.13 and v1.3.14 for every clip and browser.
usage: python3 plot-offsets.py        (needs numpy-free matplotlib only)
Each dot is the mean of one run of ten flash/beep pairs in one browser. Positive means the audio is late."""
import os, re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

here = os.path.dirname(os.path.abspath(__file__))
OLD, NEW = '1.3.13 (bundle from the release tag)', '1.3.14 (deployed)'
CLIPS = [('nob', 'nob'), ('ctrl', 'ctrl'), ('trim', 'trim'), ('live', 'live'), ('elst', 'elst')]
ENGINES = [('chrome', 'Chrome 157'), ('canary', 'Canary 160'), ('canaryKS', 'Canary 160, edit skipped'),
           ('safari', 'Safari 27.2'), ('firefox', 'Firefox 161 Beta'), ('firefoxNightly', 'Firefox 163 Nightly')]

def parse():
    rows = {}
    for line in open(os.path.join(here, 'results.tsv')):
        f = line.rstrip('\n').split('\t')
        if len(f) < 6 or f[0] == 'tag' or f[3] not in (OLD, NEW):
            continue
        m = re.search(r'mean=(-?[\d.]+) sd=([\d.]+)', f[5])
        if not m:
            continue
        engine = f[0].split('-')[1]
        rows[(f[3], engine, f[2])] = (float(m.group(1)), float(m.group(2)))
    return rows

SHAPES = {'chrome': 'o', 'canaryKS': 'D', 'canary': '^', 'safari': 's', 'firefox': 'P', 'firefoxNightly': 'X'}

def main():
    data = parse()
    surface, ink, ink2, grid = '#fcfcfb', '#0b0b0b', '#52514e', '#e3e2de'
    c_old, c_new = '#eb6834', '#2a78d6'
    # Colour is the build, shape is the browser. The axis is broken between 110 and 450 ms so that the dots near 0 stay
    # legible next to the three near 500.
    fig, (ax, bx) = plt.subplots(1, 2, figsize=(7.4, 3.7), sharey=True, facecolor=surface,
                                 gridspec_kw={'width_ratios': [9, 1.4], 'wspace': 0.1})
    n = len(CLIPS)
    for a_ in (ax, bx):
        a_.set_facecolor(surface)
        for g, (clip, _) in enumerate(CLIPS):
            y0 = n - 1 - g
            for build, color, dy in ((OLD, c_old, 0.2), (NEW, c_new, -0.2)):
                for k, (eng, _) in enumerate(ENGINES):
                    cell = data.get((build, eng, clip))
                    if cell:
                        a_.plot(cell[0], y0 + dy + (2 - k) * 0.07, marker=SHAPES[eng], ms=6.5 if SHAPES[eng] != 'P' else 7.5, color=color, mec=surface,
                                mew=1.2, ls='none', alpha=0.92, zorder=3)
        a_.grid(axis='x', color=grid, lw=0.7)
        a_.set_axisbelow(True)
        a_.tick_params(length=0, colors=ink2, labelsize=8)
        a_.set_ylim(-0.6, n - 0.4)
        for sp in a_.spines.values():
            sp.set_visible(False)
    bx.set_facecolor('#f1f0ec')   # a different scale: tint the far panel
    ax.set_xlim(-110, 110)
    ax.set_xticks([-100, -80, -60, -40, -20, 0, 20, 40, 60, 80, 100])
    ax.axvline(0, color=ink2, lw=0.9, zorder=1)
    bx.set_xlim(450, 520)
    bx.set_xticks([460, 500])
    ax.set_yticks(range(n))
    ax.set_yticklabels([t for _, t in reversed(CLIPS)], fontsize=8, color=ink2)
    fig.supxlabel('audio offset in ms (positive: the sound is late); the axis is broken between 110 and 450 ms',
                  fontsize=7.5, color=ink2, y=0.01)
    builds = [Line2D([], [], marker='o', ls='none', ms=6.5, color=c, mec=surface, label=l) for c, l in ((c_old, 'v1.3.13'), (c_new, 'v1.3.14'))]
    browsers = [Line2D([], [], marker=SHAPES[e], ls='none', ms=6.5 if SHAPES[e] != 'P' else 7.5, color=ink2, mec=surface, label=l) for e, l in ENGINES]
    # Same font size, handle length and anchor for both rows, so the first symbols line up.
    kw = dict(loc='upper left', frameon=False, fontsize=7.5, labelcolor=ink, handlelength=1.0, handletextpad=0.3, borderaxespad=0, borderpad=0)
    fig.legend(handles=builds, ncol=2, columnspacing=1.2, bbox_to_anchor=(0.015, 0.915), **kw)
    fig.legend(handles=browsers, ncol=len(browsers), columnspacing=0.9, bbox_to_anchor=(0.015, 0.862), **kw)
    fig.suptitle('Audio offset at the sound output, by clip', x=0.01, y=0.995, ha='left', va='top', fontsize=10, color=ink)
    fig.subplots_adjust(left=0.08, right=0.99, top=0.80, bottom=0.19)
    # The cut: a double slash at the top and bottom of each side, drawn with a marker so the angle is the same on both panels.
    for a_, x in ((ax, 1.0), (bx, 0.0)):
        for y in (0.0, 1.0):
            a_.plot([x], [y], transform=a_.transAxes, marker=[(-1, -1), (1, 1)], ms=9, mew=1.2, color=ink2, ls='none', clip_on=False, zorder=5)
    for ext in ('png', 'svg'):
        fig.savefig(os.path.join(here, 'offsets.' + ext), dpi=150, facecolor=surface)
    print('wrote offsets.png and offsets.svg,', len(data), 'cells')

main()
