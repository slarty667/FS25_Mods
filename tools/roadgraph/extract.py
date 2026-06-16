#!/usr/bin/env python3
"""
roadgraph/extract.py — offline road-network extraction for FS25 maps.

Reads a map's top-down overview image (overview.dds), isolates the road/track
pixels by colour, thins them to 1px centrelines, and vectorises the skeleton into
a graph of nodes (junctions/ends) and edges (polylines). Output: a graph JSON in
world coordinates plus a debug overlay PNG so the result can be checked visually.

This is the "deluxe" pre-processing step: run once per map (batchable over ModHub),
ship the resulting graph; the in-game mod just loads it and runs A* — cheap, and it
follows real roads because the graph *is* the roads.

Usage:
    python3 extract.py <overview.dds> <out_dir> [--terrain 2048] [--name MapName]
"""

import sys
import os
import json
import argparse
import numpy as np
from PIL import Image
from skimage.morphology import skeletonize, remove_small_objects, binary_closing, disk, binary_dilation
import sknw


def road_mask(rgb):
    """Boolean mask of road/track pixels: low saturation, mid brightness, not water."""
    a = rgb.astype(int)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    sat = mx - mn
    bright = (r + g + b) // 3
    water = (b > r + 12) & (b > g + 12)          # bluish -> lakes/rivers
    mask = (sat < 30) & (bright > 70) & (bright < 232) & (~water)
    return mask


def clean_mask(mask, min_obj=120, close_r=2):
    """Bridge small gaps, drop small blobs (buildings)."""
    m = binary_closing(mask, disk(close_r))
    m = remove_small_objects(m, min_size=min_obj)
    return m


def rdp(points, eps=2.0):
    """Ramer-Douglas-Peucker polyline simplification (points: list of (x,y))."""
    if len(points) < 3:
        return points
    start, end = np.array(points[0]), np.array(points[-1])
    line = end - start
    ll = np.hypot(*line)
    if ll == 0:
        d = [np.hypot(*(np.array(p) - start)) for p in points]
    else:
        d = [abs(np.cross(line, np.array(p) - start)) / ll for p in points]
    idx = int(np.argmax(d))
    if d[idx] > eps:
        left = rdp(points[:idx + 1], eps)
        right = rdp(points[idx:], eps)
        return left[:-1] + right
    return [points[0], points[-1]]


def _elen_px(graph, s, e):
    pts = graph[s][e]["pts"]
    return sum(float(np.hypot(pts[i+1][1]-pts[i][1], pts[i+1][0]-pts[i][0]))
               for i in range(len(pts)-1))


