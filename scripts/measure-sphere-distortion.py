#!/usr/bin/env python3
"""Quantify the equirect-sphere tessellation error in the HOAST360/videojs-xr
player, as a function of mesh resolution.

WHY
The 360 video is textured onto a faceted approximation of a sphere (three.js
SphereGeometry). UV coordinates are exact at the vertices but interpolated
linearly across each quad, while the equirect->sphere mapping is not linear, so
straight lines in the content bow inside each quad. The player shipped the
videojs-xr default of 32x32 segments; this measures how visible that is and
what raising it buys, so "is 256x128 enough / too much" is answered with a
number rather than an opinion.

METRIC
For a cone of viewing rays (default 75 deg FOV, the player's camera), each ray's
true direction is compared with the direction the *sampled* texel actually
belongs to (faceted UV -> direction). That angular error is projection
independent - unlike a raw screen-pixel count, it does not blow up spuriously
near the poles where azimuth compresses on screen - and is then expressed in
screen pixels at a chosen viewport width. Straight three.js geometry: vertices
at equal (phi, theta) increments, UV linear in them, quads split into two
triangles, ray-triangle intersection by Moller-Trumbore.

RESULT (8K source, 75 deg FOV, 1920 px viewport; one pixel = 2.34 arcmin):
  32x32     equator 5.3 px   straight-down 7.1 px   -> visible bowing
  256x128   equator 0.14 px  straight-down 0.22 px  -> sub-pixel everywhere
  512x256   equator 0.03 px  straight-down 0.05 px  -> improving the invisible
So 256x128 (shipped) clears the visible threshold with ~5x margin at the poles
too; going higher spends ~4x the triangles per doubling on error that is already
invisible. The residual pole *look* is creasing at the sliver-quad diagonals,
not magnitude - the fix for that is per-pixel shader sampling, not more mesh.

Usage: scripts/measure-sphere-distortion.py [--fov DEG] [--viewport PX] [--rays N]
Needs numpy (see the AmbisonicEnergyRenderer venv; system python3 lacks it).
"""
import argparse
import numpy as np


def vert(iu, iv, W, H):
    u = iu / W; v = iv / H
    phi = u * 2 * np.pi; theta = v * np.pi
    return (np.array([-np.cos(phi) * np.sin(theta), np.cos(theta),
                      np.sin(phi) * np.sin(theta)]),
            np.array([u, 1 - v]))


def dir_to_uv(d):
    x, y, z = d
    theta = np.arccos(np.clip(y, -1, 1))
    phi = np.arctan2(z, -x) % (2 * np.pi)
    return np.array([phi / (2 * np.pi), 1 - theta / np.pi])


def uv_to_dir(uv):
    phi = uv[0] * 2 * np.pi; theta = (1 - uv[1]) * np.pi
    return np.array([-np.cos(phi) * np.sin(theta), np.cos(theta),
                     np.sin(phi) * np.sin(theta)])


def ray_tri_uv(d, P, U):
    e1 = P[1] - P[0]; e2 = P[2] - P[0]
    h = np.cross(d, e2); a = e1 @ h
    if abs(a) < 1e-12:
        return None
    f = 1 / a; s = -P[0]
    u = f * (s @ h); q = np.cross(s, e1); v = f * (d @ q); t = f * (e2 @ q)
    if t <= 0 or u < -1e-9 or v < -1e-9 or u + v > 1 + 1e-9:
        return None
    return (1 - u - v) * U[0] + u * U[1] + v * U[2]


def faceted_uv(d, W, H):
    tu = dir_to_uv(d)
    iu = min(int(tu[0] * W), W - 1); iv = min(int((1 - tu[1]) * H), H - 1)
    c = {(du, dv): vert(iu + du, iv + dv, W, H)
         for du in (0, 1) for dv in (0, 1)}
    for tri in ([c[(0, 0)], c[(1, 0)], c[(1, 1)]],
                [c[(0, 0)], c[(1, 1)], c[(0, 1)]]):
        r = ray_tri_uv(d, [t[0] for t in tri], [t[1] for t in tri])
        if r is not None:
            return r
    return None


def cone(az, el, fov, n):
    ca, ce = np.radians(az), np.radians(el)
    fwd = np.array([-np.cos(ce) * np.cos(ca), np.sin(ce), np.cos(ce) * np.sin(ca)])
    right = np.cross(fwd, [0, 1.0, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    h = np.tan(np.radians(fov / 2)); xs = np.linspace(-h, h, n)
    return [v / np.linalg.norm(v) for sy in xs for sx in xs
            for v in [fwd + sx * right + sy * up]]


def measure(W, H, az, el, fov, n, vpx):
    px_per_rad = vpx / np.radians(fov)
    worst = 0.0
    for d in cone(az, el, fov, n):
        fu = faceted_uv(d, W, H)
        if fu is None:
            continue
        ang = np.arccos(np.clip(d @ uv_to_dir(fu), -1, 1))
        worst = max(worst, ang)
    return np.degrees(worst) * 60, worst * px_per_rad


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--fov", type=float, default=75)
    ap.add_argument("--viewport", type=int, default=1920)
    ap.add_argument("--rays", type=int, default=160)
    args = ap.parse_args()

    print("equirect-sphere tessellation error  (FOV %g deg, %d px viewport)"
          % (args.fov, args.viewport))
    print("one screen pixel = %.2f arcmin\n"
          % (np.degrees(np.radians(args.fov) / args.viewport) * 60))
    print("%-12s %18s %20s" % ("mesh", "FRONT (equator)", "straight DOWN (pole)"))
    print("%-12s %9s %8s %10s %9s" % ("", "arcmin", "px", "arcmin", "px"))
    for W, H in [(32, 32), (64, 64), (128, 64), (256, 128), (512, 256), (1024, 512)]:
        e_am, e_px = measure(W, H, 0, 0, args.fov, args.rays, args.viewport)
        p_am, p_px = measure(W, H, 0, -90, args.fov, args.rays, args.viewport)
        tag = "  <- shipped" if (W, H) == (256, 128) else ""
        print("%-12s %9.2f %8.2f %10.2f %9.2f%s"
              % ("%dx%d" % (W, H), e_am, e_px, p_am, p_px, tag))


if __name__ == "__main__":
    main()
