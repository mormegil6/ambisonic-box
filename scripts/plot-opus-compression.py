#!/usr/bin/env python3
"""Compression-level quality figure for the Opus study (opus-compression-test/RESULTS.md).

Regenerates opus-compression-test/compression-level-<date>.{png,svg} from
opus-compression-test/results.tsv, where <date> is the YYYY-MM the measurement
was taken (not
the day the plot was drawn). Pass it explicitly:

    python3 scripts/plot-opus-compression.py 2026-08

The figure exists to make one argument visible that the table can only assert:
every excerpt except piano moved *up* when the encoder was asked to do less
work. That cannot be a real quality gain, so the upward spread is the metric's
own noise on this material, and the honest way to read piano's loss is against
that spread rather than against zero. The shaded band is therefore drawn at the
largest non-piano excursion in each metric, computed from the data rather than
stated here, so this comment cannot go stale against a re-measurement.

The CPU half of the study is deliberately NOT plotted. The whole saving is 0.9 %
of a core, which is the decisive argument and needs no chart; drawing it at a
readable scale would give a trivial difference the visual weight of a finding.
RESULTS.md states it as a number, which is proportionate.
"""
import csv
import pathlib
import re
import sys

# Argument check before the matplotlib import, so a usage mistake reports itself
# even on a host that has not installed the plotting dependency.
if len(sys.argv) != 2 or not re.fullmatch(r"\d{4}-\d{2}", sys.argv[1]):
    sys.exit(
        "usage: plot-opus-compression.py YYYY-MM\n"
        "\n"
        "  YYYY-MM is the month the MEASUREMENT was taken, per the Date line in\n"
        "  opus-compression-test/RESULTS.md. The figure in the tree is 2026-08.\n"
        "\n"
        "  Required rather than defaulted to the current month, for the same\n"
        "  reason as plot-segment-tradeoff.py: this script does not measure\n"
        "  anything. It plots numbers transcribed from RESULTS.md, so defaulting\n"
        "  would let a styling tweak stamp a fresh month onto old data and write\n"
        "  a filename asserting a measurement that never happened."
    )
MEASURED = sys.argv[1]

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# READ THE MEASUREMENT, DO NOT TRANSCRIBE IT. These deltas used to be copied by
# hand out of the AMBIQUAL table in RESULTS.md. A 2026-08-22 re-run updated the
# table and not this file, so the committed figure plotted the superseded run
# underneath the new numbers - its noise band drawn at +/-0.0091 while the text
# beside it said +0.0101. Reading results.tsv makes that class of drift
# impossible.
#
# Deltas are against -compression_level 10 (what FFmpeg's libopus encoder
# applies when the flag is absent), so negative means worse.
ITEMS = [("piano", "solo piano"), ("orchestra", "orchestra"),
         ("deusexmachina", "dense ensemble"), ("carnival", "live concert"),
         ("quarry", "outdoor ambience")]
TSV = pathlib.Path(__file__).resolve().parent.parent / "opus-compression-test" / "results.tsv"
if not TSV.exists():
    sys.exit(f"no measurement at {TSV} - run scripts/measure-opus-compression.sh first")
scores = {}
with TSV.open() as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        scores[(row["item"], row["level"])] = (float(row["LQ"]), float(row["LA"]))
missing = [(i, l) for i, _ in ITEMS for l in ("10", "5", "0") if (i, l) not in scores]
if missing:
    sys.exit(f"{TSV} is missing rows: {missing}")

EXCERPTS = [label for _, label in ITEMS]
c5_LQ = [scores[(i, "5")][0] - scores[(i, "10")][0] for i, _ in ITEMS]
c5_LA = [scores[(i, "5")][1] - scores[(i, "10")][1] for i, _ in ITEMS]
c0_LQ = [scores[(i, "0")][0] - scores[(i, "10")][0] for i, _ in ITEMS]
c0_LA = [scores[(i, "0")][1] - scores[(i, "10")][1] for i, _ in ITEMS]

# The noise band: the largest excursion among the excerpts that cannot have
# genuinely improved.
noise_LQ = max(abs(v) for v in c5_LQ[1:] + c0_LQ[1:])
noise_LA = max(abs(v) for v in c5_LA[1:] + c0_LA[1:])

y = range(len(EXCERPTS))
h = 0.36

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2), sharey=True)

for ax, v5, v0, noise, metric in (
    (ax1, c5_LQ, c0_LQ, noise_LQ, "LQ (listening quality)"),
    (ax2, c5_LA, c0_LA, noise_LA, "LA (localisation)"),
):
    ax.axvspan(-noise, noise, color="#7f8c8d", alpha=0.16, zorder=0)
    ax.barh([i + h / 2 for i in y], v5, height=h, color="#2980b9",
            label="-compression_level 5", zorder=2)
    ax.barh([i - h / 2 for i in y], v0, height=h, color="#c0392b",
            label="-compression_level 0", zorder=2)
    ax.axvline(0, color="#2c3e50", lw=1, zorder=3)
    ax.set_xlabel(f"Δ {metric}  (vs level 10, negative = worse)")
    ax.grid(True, axis="x", alpha=0.3, zorder=1)

ax1.set_yticks(list(y))
ax1.set_yticklabels(EXCERPTS)
ax1.set_title("Quality change when libopus is asked to do less work")
ax2.set_title("Piano is the only excerpt outside the noise band")
# Upper left of the LEFT panel: the only quadrant no bar reaches into, since
# every non-piano excerpt is small and piano is at the bottom row.
ax1.legend(loc="upper left", fontsize=8, framealpha=0.9)

# One text block, not two: separate fig.text calls do not know about each
# other's extents and silently overprinted when the wording grew. Line breaks
# are placed by hand to keep each line's WIDTH roughly even - `ha="center"`
# centers each line independently, so four lines of uneven length (as an
# earlier version had) reads as ragged/zigzagged rather than as one block.
fig.text(0.5, 0.015,
         f"Shaded band = largest excursion among the non-piano excerpts (±{noise_LQ:.4f} LQ, ±{noise_LA:.4f} LA).\n"
         "Those excerpts moved UP at lower effort, which cannot be a real gain, so the band is the metric's noise\n"
         "on this material, not a confidence interval. 16-channel Opus, -b:a 1536k, scored with AMBIQUAL.",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.5)

fig.tight_layout(rect=(0, 0.22, 1, 1))
# PNG for inline markdown / quick view; SVG (vector) for web pages and print.
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"opus-compression-test/compression-level-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
