#!/usr/bin/env python3
"""
fit_calib.py — calibrate the engine-world <-> overview-image transform.

The overview image's pixel grid does NOT map to the engine world by a simple
terrain-centered formula (the image has fictional padding/desk borders, and the
engine origin is offset). We recover the true affine map by registering a driven
vehicle track (engine coords, logged as VTRACK, guaranteed to lie on roads) onto
the overview's road mask via ICP.

Output: affine A mapping engine(x,z) -> overview pixel(px,py), printed as the
4 numbers a,b (px = a*ex + b) and c,d (py = c*ez + d) when axis-aligned, plus the
inverse for re-exporting the graph in engine coords. Also writes a verification PNG.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree

dds = sys.argv[1]
track_file = sys.argv[2]

rgb = np.asarray(Image.open(dds).convert("RGB")).astype(int)
H, W = rgb.shape[:2]
r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
mx = np.maximum(np.maximum(r, g), b); mn = np.minimum(np.minimum(r, g), b)
sat = mx - mn; bright = (r + g + b) // 3
water = (b > r + 12) & (b > g + 12)
mask = (sat < 30) & (bright > 70) & (bright < 232) & (~water)
ys, xs = np.where(mask)
road = np.column_stack([xs, ys]).astype(float)   # (px, py)
tree = cKDTree(road)
print(f"road pixels: {len(road)}")

track = np.array([list(map(float, l.split())) for l in open(track_file) if l.strip()])
E = np.column_stack([track[:, 0], track[:, 1], np.ones(len(track))])  # engine [x,z,1]
print(f"track points: {len(track)}  x {track[:,0].min():.0f}..{track[:,0].max():.0f}  z {track[:,1].min():.0f}..{track[:,1].max():.0f}")


def similarity(src, dst):
    """2D similarity (uniform scale + rotation + translation) via Umeyama. Returns A (2x3)."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    sc, dc = src - mu_s, dst - mu_d
    cov = (dc.T @ sc) / len(src)
    U, S, Vt = np.linalg.svd(cov)
    d = np.sign(np.linalg.det(U @ Vt))
    R = U @ np.diag([1, d]) @ Vt
    var = (sc ** 2).sum() / len(src)
    s = (S[0] + d * S[1]) / var
    t = mu_d - s * (R @ mu_s)
    return np.hstack([s * R, t.reshape(2, 1)])


def icp(A0, iters=60, sim=True):
    A = A0.copy()
    for _ in range(iters):
        P = E @ A.T
        d, idx = tree.query(P)
        target = road[idx]
        if sim:
            A = similarity(E[:, :2], target)
        else:
            A, *_ = np.linalg.lstsq(E, target, rcond=None); A = A.T
    P = E @ A.T
    d, _ = tree.query(P)
    return A, d.mean(), np.median(d)


# initial guesses: scale ~2 px/m (4096px/2048m), 4 axis-sign combos, offset aligns centroids
cx, cz = track[:, 0].mean(), track[:, 1].mean()
rcx, rcy = road[:, 0].mean(), road[:, 1].mean()
best = None
for sx in (2.0, -2.0):
    for sz in (2.0, -2.0):
        A0 = np.array([[sx, 0, rcx - sx * cx], [0, sz, rcy - sz * cz]], float)
        A, mean_d, med_d = icp(A0)
        print(f"init sx={sx} sz={sz} -> mean={mean_d:.1f}px median={med_d:.1f}px")
        if best is None or mean_d < best[1]:
            best = (A, mean_d, med_d)

A, mean_d, med_d = best
print(f"\nBEST mean={mean_d:.1f}px ({mean_d/2:.1f}m) median={med_d:.1f}px ({med_d/2:.1f}m)")
print("A (engine->pixel):\n", np.round(A, 4))
# inverse: pixel -> engine (for graph re-export)
A3 = np.vstack([A, [0, 0, 1]])
Ainv = np.linalg.inv(A3)
print("Ainv (pixel->engine):\n", np.round(Ainv, 6))

# verification image: track (cyan) mapped onto overview
im = Image.open(dds).convert("RGB")
d = ImageDraw.Draw(im)
P = E @ A.T
for (px, py) in P:
    d.ellipse([px - 5, py - 5, px + 5, py + 5], fill=(0, 255, 255))
xs2 = P[:, 0]; ys2 = P[:, 1]; m = 250
im.crop((int(xs2.min() - m), int(ys2.min() - m), int(xs2.max() + m), int(ys2.max() + m))).save(
    "/sessions/exciting-awesome-gates/mnt/outputs/calib_check.png")
print("wrote calib_check.png")
