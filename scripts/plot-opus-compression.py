#!/usr/bin/env python3
"""Compression-level quality figure for the Opus study (opus-compression-test/RESULTS.md).

Regenerates opus-compression-test/compression-level-<date>.{png,svg} from the
RESULTS.md numbers, where <date> is the YYYY-MM the measurement was taken (not
the day the plot was drawn). Pass it explicitly:

    python3 scripts/plot-opus-compression.py 2026-08

The figure exists to make one argument visible that the table can only assert:
every excerpt except piano moved *up* when the encoder was asked to do less
work. That cannot be a real quality gain, so the upward spread is the metric's
own noise on this material, and the honest way to read piano's loss is against
that spread rather than against zero. The shaded band is therefore drawn at the
largest non-piano excursion in each metric (+0.0091 LQ, +0.0171 LA); piano is
the only excerpt that leaves it, at 1.8x and 2.2x respectively.

The CPU half of the study is deliberately NOT plotted. The whole saving is 0.9 %
of a core, which is the decisive argument and needs no chart; drawing it at a
readable scale would give a trivial difference the visual weight of a finding.
RESULTS.md states it as a number, which is proportionate.
"""
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

# Transcribed from the AMBIQUAL table in RESULTS.md. Deltas are against
# -compression_level 10 (libopus's default), so negative means worse.
EXCERPTS = ["solo piano", "orchestra", "dense ensemble", "live concert", "outdoor ambience"]
c5_LQ = [-0.0163, +0.0023, +0.0026, +0.0043, +0.0091]
c5_LA = [-0.0381, +0.0031, +0.0072, +0.0080, +0.0171]
c0_LQ = [-0.0202, -0.0001, -0.0005, +0.0004, +0.0056]
c0_LA = [-0.0489, +0.0018, +0.0007, -0.0011, +0.0093]

# The noise band: the largest excursion among the excerpts that cannot have
# genuinely improved. Taken from the data rather than hardcoded, so a
# re-measurement cannot leave the band describing the previous run.
noise_LQ = max(abs(v) for v in c5_LQ[1:] + c0_LQ[1:])
noise_LA = max(abs(v) for v in c5_LA[1:] + c0_LA[1:])

y = range(len(EXCERPTS))
h = 0.36

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2), sharey=True)

for ax, v5, v0, noise, metric in (
    (ax1, c5_LQ, c0_LQ, noise_LQ, "LQ (listening quality)"),
    (ax2, c5_LA, c0_LA, noise_LA, "LA (listening artefacts)"),
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
# other's extents and silently overprinted when the wording grew.
fig.text(0.5, 0.015,
         "Shaded band = largest excursion among the non-piano excerpts "
         f"(±{noise_LQ:.4f} LQ, ±{noise_LA:.4f} LA).\n"
         "Those excerpts moved UP at lower effort, which cannot be a real gain, so the band is\n"
         "the metric's noise on this material, not a confidence interval.\n"
         "16-channel Opus, -b:a 1536k, scored with AMBIQUAL.",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.5)

fig.tight_layout(rect=(0, 0.22, 1, 1))
# PNG for inline markdown / quick view; SVG (vector) for web pages and print.
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"opus-compression-test/compression-level-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
