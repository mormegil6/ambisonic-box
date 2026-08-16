#!/usr/bin/env python3
"""Segment-duration trade-off figure for the lip-sync measurement (lip-sync-test/RESULTS.md).

Regenerates lip-sync-test/segment-tradeoff-<date>.{png,svg} from the RESULTS.md
numbers, where <date> is the YYYY-MM the measurement was taken (not the day the
plot was drawn). Pass it explicitly:

    python3 scripts/plot-segment-tradeoff.py 2026-06

The date is part of the filename so a re-measurement lands beside its
predecessor instead of overwriting it: the figures are cited from RESULTS.md and
from the project page at https://bmroz.eu/projects/360-livestream/, and a
silently-replaced figure would leave those captions describing data that is no
longer in the image.

The A/V offset is a flat 0 ms across all durations (combined-MPD single
media-element clock), so it is stated as a note rather than plotted. What varies
is bitrate and buffer depth. Buffer depth is a fluctuating level, drawn as a
min-max band rather than error bars: with n=3 runs and a structurally-zero sync
result, confidence intervals would imply noise that is not there.
"""
import re
import sys

# Argument check before the matplotlib import, so a usage mistake reports itself
# even on a host that has not installed the plotting dependency.
if len(sys.argv) != 2 or not re.fullmatch(r"\d{4}-\d{2}", sys.argv[1]):
    sys.exit(
        "usage: plot-segment-tradeoff.py YYYY-MM\n"
        "\n"
        "  YYYY-MM is the month the MEASUREMENT was taken, per the Date line in\n"
        "  lip-sync-test/RESULTS.md. The figures currently in the tree are 2026-06.\n"
        "\n"
        "  It is required rather than defaulted to the current month on purpose.\n"
        "  This script does not measure anything: it plots numbers transcribed\n"
        "  into the arrays below from RESULTS.md. Re-running it to adjust styling\n"
        "  would then stamp a fresh month onto old data and write a file whose\n"
        "  name asserts a measurement that never happened. Passing the month\n"
        "  explicitly also keeps the script idempotent: the same data always\n"
        "  produces the same filename, whenever it is run.\n"
        "\n"
        "  The date is in the filename so a re-measurement lands beside its\n"
        "  predecessor rather than overwriting it. These figures are cited from\n"
        "  RESULTS.md and from https://bmroz.eu/projects/360-livestream/, and a\n"
        "  silently-replaced figure would leave both captions describing data\n"
        "  that is no longer in the image."
    )
MEASURED = sys.argv[1]

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

seg = [0.5, 1, 2, 4]
bitrate = [43, 11, 7.5, 5.8]          # effective video bitrate, Mbps
buf_lo = [0.4, 3, 9, 15]              # buffer depth band, seconds
buf_hi = [0.6, 5, 12, 20]
buf_mid = [(a + b) / 2 for a, b in zip(buf_lo, buf_hi)]

# Left-right, not top-bottom: matches the other figures in this repo
# (plot-opus-compression.py, plot-aac-bitrate.py, plot-bamq.py), all 1x2.
# This one was the odd one out at 2x1.
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.8))

ax1.plot(seg, bitrate, "o-", color="#c0392b", lw=2, ms=7)
ax1.set_ylabel("Effective video bitrate (Mbps)")
ax1.set_title("Effective video bitrate")
ax1.grid(True, alpha=0.3)

ax2.fill_between(seg, buf_lo, buf_hi, color="#2980b9", alpha=0.25)
ax2.plot(seg, buf_mid, "o-", color="#2980b9", lw=2, ms=7)
ax2.set_ylabel("Playback buffer depth (s)")
ax2.set_title("Playback buffer depth")
ax2.grid(True, alpha=0.3)

for ax in (ax1, ax2):
    ax.set_xlabel("Segment duration (s)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(seg)
    ax.set_xticklabels([f"{s:g}" for s in seg])
    ax.set_xlim(0.4, 5)
    ax.axvspan(1.8, 2.2, color="#27ae60", alpha=0.10)   # chosen
    ax.axvspan(0.45, 0.55, color="#c0392b", alpha=0.10)  # not viable

ax1.annotate("0.5 s: ~6x bitrate, stalls", (0.5, 43),
             textcoords="offset points", xytext=(26, -4),
             fontsize=8, color="#c0392b")
ax2.annotate("2 s: chosen", (2, buf_mid[2]),
             textcoords="offset points", xytext=(10, -20),
             fontsize=9, color="#1e7e34")

fig.text(0.5, 0.02,
         "DASH segment-duration trade-off, 4K VP9, combined-MPD.\n"
         "A/V offset: 0 ms at every duration (single media-element clock). Buffer shown as min-max band, not error bars.",
         ha="center", va="bottom", fontsize=8, style="italic", linespacing=1.5)

fig.tight_layout(rect=(0, 0.12, 1, 1))
# PNG for inline markdown / quick view; SVG (vector) for web pages and print.
for ext, kw in (("png", {"dpi": 160}), ("svg", {})):
    out = f"lip-sync-test/segment-tradeoff-{MEASURED}.{ext}"
    fig.savefig(out, **kw)
    print("wrote", out)
