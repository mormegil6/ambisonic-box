#!/usr/bin/env python3
"""Render what the equirect-sphere tessellation error actually looks like, by
reproducing the player's faceted sampling on a still frame.

WHY
scripts/measure-sphere-distortion.py answers "how big is the error" in arcmin
and screen pixels. It cannot answer "would anyone notice", which is the question
that actually decided the mesh setting. This renders the same geometry against
the 360 test card, so the before/after is shown rather than asserted.

HOW
No browser and no screenshotting. For every pixel of a perspective view we take
the camera ray and sample the equirect source twice:

  faceted  - the UV three.js hands the fragment shader: find the quad the ray
             hits, interpolate the corner UVs linearly across the triangle
             (scripts/measure-sphere-distortion.py:faceted_uv, imported here so
             the two scripts cannot drift apart)
  exact    - the UV the equirect mapping really implies for that direction
             (dir_to_uv), i.e. what an infinitely fine mesh would sample

Sampling the source at the faceted UV *is* what the viewer sees at that mesh
resolution; sampling at the exact UV is the reference. Rendering at 32x32 and at
256x128 therefore gives a true before/after of a player-side change, from the
same bytes, with no re-encode and nothing measured by eye.

The error is a fraction of a degree, so a full-frame view shows little: pass
--zoom to narrow the FOV onto a region of fine detail, where the bowing is
resolvable. The FOV, viewport and mesh are printed into the caption strip of the
output so a figure cannot be separated from the parameters that produced it.

The source needs to out-resolve the view, or its own pixels, not the geometry,
are what the figure shows. Generate one first:

  scripts/make-360-testcard.py -o /tmp/testcard-8k.png --width 7680

The committed figure, docs/images/sphere-tessellation-before-after.png, is:

  scripts/render-sphere-distortion.py /tmp/testcard-8k.png \
      --az 0 --el -88 --fov 60 --size 520 --out-dir docs/images

It looks near the nadir on purpose. The angular error there is only about 1.3x
the equator's, but the quads degenerate to slivers and every meridian
converges, so the same magnitude reads far louder: it is the honest worst case,
not the typical one, and the caption on any page using it should say so. FOV is
wide enough to keep the surrounding test-card panel in frame rather than
filling the crop with an isolated crosshair; the bowing is still visible in the
full-resolution PNG at native size, in the spokes nearest the crosshair.

Usage:
  scripts/render-sphere-distortion.py SOURCE.png --out-dir docs/images
  scripts/render-sphere-distortion.py SOURCE.png --zoom --az 0 --el 0
Needs numpy and pillow.
"""
import argparse
import importlib.util
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw

# Import the measurement script by path: it has a hyphen in its name, so it is
# not importable as a module, and copying its geometry here would let the two
# drift apart silently.
_HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "measure_sphere_distortion", _HERE / "measure-sphere-distortion.py")
_msd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_msd)

faceted_uv = _msd.faceted_uv
dir_to_uv = _msd.dir_to_uv


def camera_rays(az, el, fov, w, h):
    """Perspective camera ray directions, one per output pixel."""
    ca, ce = np.radians(az), np.radians(el)
    fwd = np.array([-np.cos(ce) * np.cos(ca), np.sin(ce), np.cos(ce) * np.sin(ca)])
    world_up = np.array([0.0, 1.0, 0.0])
    if abs(fwd @ world_up) > 0.999:          # looking at a pole: pick a stable right
        world_up = np.array([0.0, 0.0, 1.0])
    right = np.cross(fwd, world_up); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)

    half = np.tan(np.radians(fov / 2))
    sx = np.linspace(-half, half, w)
    sy = np.linspace(half * h / w, -half * h / w, h)   # +y is up on screen
    gx, gy = np.meshgrid(sx, sy)
    d = (fwd[None, None, :]
         + gx[..., None] * right[None, None, :]
         + gy[..., None] * up[None, None, :])
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def sample(src, uv):
    """Nearest-neighbour texture fetch. Nearest, not bilinear, on purpose: it
    shows the geometric displacement without a filter blurring it."""
    sh, sw = src.shape[:2]
    x = np.clip((uv[..., 0] * sw).astype(int), 0, sw - 1)
    y = np.clip(((1 - uv[..., 1]) * sh).astype(int), 0, sh - 1)
    return src[y, x]


def render(src, mesh, az, el, fov, w, h, exact=False):
    rays = camera_rays(az, el, fov, w, h)
    uv = np.zeros(rays.shape[:2] + (2,))
    for j in range(h):
        for i in range(w):
            d = rays[j, i]
            uv[j, i] = dir_to_uv(d) if exact else (faceted_uv(d, *mesh)
                                                   if faceted_uv(d, *mesh) is not None
                                                   else dir_to_uv(d))
    return sample(src, uv)


def label(img, text):
    out = Image.new("RGB", (img.width, img.height + 26), "white")
    out.paste(img, (0, 0))
    ImageDraw.Draw(out).text((6, img.height + 7), text, fill="black")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("source", help="equirectangular still (the 360 test card)")
    ap.add_argument("--out-dir", default="docs/images")
    ap.add_argument("--az", type=float, default=0.0)
    ap.add_argument("--el", type=float, default=0.0)
    ap.add_argument("--fov", type=float, default=75.0)
    ap.add_argument("--size", type=int, default=560, help="output edge, px")
    ap.add_argument("--zoom", action="store_true",
                    help="narrow the FOV to 12 deg, where the error is resolvable")
    args = ap.parse_args()

    fov = 12.0 if args.zoom else args.fov
    src = np.asarray(Image.open(args.source).convert("RGB"))
    out_dir = pathlib.Path(args.out_dir); out_dir.mkdir(parents=True, exist_ok=True)

    px_per_deg = args.size / fov
    print("source %dx%d, view %.0f deg FOV at %d px (%.1f px/deg), az %g el %g"
          % (src.shape[1], src.shape[0], fov, args.size, px_per_deg, args.az, args.el))

    view = "az %g, el %g, %.0f deg FOV at %d px" % (args.az, args.el, fov, args.size)
    panels = []
    for tag, mesh, exact in (("32x32 mesh (videojs-xr default)", (32, 32), False),
                             ("256x128 mesh (shipped)", (256, 128), False)):
        img = render(src, mesh, args.az, args.el, fov, args.size, args.size, exact)
        panels.append(label(Image.fromarray(img.astype(np.uint8)),
                            "%s  -  %s" % (tag, view)))
        print("  rendered", tag)

    gap = 14
    combo = Image.new("RGB", (sum(p.width for p in panels) + gap, panels[0].height),
                      "white")
    x = 0
    for p in panels:
        combo.paste(p, (x, 0)); x += p.width + gap

    name = "sphere-tessellation-before-after%s.png" % ("-zoom" if args.zoom else "")
    combo.save(out_dir / name)
    print("wrote", out_dir / name)


if __name__ == "__main__":
    main()
