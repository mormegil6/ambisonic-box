#!/usr/bin/env python3
"""Segment-duration trade-off figure for the Phase 5 lip-sync measurement.

Regenerates lip-sync-test/segment-tradeoff.png from the RESULTS.md numbers.

The A/V offset is a flat 0 ms across all durations (combined-MPD single
media-element clock), so it is stated as a note rather than plotted. What varies
is bitrate and buffer depth. Buffer depth is a fluctuating level, drawn as a
min-max band rather than error bars: with n=3 runs and a structurally-zero sync
result, confidence intervals would imply noise that is not there.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

seg = [0.5, 1, 2, 4]
bitrate = [43, 11, 7.5, 5.8]          # effective video bitrate, Mbps
buf_lo = [0.4, 3, 9, 15]              # buffer depth band, seconds
buf_hi = [0.6, 5, 12, 20]
buf_mid = [(a + b) / 2 for a, b in zip(buf_lo, buf_hi)]

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(7, 6), sharex=True)

ax1.plot(seg, bitrate, "o-", color="#c0392b", lw=2, ms=7)
ax1.set_ylabel("Effective video bitrate (Mbps)")
ax1.set_title("DASH segment-duration trade-off (4K VP9, combined-MPD)")
ax1.grid(True, alpha=0.3)

ax2.fill_between(seg, buf_lo, buf_hi, color="#2980b9", alpha=0.25)
ax2.plot(seg, buf_mid, "o-", color="#2980b9", lw=2, ms=7)
ax2.set_ylabel("Playback buffer depth (s)")
ax2.set_xlabel("Segment duration (s)")
ax2.grid(True, alpha=0.3)

for ax in (ax1, ax2):
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

fig.text(0.5, 0.005,
         "A/V offset: 0 ms at every duration (combined-MPD single clock). "
         "Buffer shown as min-max band, not error bars.",
         ha="center", fontsize=8, style="italic")

fig.tight_layout(rect=(0, 0.03, 1, 1))
out = "lip-sync-test/segment-tradeoff.png"
fig.savefig(out, dpi=160)
print("wrote", out)