def prune_and_stitch(graph, min_spur_px=20.0, merge_px=10.0):
    """Bridge skeleton gaps (stitch near nodes) and remove short dead-end spurs."""
    coords = {n: (float(graph.nodes[n]["o"][1]), float(graph.nodes[n]["o"][0])) for n in graph.nodes()}
    cell = max(1.0, merge_px)
    buckets = {}
    for n, (x, y) in coords.items():
        buckets.setdefault((int(x // cell), int(y // cell)), []).append(n)
    added = 0
    for n, (x, y) in coords.items():
        cx, cy = int(x // cell), int(y // cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for m in buckets.get((cx + dx, cy + dy), []):
                    if m <= n:
                        continue
                    mx, my = coords[m]
                    if (mx - x)**2 + (my - y)**2 <= merge_px * merge_px and not graph.has_edge(n, m):
                        graph.add_edge(n, m, pts=np.array([[y, x], [my, mx]]))
                        added += 1
    removed, changed = 0, True
    while changed:
        changed = False
        for n in list(graph.nodes()):
            if graph.degree(n) == 1:
                s, e = list(graph.edges(n))[0]
                if _elen_px(graph, s, e) < min_spur_px:
                    graph.remove_node(n); removed += 1; changed = True
    for n in list(graph.nodes()):
        if graph.degree(n) == 0:
            graph.remove_node(n)
    return added, removed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dds")
    ap.add_argument("out_dir")
    ap.add_argument("--terrain", type=float, default=2048.0)
    ap.add_argument("--name", default=None)
    # Map world<->image projection (from in-game nhMapInfo). Default = terrain-centered.
    ap.add_argument("--wsx", type=float, default=None, help="worldSizeX")
    ap.add_argument("--wsz", type=float, default=None, help="worldSizeZ")
    ap.add_argument("--offx", type=float, default=None, help="worldCenterOffsetX")
    ap.add_argument("--offz", type=float, default=None, help="worldCenterOffsetZ")
    ap.add_argument("--calib", default=None,
                    help="pixel->engine affine 'a11,a12,a13,a21,a22,a23' (from fit_calib.py Ainv)")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    name = args.name or os.path.basename(os.path.dirname(args.dds)) or "map"

    rgb = np.asarray(Image.open(args.dds).convert("RGB"))
    H, W = rgb.shape[:2]
    print(f"[{name}] overview {W}x{H}, terrain {args.terrain} m")

    mask = clean_mask(road_mask(rgb))
    print(f"[{name}] road pixels: {mask.mean()*100:.1f}%")

    ske = skeletonize(mask)
    graph = sknw.build_sknw(ske)
    print(f"[{name}] skeleton graph: {graph.number_of_nodes()} nodes, {graph.number_of_edges()} edges")
    px_per_m = W / args.terrain
    added, removed = prune_and_stitch(graph, min_spur_px=10.0 * px_per_m, merge_px=5.0 * px_per_m)
    print(f"[{name}] cleanup: +{added} stitch, -{removed} spurs -> {graph.number_of_nodes()} nodes, {graph.number_of_edges()} edges")

    # pixel (col=x, row=y) -> world. Use the map's real projection if given, else
    # assume the overview covers the terrain square centered (offset = size/2).
    wsx = args.wsx if args.wsx is not None else args.terrain
    wsz = args.wsz if args.wsz is not None else args.terrain
    offx = args.offx if args.offx is not None else wsx / 2.0
    offz = args.offz if args.offz is not None else wsz / 2.0
    print(f"[{name}] projection wsx={wsx} wsz={wsz} offx={offx} offz={offz}")

    calib = None
    if args.calib:
        calib = [float(v) for v in args.calib.split(",")]
        print(f"[{name}] using calib pixel->engine: {calib}")

    def to_world(px, py):
        if calib is not None:
            wx = calib[0] * px + calib[1] * py + calib[2]
            wz = calib[3] * px + calib[4] * py + calib[5]
            return round(wx, 1), round(wz, 1)
        wx = (px / W) * wsx - offx
        wz = (py / H) * wsz - offz
        return round(wx, 1), round(wz, 1)

    nodes = {}
    for n in graph.nodes():
        y, x = graph.nodes[n]["o"]
        wx, wz = to_world(x, y)
        nodes[n] = {"id": int(n), "x": wx, "z": wz}

    edges = []
    for s, e in graph.edges():
        pts = graph[s][e]["pts"]  # array of (y, x)
        poly = [(float(p[1]), float(p[0])) for p in pts]      # (x_px, y_px)
        poly = rdp(poly, eps=2.5)
        wpts = [list(to_world(px, py)) for (px, py) in poly]
        length = sum(np.hypot(wpts[i+1][0]-wpts[i][0], wpts[i+1][1]-wpts[i][1])
                     for i in range(len(wpts)-1))
        edges.append({"a": int(s), "b": int(e), "pts": wpts, "len": round(length, 1)})

    out_json = os.path.join(args.out_dir, f"{name}.roadgraph.json")
    with open(out_json, "w") as f:
        json.dump({"map": name, "terrain": args.terrain, "image": [W, H],
                   "nodes": list(nodes.values()), "edges": edges}, f)
    total_len = round(sum(e["len"] for e in edges))
    print(f"[{name}] wrote {out_json}: {len(nodes)} nodes, {len(edges)} edges, ~{total_len} m road")

    # Compact Lua data file for the in-game mod (sourced at map load).
    node_order = list(nodes.keys())
    idmap = {n: i + 1 for i, n in enumerate(node_order)}
    out_lua = os.path.join(args.out_dir, f"{name}.lua")
    with open(out_lua, "w") as f:
        f.write("-- generated by tools/roadgraph/extract.py — do not edit by hand\n")
        f.write("NaviHelperRoadData = {\n")
        f.write(f"terrain={args.terrain},\n")
        f.write("nodes={")
        for n in node_order:
            f.write("{x=%s,z=%s}," % (nodes[n]["x"], nodes[n]["z"]))
        f.write("},\nedges={")
        for ed in edges:
            flat = ",".join("%s,%s" % (p[0], p[1]) for p in ed["pts"])
            f.write("{a=%d,b=%d,len=%s,pts={%s}}," % (idmap[ed["a"]], idmap[ed["b"]], ed["len"], flat))
        f.write("}\n}\n")
    print(f"[{name}] wrote {out_lua}")

    # debug overlay: dim overview + graph edges (cyan) + nodes (amber)
    from PIL import ImageDraw
    base = Image.open(args.dds).convert("RGB").resize((1024, 1024))
    base = Image.eval(base, lambda v: v // 2)
    d = ImageDraw.Draw(base)
    sx, sy = 1024 / W, 1024 / H
    for s, e in graph.edges():
        pts = graph[s][e]["pts"]
        xy = [(p[1]*sx, p[0]*sy) for p in pts]
        if len(xy) >= 2:
            d.line(xy, fill=(80, 210, 255), width=1)
    for n in graph.nodes():
        y, x = graph.nodes[n]["o"]
        deg = graph.degree(n)
        if deg >= 3:
            d.ellipse([x*sx-3, y*sy-3, x*sx+3, y*sy+3], fill=(255, 160, 0))
    dbg = os.path.join(args.out_dir, f"{name}.debug.png")
    base.save(dbg)
    print(f"[{name}] wrote {dbg}")


if __name__ == "__main__":
    main()
