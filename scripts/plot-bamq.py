#!/usr/bin/env python3
"""BAM-Q figure: the HOAST360 decoder defect against every codec condition.

    python3 scripts/plot-bamq.py 2026-08

Reads aac-bitrate-test/bamq.tsv. Two panels, both showing the same comparison
on different axes: binQ (BAM-Q's binaural quality, 100 = no difference) and
ILDdiff (interaural level difference error, higher = worse).

DESIGN CHOICE. The four codec conditions are drawn as one muted series rather
than four colours, because the argument is not "which bitrate wins" - that is
the sibling figure's job - but "every codec condition clusters, and the decoder
defect sits outside the cluster". Two colours also means the palette is the one
already validated for the other figures in this repo (deltaE 21.0 deutan) rather
than a five-hue set needing its own check.
"""
import csv
import re
import sys

if len(sys.argv) != 2 or not re.fullmatch(r"\d{4}-\d{2}", sys.argv[1]):
    sys.exit("usage: plot-bamq.py YYYY-MM   (month the measurement was taken)")
MEASURED = sys.argv[1]

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

rows = {r["label"]: r for r in csv.DictReader(open("aac-bitrate-test/bamq.tsv"), delimiter="\t")}
ITEMS = ["piano", "orchestra", "deusexmachina", "carnival", "quarry"]
CODEC = ["aac96", "aac128", "casc96", "casc128"]
CODEC_LABEL = {"aac96": "AAC 96", "aac128": "AAC 128",
               "casc96": "cascade 96", "casc128": "cascade 128"}

C_CODEC = "#2980b9"
C_BUG = "#c0392b"

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.8))

for ax, key, label, invert in (
    (ax1, "binQ", "BAM-Q binQ   (100 = no binaural difference)", True),
    (ax2, "ILDdiff", "ILD error   (higher = worse)", False),
):
    for y, item in enumerate(ITEMS):
        vals = [float(rows[f"{item}_{c}"][key]) for c in CODEC]
        bug = float(rows[f"{item}_DECODERBUG"][key])
        # codec conditions as a spread of small markers
        ax.plot(vals, [y] * len(vals), "o", color=C_CODEC, ms=7, alpha=0.75,
                zorder=3, label="codec conditions" if y == 0 else None)
        # a light connector showing the codec cluster's extent
        ax.plot([min(vals), max(vals)], [y, y], "-", color=C_CODEC, lw=1.5,
                alpha=0.35, zorder=2)
        ax.plot([bug], [y], "D", color=C_BUG, ms=9, zorder=4,
                label="decoder defect" if y == 0 else None)
    ax.set_yticks(range(len(ITEMS)))
    ax.set_yticklabels(ITEMS)
    ax.set_xlabel(label)
    ax.grid(True, axis="x", alpha=0.3)
    ax.invert_yaxis()
    if invert:
        ax.invert_xaxis()   # worse to the right on both panels

ax2.set_xscale("log")
# Explicit decade ticks: matplotlib's default log minor labels overlapped into
# an unreadable smear at this figure width.
from matplotlib.ticker import FixedLocator, FixedFormatter, NullLocator
ax2.xaxis.set_major_locator(FixedLocator([10, 30, 100, 300, 1000]))
ax2.xaxis.set_major_formatter(FixedFormatter(["10", "30", "100", "300", "1000"]))
ax2.xaxis.set_minor_locator(NullLocator())
ax1.set_title("Binaural quality")
ax2.set_title("Interaural level error")
ax1.legend(loc="lower right", fontsize=8, framealpha=0.9)

fig.text(0.5, 0.015,
         "Same source material throughout. Codec conditions compare the corrected decode of the reference against the\n"
         "corrected decode of coded audio; the defect compares the corrected decode against upstream's decode of the SAME\n"
         "uncoded reference, so no codec loss is involved in the red point. Worse is to the right on both panels.",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.5)

fig.tight_layout(rect=(0, 0.14, 1, 1))
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"aac-bitrate-test/bamq-decoder-defect-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
