#!/usr/bin/env python3
"""Generate an equirectangular 360 test card from six flat test screens.

WHY A CUBE
Drawing a test pattern directly in equirectangular space (as
make-orientation-card.py does) tests orientation but not the imaging chain: the
pattern is pre-distorted, so nothing in it has a known shape once the viewer
re-projects it. A broadcast test card only means something when it reaches the
eye undistorted.

So this builds the card the way real 360 test content does: six flat cards are
rendered in VIEW space and arranged as the six walls of a cube around the
viewer, then inverse-projected into equirectangular. Each face spans exactly
90 deg, which is what a 360 viewer shows at a normal field of view, so when you
turn to face a wall you see a flat, undistorted test card - circles are round,
straight lines are straight, and any bend is the pipeline's fault, not the
projection's. The poles stop being smeared blobs and become ordinary walls
(ceiling and floor), testable like any other.

GEOMETRY
World axes follow Ambisonic ACN/SN3D, the same frame the rest of this repo
uses: +X front, +Y left, +Z up. The equirect convention matches
make-orientation-card.py and AmbisonicEnergyRenderer: azimuth +180 at the left
edge through 0 at centre to -180 at the right, elevation +90 top to -90 bottom.
So the left half of the image is what is to the viewer's left.

Each face image has local coordinates (s, t) in [-1, +1], s left->right and t
top->bottom (t increases downward, matching image row order). The forward maps
below are chosen so every face reads UPRIGHT and UNMIRRORED from inside:

    FRONT +X   dir = ( 1, -s, -t)
    BACK  -X   dir = (-1,  s, -t)
    LEFT  +Y   dir = ( s,  1, -t)
    RIGHT -Y   dir = (-s, -1, -t)
    UP    +Z   dir = ( t, -s,  1)
    DOWN  -Z   dir = (-t, -s, -1)

The two polar faces need an explicit tie-break, since "upright" is degenerate
at a pole. The one used here: a viewer facing FRONT who pitches their head up
90 deg sees the ceiling upright, and likewise pitching down 90 deg sees the
floor upright. Pitching up puts BACK at the top of your visual field, so the
ceiling card's top edge points BACK; pitching down puts FRONT at the top, so
the floor card's top edge points FRONT. That is the single easiest sign to get
wrong, which is why --pattern dummy exists.

SAMPLING
Faces are rendered at supersample x the density that maps 1:1 at the face
centre, and the equirect is itself sampled supersample x and box-reduced. Both
matter: gnomonic projection compresses a face by up to 2x toward its edges, so
naive point sampling aliases exactly where the resolution wedges are supposed
to be read.

Pillow does the drawing (pixel-exact primitives), numpy the projection, and
matplotlib is used ONLY to locate a font file - it bundles DejaVu, so there is
no per-machine font path to guess, the same reason make-orientation-card.py
uses it.

Usage: scripts/make-360-testcard.py [-o OUT] [--width W] [--pattern dummy|card]
                                    [--supersample N] [--faces-out DIR]
  defaults: content/vod/masters/testcard-360_8k.png, 7680x3840
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# faces in a fixed order; the string is also the face's label
FACES = ("front", "right", "back", "left", "up", "down")


# --------------------------------------------------------------------------
# fonts
# --------------------------------------------------------------------------
def font_path(family="DejaVu Sans"):
    """Absolute path to a TTF that is guaranteed to exist wherever matplotlib
    is installed, because matplotlib ships it."""
    from matplotlib import font_manager as fm
    return fm.findfont(fm.FontProperties(family=family))


_FONT_CACHE = {}


def font(size, family="DejaVu Sans"):
    key = (family, int(size))
    if key not in _FONT_CACHE:
        _FONT_CACHE[key] = ImageFont.truetype(font_path(family), int(size))
    return _FONT_CACHE[key]


# --------------------------------------------------------------------------
# validation pattern
# --------------------------------------------------------------------------
DUMMY_BG = {
    "front": (0, 108, 100),
    "right": (150, 45, 35),
    "back":  (85, 45, 110),
    "left":  (25, 75, 130),
    "up":    (85, 105, 45),
    "down":  (105, 70, 35),
}


def render_dummy_face(name, size):
    """A face whose orientation is unmistakable.

    Every symmetry a bug could hide behind is broken on purpose: the word reads
    left-to-right (catches mirroring), an arrow points at the card's top edge
    (catches flips), the corners are numbered clockwise from top-left (catches
    90 deg rotations), one diagonal is drawn (catches transposes), and each
    edge midpoint is labelled with the direction it should be pointing at once
    projected (catches everything else).
    """
    F = size
    img = Image.new("RGB", (F, F), DUMMY_BG[name])
    d = ImageDraw.Draw(img)
    k = F / 1024.0                                  # scale everything off 1024

    # checkerboard frame: shows the seam between adjacent faces
    cell = F // 32
    for n in range(32):
        for (cx, cy) in ((n, 0), (n, 31), (0, n), (31, n)):
            if (cx + cy) % 2 == 0:
                d.rectangle([cx * cell, cy * cell,
                             (cx + 1) * cell - 1, (cy + 1) * cell - 1],
                            fill=(235, 235, 235))

    # one diagonal, top-left to bottom-right: a transpose or mirror moves it
    d.line([(cell, cell), (F - cell, F - cell)], fill=(255, 210, 0),
           width=int(4 * k))

    # the face name, big, reading left to right
    d.text((F / 2, F * 0.46), name.upper(), font=font(120 * k),
           fill=(255, 255, 255), anchor="mm")

    # arrow pointing at the card's TOP edge
    ax, ay, h = F / 2, F * 0.30, F * 0.10
    d.line([(ax, ay), (ax, ay + h)], fill=(255, 255, 255), width=int(8 * k))
    d.polygon([(ax, ay - h * 0.45), (ax - h * 0.28, ay + h * 0.05),
               (ax + h * 0.28, ay + h * 0.05)], fill=(255, 255, 255))

    # corners, numbered clockwise from top-left
    m = cell * 2.4
    for label, (px, py, anch) in {
        "1": (m, m, "lt"), "2": (F - m, m, "rt"),
        "3": (F - m, F - m, "rb"), "4": (m, F - m, "lb"),
    }.items():
        d.text((px, py), label, font=font(64 * k), fill=(255, 255, 255),
               anchor=anch)

    # what each edge should be pointing at once projected: top, bottom, left,
    # right. Read these off the projected equirect to check every face.
    edges = {
        "front": ("UP", "DOWN", "LEFT", "RIGHT"),
        "right": ("UP", "DOWN", "FRONT", "BACK"),
        "back":  ("UP", "DOWN", "RIGHT", "LEFT"),
        "left":  ("UP", "DOWN", "BACK", "FRONT"),
        "up":    ("BACK", "FRONT", "LEFT", "RIGHT"),
        "down":  ("FRONT", "BACK", "LEFT", "RIGHT"),
    }[name]
    f = font(34 * k)
    d.text((F / 2, cell * 3.2), "^ " + edges[0], font=f, fill=(255, 255, 255),
           anchor="mt")
    d.text((F / 2, F - cell * 3.2), "v " + edges[1], font=f,
           fill=(255, 255, 255), anchor="mb")
    d.text((cell * 3.2, F / 2), "< " + edges[2], font=f, fill=(255, 255, 255),
           anchor="lm")
    d.text((F - cell * 3.2, F / 2), edges[3] + " >", font=f,
           fill=(255, 255, 255), anchor="rm")

    return np.asarray(img, dtype=np.uint8)


# --------------------------------------------------------------------------
# the test card itself
# --------------------------------------------------------------------------
# Elements are the standard broadcast test-card vocabulary - EBU colour bars, a
# grey staircase, PLUGE, a multiburst, a Siemens star - arranged for a square
# face. That vocabulary is public and decades old (PM5544, Test Card F, EBU
# 3325); what is ours is the layout, the code, and the 360 arrangement.
#
# The card is authored in full-range RGB. The delivery encode is limited range
# (see CLAUDE.md: VP9/AV1 must be tv range), so 0 and 255 land on the clipping
# boundaries at 16 and 235 - which is precisely what the PLUGE block is for. If
# the sub-black bar is visible, something is expanding range it should not.

BG      = (18, 18, 18)
MESH    = (58, 58, 58)
DIAG    = (96, 96, 96)
INK     = (238, 238, 238)
DIM     = (150, 150, 150)
ACCENT  = (0, 216, 198)

# EBU 75 % colour bars, descending luminance
BARS = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
        (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]

# face centre direction, for the caption under the label
FACE_AZ_EL = {"front": (0, 0), "right": (-90, 0), "back": (180, 0),
              "left": (90, 0), "up": (0, 90), "down": (0, -90)}


def _siemens(n, spokes=72, ss=3):
    """Radial spoke pattern, antialiased, with a circular alpha mask.

    A Siemens star is a superset of the converging frequency wedges on a
    classic card: it sweeps every spatial frequency at every orientation at
    once, so the radius where the spokes turn to mush IS the delivered
    resolution, read directly off the picture.
    """
    m = n * ss
    g = (np.arange(m, dtype=np.float32) + 0.5) / m * 2.0 - 1.0
    X, Y = np.meshgrid(g, g)
    th = np.arctan2(Y, X)
    v = np.floor(th / (2 * np.pi) * (2 * spokes)) % 2
    a = (np.hypot(X, Y) <= 1.0).astype(np.float32)
    v = v.reshape(n, ss, n, ss).mean(axis=(1, 3))
    a = a.reshape(n, ss, n, ss).mean(axis=(1, 3))
    lum = (16.0 + v * (235.0 - 16.0)).astype(np.uint8)
    rgba = np.dstack([lum, lum, lum, (a * 255).astype(np.uint8)])
    return Image.fromarray(rgba, "RGBA")


def _checker_block(n, pitches):
    """2x2 grid of checkerboards; pitches are in face pixels."""
    out = np.zeros((n, n), np.uint8)
    h = n // 2
    for q, p in enumerate(pitches):
        oy, ox = (q // 2) * h, (q % 2) * h
        g = np.arange(h)
        X, Y = np.meshgrid(g, g)
        out[oy:oy + h, ox:ox + h] = ((X // p + Y // p) % 2) * 219 + 16
    return Image.fromarray(np.dstack([out] * 3), "RGB")


def _multiburst(n, pitches):
    """Vertical bar bursts, coarse to fine, left to right."""
    out = np.zeros((n, n), np.uint8)
    w = n // len(pitches)
    for i, p in enumerate(pitches):
        g = np.arange(w)
        out[:, i * w:(i + 1) * w] = ((g // p) % 2) * 219 + 16
    return Image.fromarray(np.dstack([out] * 3), "RGB")


def _noise_block(n, seed=360):
    """Band-limited, mostly-luminance noise: a synthetic stand-in for natural
    detail, so the card exercises the encoder the way a photographic texture
    would. Kept low in chroma on purpose - saturated confetti would be
    destroyed by 4:2:0 subsampling and tell you nothing the colour bars do not
    already say, whereas luminance detail is what a codec actually spends its
    bits on."""
    m = max(3, n // 10)
    rng = np.random.default_rng(seed)
    lum = rng.integers(28, 228, size=(m, m), dtype=np.int16)
    chroma = rng.integers(-22, 23, size=(m, m, 3), dtype=np.int16)
    lo = np.clip(lum[:, :, None] + chroma, 0, 255).astype(np.uint8)
    return Image.fromarray(lo, "RGB").resize((n, n), Image.BICUBIC)


def _rot_text(img, cx, cy, text, fnt, fill, angle):
    d = ImageDraw.Draw(img)
    b = d.textbbox((0, 0), text, font=fnt)
    tmp = Image.new("RGBA", (b[2] - b[0] + 8, b[3] - b[1] + 8), (0, 0, 0, 0))
    ImageDraw.Draw(tmp).text((-b[0] + 4, -b[1] + 4), text, font=fnt,
                             fill=fill + (255,))
    if angle:
        tmp = tmp.rotate(angle, expand=True, resample=Image.BICUBIC)
    img.paste(tmp, (int(cx - tmp.width / 2), int(cy - tmp.height / 2)), tmp)


def render_card_face(name, size, ss=2):
    """One flat test screen. `ss` is face pixels per delivered pixel at the
    face centre, so fine detail can be specified in DELIVERED pixels and mean
    the same thing at any output resolution."""
    F = size
    k = F / 1024.0                       # type and stroke scale
    d_ = max(1, int(round(ss)))          # one delivered pixel, in face pixels
    P = lambda u: int(round(u * F))      # noqa: E731  normalised -> pixels

    img = Image.new("RGB", (F, F), BG)
    d = ImageDraw.Draw(img)

    # -- background mesh: geometry, plus a moire target ---------------------
    step = F / 16.0
    for i in range(1, 16):
        d.line([(i * step, P(0.035)), (i * step, P(0.965))], fill=MESH,
               width=max(1, int(2 * k)))
        d.line([(P(0.035), i * step), (P(0.965), i * step)], fill=MESH,
               width=max(1, int(2 * k)))

    # -- diagonal stubs: linearity, and they must stay straight in a viewer -
    for (x0, y0, x1, y1) in ((0.13, 0.13, 0.33, 0.33), (0.87, 0.13, 0.67, 0.33),
                             (0.87, 0.87, 0.67, 0.67), (0.13, 0.87, 0.33, 0.67)):
        d.line([(P(x0), P(y0)), (P(x1), P(y1))], fill=DIAG,
               width=max(1, int(3 * k)))

    # -- EBU 75 % colour bars ----------------------------------------------
    bx0, bx1, by0, by1 = P(0.155), P(0.845), P(0.085), P(0.175)
    bw = (bx1 - bx0) / len(BARS)
    for i, c in enumerate(BARS):
        d.rectangle([bx0 + i * bw, by0, bx0 + (i + 1) * bw - 1, by1], fill=c)
    d.rectangle([bx0, by0, bx1, by1], outline=DIM, width=max(1, int(2 * k)))

    # -- grey staircase: gamma and banding ----------------------------------
    sx0, sx1, sy0, sy1 = P(0.155), P(0.845), P(0.825), P(0.915)
    steps = 11
    sw = (sx1 - sx0) / steps
    for i in range(steps):
        v = int(round(255 * i / (steps - 1)))
        d.rectangle([sx0 + i * sw, sy0, sx0 + (i + 1) * sw - 1, sy1],
                    fill=(v, v, v))
    d.rectangle([sx0, sy0, sx1, sy1], outline=DIM, width=max(1, int(2 * k)))
    d.text((sx0, sy1 + 6 * k), "0%", font=font(26 * k), fill=DIM, anchor="lt")
    d.text((sx1, sy1 + 6 * k), "100%", font=font(26 * k), fill=DIM, anchor="rt")

    # -- face identity, above the blocks ------------------------------------
    az, el = FACE_AZ_EL[name]
    d.text((F / 2.0, P(0.205)), "az %d°   ·   el %d°" % (az, el),
           font=font(28 * k), fill=ACCENT, anchor="mm")

    # -- the four corner blocks ---------------------------------------------
    # Captions sit above the lower pair and below the upper pair, keeping the
    # four mid-edge wordmarks' lanes clear.
    n = P(0.17)
    blocks = (
        (0.075, 0.230, _checker_block(n, [d_, 2 * d_, 4 * d_, 8 * d_]),
         "CHECKER 1·2·4·8"),
        (0.755, 0.230, _noise_block(n), "DETAIL"),
        (0.075, 0.600, _multiburst(n, [8 * d_, 6 * d_, 4 * d_, 3 * d_,
                                       2 * d_, d_]), "MULTIBURST"),
        (0.755, 0.600, None, "PLUGE"),
    )
    for ux, uy, blk, cap in blocks:
        x, y = P(ux), P(uy)
        if blk is not None:
            img.paste(blk, (x, y))
        else:
            # PLUGE, darkest to brightest: sub-black, black, above-black, then
            # the limited-range white point and beyond. Under a correct tv-range
            # encode the sub-black bar is invisible and the above-black bar is
            # just visible; seeing both means something expanded the range.
            vals = [0, 8, 16, 24, 128, 235, 243, 255]
            bh = n / len(vals)
            for i, v in enumerate(vals):
                d.rectangle([x, y + i * bh, x + n - 1, y + (i + 1) * bh - 1],
                            fill=(v, v, v))
        d.rectangle([x, y, x + n - 1, y + n - 1], outline=DIM,
                    width=max(1, int(2 * k)))
        if uy < 0.5:
            d.text((x + n / 2, y + n + 7 * k), cap, font=font(24 * k),
                   fill=DIM, anchor="mt")
        else:
            d.text((x + n / 2, y - 7 * k), cap, font=font(24 * k), fill=DIM,
                   anchor="mb")

    # -- centre: Siemens star, colour rings, crosshair -----------------------
    cx, cy = F / 2.0, F / 2.0
    star_r = P(0.135)
    star = _siemens(star_r * 2)
    img.paste(star, (int(cx - star_r), int(cy - star_r)), star)
    for rr, col in ((0.150, (220, 40, 40)), (0.165, (40, 200, 60)),
                    (0.180, (60, 110, 240)), (0.195, INK)):
        r = P(rr)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col,
                  width=max(1, int(4 * k)))
    # the big inscribed circle: must stay circular, must not clip at the edges
    r = P(0.46)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=INK,
              width=max(1, int(3 * k)))
    # Solid hub, because the spokes are unresolvable at the very centre.
    #
    # The crosshair is broken at the exact centre on purpose. Equirectangular
    # projection stretches a face's centre PIXEL across a whole image row at
    # the pole, so whatever colour sits at the centre of the UP and DOWN cards
    # becomes a solid band along the top and bottom edges of the output. A
    # crosshair drawn through it paints that band accent-coloured and it reads
    # as a rendering fault. Leaving the centre at background level makes the
    # pole row disappear into the card instead. The inner ring survives as a
    # deliberate marker: a circle of radius r on a polar face lands at constant
    # elevation 90 - atan(r), so it draws a clean latitude line near the pole.
    hub = P(0.038)
    d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=BG, outline=ACCENT,
              width=max(1, int(3 * k)))
    ring = hub * 0.42
    d.ellipse([cx - ring, cy - ring, cx + ring, cy + ring], outline=ACCENT,
              width=max(1, int(2 * k)))
    gap = hub * 0.62
    for x0, y0, x1, y1 in ((-2.6, 0, -gap / hub, 0), (gap / hub, 0, 2.6, 0),
                           (0, -2.6, 0, -gap / hub), (0, gap / hub, 0, 2.6)):
        d.line([(cx + x0 * hub, cy + y0 * hub), (cx + x1 * hub, cy + y1 * hub)],
               fill=ACCENT, width=max(1, int(3 * k)))

    # -- wordmark at four orientations: legibility and rotation check --------
    wf = font(30 * k)
    for cxx, cyy, ang in ((0.5, 0.272, 0), (0.5, 0.728, 180),
                          (0.272, 0.5, 90), (0.728, 0.5, 270)):
        _rot_text(img, P(cxx), P(cyy), "HOA 360", wf, DIM, ang)

    # -- the name of the wall you are looking at -----------------------------
    d.text((cx, P(0.790)), name.upper(), font=font(68 * k), fill=INK,
           anchor="mm")

    # -- corner targets, clockwise from top-left ----------------------------
    tr = P(0.038)
    for i, (ux, uy) in enumerate(((0.085, 0.085), (0.915, 0.085),
                                  (0.915, 0.915), (0.085, 0.915)), start=1):
        x, y = P(ux), P(uy)
        d.ellipse([x - tr, y - tr, x + tr, y + tr], outline=INK,
                  width=max(1, int(3 * k)))
        d.line([(x - tr, y), (x + tr, y)], fill=INK, width=max(1, int(2 * k)))
        d.line([(x, y - tr), (x, y + tr)], fill=INK, width=max(1, int(2 * k)))
        # numbered on the inboard side, clear of the castellation
        nx = x + tr * 1.55 * (1 if ux < 0.5 else -1)
        d.text((nx, y), str(i), font=font(34 * k), fill=INK, anchor="mm")

    # -- castellation border: face seams and edge handling -------------------
    b = P(0.035)
    cell = F // 24
    for n_ in range(24):
        if n_ % 2:
            continue
        for (x, y, w_, h_) in ((n_ * cell, 0, cell, b),
                               (n_ * cell, F - b, cell, b),
                               (0, n_ * cell, b, cell),
                               (F - b, n_ * cell, b, cell)):
            d.rectangle([x, y, x + w_ - 1, y + h_ - 1], fill=INK)
    d.rectangle([0, 0, F - 1, F - 1], outline=DIM, width=max(1, int(2 * k)))

    return np.asarray(img, dtype=np.uint8)


# --------------------------------------------------------------------------
# cube -> equirectangular
# --------------------------------------------------------------------------
def _bilinear(face, px, py):
    """Sample face (F,F,3) uint8 at fractional pixel coords, clamped.

    Indexing stays on the uint8 array and only the gathered samples are
    promoted to float - keeping six 8K-grade faces in float32 would cost about
    a gigabyte for no benefit. Clamping rather than rounding also keeps the
    degenerate pole rows in range: DOWN's centre sits at row H, one past the
    last valid index.
    """
    F = face.shape[0]
    px = np.clip(px, 0.0, F - 1.0)
    py = np.clip(py, 0.0, F - 1.0)
    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    x1 = np.minimum(x0 + 1, F - 1)
    y1 = np.minimum(y0 + 1, F - 1)
    fx = (px - x0).astype(np.float32)[:, None]
    fy = (py - y0).astype(np.float32)[:, None]
    top = face[y0, x0] * (1.0 - fx) + face[y0, x1] * fx
    bot = face[y1, x0] * (1.0 - fx) + face[y1, x1] * fx
    return top * (1.0 - fy) + bot * fy


def _sample_cube(faces, x, y, z):
    """Sample the cube for flat direction arrays; returns (N,3) float32."""
    out = np.zeros(x.shape + (3,), dtype=np.float32)
    ax, ay, az = np.abs(x), np.abs(y), np.abs(z)

    # dominant axis picks the wall; ties go to x then y, which only matters on
    # the cube's edges where both faces meet at the same colour anyway
    dom_x = (ax >= ay) & (ax >= az)
    dom_y = (~dom_x) & (ay >= az)
    dom_z = ~(dom_x | dom_y)

    # (mask, face name, s, t) - the inverse of the forward maps in the header
    plan = (
        (dom_x & (x > 0), "front", lambda: (-y[m] / ax[m], -z[m] / ax[m])),
        (dom_x & (x <= 0), "back", lambda: (y[m] / ax[m], -z[m] / ax[m])),
        (dom_y & (y > 0), "left", lambda: (x[m] / ay[m], -z[m] / ay[m])),
        (dom_y & (y <= 0), "right", lambda: (-x[m] / ay[m], -z[m] / ay[m])),
        (dom_z & (z > 0), "up", lambda: (-y[m] / az[m], x[m] / az[m])),
        (dom_z & (z <= 0), "down", lambda: (-y[m] / az[m], -x[m] / az[m])),
    )

    for mask, name, st in plan:
        m = mask
        if not m.any():
            continue
        s, t = st()
        F = faces[name].shape[0]
        out[m] = _bilinear(faces[name],
                           (s + 1.0) * 0.5 * F - 0.5,
                           (t + 1.0) * 0.5 * F - 0.5)
    return out


def cube_to_equirect(faces, W, H, supersample=2, stripe_rows=128):
    """Project six face images into one equirectangular image.

    Worked in horizontal stripes so an 8K render at supersample 2 stays inside
    a couple of hundred MB rather than allocating the whole 4x grid at once.
    """
    ss = max(1, int(supersample))
    out = np.empty((H, W, 3), dtype=np.uint8)

    # columns are the same for every stripe
    ii = (np.arange(W * ss, dtype=np.float64) + 0.5) / (W * ss)
    az = np.deg2rad(180.0 - 360.0 * ii)             # +180 left -> -180 right
    cos_az, sin_az = np.cos(az), np.sin(az)

    for j0 in range(0, H, stripe_rows):
        j1 = min(j0 + stripe_rows, H)
        jj = (np.arange(j0 * ss, j1 * ss, dtype=np.float64) + 0.5) / (H * ss)
        el = np.deg2rad(90.0 - 180.0 * jj)          # +90 top -> -90 bottom
        ce, se = np.cos(el), np.sin(el)

        x = np.ravel(ce[:, None] * cos_az[None, :])         # +X front
        y = np.ravel(ce[:, None] * sin_az[None, :])         # +Y left
        z = np.repeat(se, W * ss)                           # +Z up

        block = _sample_cube(faces, x, y, z)
        block = block.reshape((j1 - j0), ss, W, ss, 3)
        out[j0:j1] = np.clip(block.mean(axis=(1, 3)) + 0.5, 0, 255) \
                       .astype(np.uint8)
    return out


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-o", "--out",
                    default="content/vod/masters/testcard-360_8k.png")
    ap.add_argument("--width", type=int, default=7680,
                    help="equirect width; height is always width/2")
    ap.add_argument("--pattern", choices=("card", "dummy"), default="card",
                    help="dummy = geometry-validation faces, for checking the "
                         "projection rather than the picture")
    ap.add_argument("--supersample", type=int, default=2,
                    help="1 for a fast preview, 2 for delivery")
    ap.add_argument("--faces-out", default=None,
                    help="also write the six flat faces to this directory")
    args = ap.parse_args()

    W = args.width
    H = W // 2
    ss = max(1, args.supersample)
    # one face px == one equirect px at the face centre, times the supersample
    F = (W // 4) * ss

    faces = {}
    for name in FACES:
        faces[name] = (render_dummy_face(name, F) if args.pattern == "dummy"
                       else render_card_face(name, F, ss=ss))
        if args.faces_out:
            os.makedirs(args.faces_out, exist_ok=True)
            Image.fromarray(faces[name]).save(
                os.path.join(args.faces_out, "face-%s.png" % name))

    eq = cube_to_equirect(faces, W, H, supersample=args.supersample)

    outdir = os.path.dirname(args.out)
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    Image.fromarray(eq).save(args.out)
    print("wrote %s  (%dx%d equirectangular, %s faces at %dpx, "
          "supersample %d)" % (args.out, W, H, args.pattern, F,
                               args.supersample))


if __name__ == "__main__":
    main()
