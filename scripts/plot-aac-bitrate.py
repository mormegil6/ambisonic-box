#!/usr/bin/env python3
"""AAC contribution-bitrate figure for the study (aac-bitrate-test/RESULTS.md).

Regenerates aac-bitrate-test/bitrate-curve-<date>.{png,svg} from
aac-bitrate-test/results.tsv, where <date> is the YYYY-MM the measurement was
taken (not the day the plot was drawn):

    python3 scripts/plot-aac-bitrate.py 2026-08

Two panels, LQ and LA, matching the layout of the segment-duration and
opus-compression figures already in this repo. Each panel shows two series -
AAC alone, and the AAC-then-Opus cascade - as a bold MEAN line across the five
excerpts with a shaded MIN-MAX band, the same choice plot-segment-tradeoff.py
made and for the same reason: five excerpts, one window each, no repeats, so a
band communicates the real spread honestly rather than implying a confidence
interval that is not there.

Colour pair (#2980b9 aac, #c0392b cascade) reused from the two existing
figures rather than a fresh choice, and validated before reuse rather than
assumed: `node scripts/validate_palette.js "#2980b9,#c0392b" --mode light` in
the dataviz skill passes lightness, chroma, CVD separation (deltaE 21.0
deutan) and contrast.

Marker shape (circle AAC alone, square cascade) matches plot-bamq.py's
convention, so the two figures share a visual vocabulary for the same two
conditions. Colour does NOT also match plot-bamq.py, deliberately: there,
blue covers every codec condition as one family and red is reserved for the
anomalous decoder defect, because the point of that figure is "codec
conditions cluster, the defect does not." Here aac and cascade ARE the two
things being compared, so collapsing them into one hue would erase the
comparison the figure exists to show.
"""
import csv
import re
import sys

if len(sys.argv) != 2 or not re.fullmatch(r"\d{4}-\d{2}", sys.argv[1]):
    sys.exit(
        "usage: plot-aac-bitrate.py YYYY-MM\n"
        "\n"
        "  YYYY-MM is the month the MEASUREMENT was taken, per the Date line in\n"
        "  aac-bitrate-test/RESULTS.md.\n"
        "\n"
        "  Required rather than defaulted to the current month, for the same\n"
        "  reason as the other plot-*.py scripts here: this does not measure\n"
        "  anything, it plots aac-bitrate-test/results.tsv. Defaulting would let\n"
        "  a styling tweak stamp a fresh month onto old data."
    )
MEASURED = sys.argv[1]

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

rows = list(csv.DictReader(open("aac-bitrate-test/results.tsv"), delimiter="\t"))
RATES = sorted(set(int(r["kbps_per_ch"]) for r in rows))
ITEMS = sorted(set(r["item"] for r in rows))

def series(chain, metric):
    """mean, lo, hi across items at each rate, for one chain and one metric."""
    mean, lo, hi = [], [], []
    for kb in RATES:
        vals = [float(r[metric]) for r in rows
                if r["chain"] == chain and int(r["kbps_per_ch"]) == kb]
        mean.append(sum(vals) / len(vals))
        lo.append(min(vals))
        hi.append(max(vals))
    return mean, lo, hi

COL = {"aac": "#c0392b", "cascade": "#2980b9"}
MARKER = {"aac": "o", "cascade": "s"}   # matches plot-bamq.py's chain shapes
LABEL = {"aac": "AAC alone", "cascade": "AAC then Opus (cascade)"}

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.6), sharex=True)

for ax, metric, title in (
    (ax1, "LQ", "Listening quality"),
    (ax2, "LA", "Localisation"),
):
    for chain in ("aac", "cascade"):
        mean, lo, hi = series(chain, metric)
        c = COL[chain]
        ax.fill_between(RATES, lo, hi, color=c, alpha=0.15, zorder=1)
        ax.plot(RATES, mean, marker=MARKER[chain], color=c, lw=2, ms=6, zorder=3)
    ax.set_xlabel("Contribution AAC bitrate (kbit/s per channel)")
    ax.set_ylabel(f"AMBIQUAL {metric}")
    ax.set_title(title)
    ax.axvline(96, color="#2c3e50", lw=1, ls=":", alpha=0.6, zorder=2)
    ax.grid(True, alpha=0.3)
    ax.set_xticks(RATES)

# One legend, on ax2 only - matches plot-bamq.py's convention (also one
# legend, also the right-hand panel), and both panels here are the same two
# series, so repeating it on ax1 was pure redundancy, not independent
# standalone legibility. Upper-left: both curves start low at rate=32, so
# that corner is untouched by either line or band on either panel.
handles = [Line2D([], [], marker=MARKER[c], color=COL[c], lw=2, ms=6,
                   label=LABEL[c])
           for c in ("aac", "cascade")]
ax2.legend(handles=handles, loc="upper left", fontsize=8, framealpha=0.9,
           handletextpad=0.6)

for ax in (ax1, ax2):
    ylo, _ = ax.get_ylim()
    ax.annotate("96: production", (96, ylo),
                textcoords="offset points", xytext=(4, 4),
                fontsize=8, color="#2c3e50")

# Line break placed to keep both lines a similar WIDTH: ha="center" centers
# each line independently, so a short line beside a long one reads as ragged
# rather than as one centered block (the fix applied across every figure's
# caption tonight - see plot-opus-compression.py for the fuller note).
fig.text(0.5, 0.02,
         "Bold line = mean across 5 excerpts; band = min-max range (no repeats, so this is spread,\n"
         f"not a confidence interval). {min(RATES)}-{max(RATES)} kbit/s/channel, 16-ch AAC via the earshot contribution encoder.",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.4)

fig.tight_layout(rect=(0, 0.13, 1, 1))
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"aac-bitrate-test/bitrate-curve-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
