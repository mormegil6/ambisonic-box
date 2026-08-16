#!/usr/bin/env python3
"""BAM-Q figure: the HOAST360 decoder defect against every codec condition.

    python3 scripts/plot-bamq.py 2026-08

Reads aac-bitrate-test/bamq.tsv. Two panels, both showing the same comparison
on different axes: binQ (BAM-Q's binaural quality, 100 = no difference) and
ILDdiff (interaural level difference error, higher = worse).

Both axes read in their own natural ascending order - binQ does NOT have its
axis reversed to force "worse" onto a common side. An earlier version did
invert it so both panels agreed that worse sits to the right; reversing a
numeric axis (100...94 left to right) is a known misreading trap - a reader's
default assumption is that numbers increase left to right, and the axis label
already states which end is which ("100 = no binaural difference"), so the
inversion bought a cross-panel visual rule at the cost of a genuinely riskier
axis. The two panels now disagree on which side is worse; that is accepted
rather than hidden, and stated in the caption.

COLOUR IS SHARED ACROSS THE FIGURE FAMILY: green (#27ae60) is the AAC leg,
blue (#2980b9) is the cascade, matching plot-aac-bitrate.py's own colours for
the same two conditions, so the same hue means the same thing in both figures.
Red stays reserved for the decoder defect, which is not a codec condition at
all. An earlier version put all four codec points in one blue hue specifically
to avoid this cross-figure meaning and keep this figure's own local argument
("every codec condition clusters, the defect sits outside it") independent -
superseded once cross-figure colour consistency became the higher priority.
Validated as a triple, not assumed from the pair: `node
scripts/validate_palette.js "#27ae60,#2980b9,#c0392b" --mode light` passes
lightness, chroma and CVD separation (worst pair deltaE 20.3 deutan); it WARNs
on #27ae60's contrast against the light surface (2.8:1, below the 3:1 floor)
and requires "relief" - color is never the only way a point is identified
here, since shape and the legend both carry the same information.

Chain is carried TWICE now - colour AND marker shape (circle AAC, square
cascade) - which is deliberate redundancy for CVD/grayscale/print robustness,
not left over from the one-hue version. Rate (96 vs 128) stays marker size.
The connecting line spanning each row's four codec points is neutral grey
rather than either chain colour, since it represents the combined envelope of
both chains together and picking one chain's colour for it would misattribute
the line to that chain.
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
from matplotlib.lines import Line2D
from matplotlib.ticker import FixedLocator, FixedFormatter, NullLocator

rows = {r["label"]: r for r in csv.DictReader(open("aac-bitrate-test/bamq.tsv"), delimiter="\t")}
ITEMS = ["piano", "orchestra", "deusexmachina", "carnival", "quarry"]
CODEC = ["aac96", "aac128", "casc96", "casc128"]

C_AAC = "#27ae60"
C_CASC = "#2980b9"
C_LINE = "#7f8c8d"   # neutral: the connector spans both chains, belongs to neither
C_BUG = "#c0392b"

# marker = chain (circle AAC, square cascade), size = rate (small 96, large 128),
# color = chain again (green AAC, blue cascade) - redundant with shape on purpose.
STYLE = {
    "aac96":   dict(marker="o", s=45,  color=C_AAC),
    "aac128":  dict(marker="o", s=130, color=C_AAC),
    "casc96":  dict(marker="s", s=45,  color=C_CASC),
    "casc128": dict(marker="s", s=130, color=C_CASC),
}
CODEC_LABEL = {"aac96": "AAC 96", "aac128": "AAC 128",
               "casc96": "cascade 96", "casc128": "cascade 128"}

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.8))

for ax, key, label in (
    (ax1, "binQ", "BAM-Q binQ   (100 = no binaural difference)"),
    (ax2, "ILDdiff", "ILD error   (higher = worse)"),
):
    for y, item in enumerate(ITEMS):
        vals = [float(rows[f"{item}_{c}"][key]) for c in CODEC]
        bug = float(rows[f"{item}_DECODERBUG"][key])
        # a light connector showing the codec cluster's extent
        ax.plot([min(vals), max(vals)], [y, y], "-", color=C_LINE, lw=1.5,
                alpha=0.45, zorder=2)
        for c, v in zip(CODEC, vals):
            ax.scatter([v], [y], alpha=0.85, zorder=3,
                       edgecolors="white", linewidths=0.6, **STYLE[c])
        ax.plot([bug], [y], "D", color=C_BUG, ms=9, zorder=4)
    ax.set_yticks(range(len(ITEMS)))
    ax.set_yticklabels(ITEMS)
    ax.set_xlabel(label)
    ax.grid(True, axis="x", alpha=0.3)
    ax.invert_yaxis()

ax2.set_xscale("log")
# Explicit decade ticks: matplotlib's default log minor labels overlapped into
# an unreadable smear at this figure width.
ax2.xaxis.set_major_locator(FixedLocator([10, 30, 100, 300, 1000]))
ax2.xaxis.set_major_formatter(FixedFormatter(["10", "30", "100", "300", "1000"]))
ax2.xaxis.set_minor_locator(NullLocator())
ax1.set_title("Binaural quality")
ax2.set_title("Interaural level error")

# One shared legend spelling out every marker: shape = chain, size = rate.
# Lives in ax2's lower-left: the log-scaled ILD panel leaves that corner empty
# (every item's lowest ILD error sits well right of it), unlike ax1 where data
# spans close to the full width on every row and any interior corner collides
# with a real point (an earlier version in ax1's lower-right covered carnival).
handles = [Line2D([], [], marker=STYLE[c]["marker"], color="none",
                   markerfacecolor=STYLE[c]["color"], markeredgecolor="white",
                   markersize=(STYLE[c]["s"] / 9) ** 0.5 * 3.1, alpha=0.85,
                   label=CODEC_LABEL[c])
           for c in CODEC]
handles.append(Line2D([], [], marker="D", color="none", markerfacecolor=C_BUG,
                       markersize=8, label="decoder defect"))
ax2.legend(handles=handles, loc="lower left", fontsize=7.5, framealpha=0.92,
           labelspacing=0.6, handletextpad=0.6)

fig.text(0.5, 0.015,
         "Same source material throughout. Codec conditions compare the corrected decode of the reference against the\n"
         "corrected decode of coded audio; the defect compares the corrected decode against upstream's decode of the SAME\n"
         "uncoded reference, so no codec loss is involved in the red point. Each axis reads in its own natural direction -\n"
         "see the axis label for which way is worse; the two panels do not agree on a side, on purpose (see the script).",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.5)

fig.tight_layout(rect=(0, 0.14, 1, 1))
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"aac-bitrate-test/bamq-decoder-defect-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
