#!/usr/bin/env python3
"""Generate the equirectangular 360 orientation card used as the visual base of
the `directions` reference clip.

This replaces the third-party card the clip previously used. That card is
CC BY-ND: attribution is fine, but compositing the ambisonic energy overlay onto
it produces Adapted Material, which ND forbids redistributing - and the clip is
published both as a release asset and on the live VOD page. Generating the card
here makes the clip ours end to end, publishable without qualification.

Layout follows the same convention as AmbisonicEnergyRenderer: azimuth runs
+180 deg at the left edge, through 0 deg at centre, to -180 deg at the right, so
left-of-centre reads LEFT and right-of-centre reads RIGHT for a viewer facing
front. Elevation runs +90 (top) to -90 (bottom); the horizon is the centre row.
Graticule cells are 30 deg square.

Matplotlib is used rather than ffmpeg's drawtext because it ships its own font:
drawtext needs an ffmpeg built with libfreetype plus a system font path that
differs per machine, and many builds (including Homebrew's default) omit it.

Usage: scripts/make-orientation-card.py [-o OUT] [--width W] [--height H]
  defaults: content/vod/masters/orientation-card_8k.png 7680x3840
"""
import argparse

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BG      = "#11161c"
GRID    = "#33404d"
HORIZON = "#8a97a3"
MERID   = "#5a6875"
FRONT   = "#00a89a"
FRONT_T = "#00d8c6"
CARD_T  = "#e8eef4"
DIM_T   = "#a8b4c0"
TICK_T  = "#7a8794"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-o", "--out", default="content/vod/masters/orientation-card_8k.png")
    ap.add_argument("--width", type=int, default=7680)
    ap.add_argument("--height", type=int, default=3840)
    args = ap.parse_args()

    W, H, dpi = args.width, args.height, 100
    k = W / 7680.0  # scale strokes and type so any size looks identical

    fig = plt.figure(figsize=(W / dpi, H / dpi), dpi=dpi, facecolor=BG)
    ax = fig.add_axes([0, 0, 1, 1])          # full bleed, no margins
    ax.set_xlim(180, -180)                   # azimuth: +180 left -> -180 right
    ax.set_ylim(-90, 90)                     # elevation: -90 bottom -> +90 top
    ax.set_facecolor(BG)
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)

    # 30 deg graticule
    for az in range(-180, 181, 30):
        ax.axvline(az, color=GRID, lw=3 * k, zorder=1)
    for el in range(-90, 91, 30):
        ax.axhline(el, color=GRID, lw=3 * k, zorder=1)

    # horizon and the cardinal meridians
    ax.axhline(0, color=HORIZON, lw=7 * k, zorder=2)
    ax.axvline(90, color=MERID, lw=6 * k, zorder=2)     # LEFT
    ax.axvline(-90, color=MERID, lw=6 * k, zorder=2)    # RIGHT
    ax.axvline(0, color=FRONT, lw=10 * k, zorder=3)     # FRONT

    # azimuth ticks every 30 deg, just below the horizon
    for az in range(-150, 151, 30):
        if az == 0:
            continue
        ax.text(az, -4, "%+d" % az, color=TICK_T, fontsize=34 * k,
                ha="center", va="top", zorder=4)

    # elevation ticks up the front meridian, so height is readable too
    for el in range(-60, 61, 30):
        if el == 0:
            continue
        ax.text(-3, el, "%+d" % el, color=TICK_T, fontsize=34 * k,
                ha="left", va="center", zorder=4)

    # cardinals, sitting above the horizon on their own meridians
    big = dict(fontsize=108 * k, weight="bold", zorder=5)
    ax.text(0, 5, "FRONT", color=FRONT_T, ha="center", va="bottom", **big)
    ax.text(90, 5, "LEFT", color=CARD_T, ha="center", va="bottom", **big)
    ax.text(-90, 5, "RIGHT", color=CARD_T, ha="center", va="bottom", **big)
    ax.text(176, 5, "BACK", color=DIM_T, ha="left", va="bottom", **big)
    ax.text(-176, 5, "BACK", color=DIM_T, ha="right", va="bottom", **big)
    ax.text(0, 72, "UP", color=DIM_T, ha="center", va="center", **big)
    ax.text(0, -72, "DOWN", color=DIM_T, ha="center", va="center", **big)

    fig.savefig(args.out, dpi=dpi, facecolor=BG)
    print("wrote %s  (%dx%d equirectangular, 30 deg graticule, "
          "azimuth +180 left to -180 right)" % (args.out, W, H))


if __name__ == "__main__":
    main()
