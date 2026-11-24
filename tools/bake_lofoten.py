#!/usr/bin/env python3
"""
tools/bake_lofoten.py - bake the Lofoten map into data/world/lofoten/ (load it in the game with --map=lofoten).

Inputs (nothing else is read, nothing is downloaded here):
    data/world/lofoten_raw/elev_grid_513.json    SRTM elevation grid, 513 x 513, 64 m lattice (key elev_m_row_major_z_then_x)
    data/world/osm_cache_lofoten/tile_*.json     OSM roads / buildings / coast (tools/fetch_lofoten.py)
    data/world/osm_cache_lofoten/landuse_*.json  OSM landuse / forest / place (tools/fetch_lofoten_landuse.py), optional

Outputs (the exact formats world/osm_world.gd, world/road_graph.gd and world/city_chunks.gd read):
    terrain.bin    513*513 float32 little-endian, index = iz*513 + ix, world = -16384 + 64*i
    weights.bin    6 planes of 513*513 uint8: CITY, FOREST, DESERT, MOUNTAIN, HILLS, COAST (COUNTRY = remainder)
    network.json   road graph (nodes, edges with dense pts, spawn)
    buildings.json "tx,tz" (1024 m tiles) -> [[height_m, style, [x0, z0, x1, z1, ...]], ...]   (counter-clockwise)
    meta.json      n / lattice / origin / regions / sea polygons / default_spawn / attribution

Deterministic: fixed iteration orders, no randomness, no wall-clock data. numpy required; scipy is used for the
gaussian blur when present, otherwise a numpy separable blur gives the same result to rounding.

Usage:  python tools/bake_lofoten.py

Attribution: Road data (c) OpenStreetMap contributors, ODbL; elevation SRTM 30m
"""

import glob
import json
import math
import os
from collections import deque

import numpy as np

try:
    from scipy.ndimage import gaussian_filter as _scipy_gauss
except Exception:  # scipy is optional
    _scipy_gauss = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "data", "world", "lofoten_raw", "elev_grid_513.json")
CACHE = os.path.join(ROOT, "data", "world", "osm_cache_lofoten")
OUT = os.path.join(ROOT, "data", "world", "lofoten")

# ---------------------------------------------------------------------------------------------- constants
N = 513
LAT = 64.0
X0 = -16384.0
HALF = 16384.0
TILE = 1024.0
CLAT, CLON = 68.2085, 13.90
KX = 111320.0 * math.cos(math.radians(CLAT))
KZ = 110574.0
ATTRIBUTION = "Road data (c) OpenStreetMap contributors, ODbL; elevation SRTM 30m"

HIGHWAYS = {
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "living_street", "residential",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
}
WIDTH = {"motorway": 22.0, "trunk": 16.0, "primary": 12.0, "secondary": 10.0, "tertiary": 8.0}
DEFAULT_WIDTH = 6.0
ROAD_STEP = 10.0
ROAD_LIFT = 0.5
MOUNTAIN_ROAD_M = 250.0  # mean elevation above which an ordinary road is typed "mountain"

CITY_LANDUSE = {"residential", "commercial", "retail", "industrial"}
PLACES = {"city", "town", "village", "suburb"}
PLACE_RADIUS_M = 400.0
COAST_RANGE_M = 600.0
BLUR_SIGMA = 2.0

BUILDING_HEIGHT = {
    "house": 6.0, "detached": 6.0, "semidetached_house": 6.0, "residential": 7.0, "terrace": 7.0, "cabin": 4.5,
    "hut": 3.5, "shed": 3.0, "garage": 3.0, "garages": 3.0, "carport": 3.0, "barn": 7.0, "farm_auxiliary": 5.0,
    "boathouse": 4.5, "apartments": 10.0, "commercial": 8.0, "retail": 6.0, "industrial": 8.0, "warehouse": 7.0,
    "church": 10.0, "chapel": 6.0, "hotel": 9.0, "school": 8.0, "public": 8.0, "service": 4.0,
}
BUILDING_DEFAULT_HEIGHT = 6.0
BUILDING_STYLE = 1  # same default style as the baked Triland footprints
BUILDING_MIN_AREA = 8.0


# ---------------------------------------------------------------------------------------------- helpers
def proj(lat: float, lon: float):
    return (lon - CLON) * KX, -(lat - CLAT) * KZ


def inside(x: float, z: float) -> bool:
    return abs(x) <= HALF and abs(z) <= HALF


def dump(path: str, obj) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, separators=(",", ":"))


# ---------------------------------------------------------------------------------------------- terrain
def load_terrain() -> np.ndarray:
    with open(RAW, "r", encoding="utf-8") as f:
        d = json.load(f)
    flat = d["elev_m_row_major_z_then_x"]
    if len(flat) != N * N:
        raise SystemExit("elev grid has %d values, expected %d" % (len(flat), N * N))
    t = np.asarray(flat, dtype=np.float64).reshape(N, N)  # [iz, ix] == flat index iz*N + ix
    if not np.isfinite(t).all():
        raise SystemExit("elev grid has non-finite values")
    return np.maximum(t, 0.0).astype(np.float32)


def _cr(t):
    t2 = t * t
    t3 = t2 * t
    return (0.5 * (-t3 + 2.0 * t2 - t), 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0), 0.5 * (-3.0 * t3 + 4.0 * t2 + t), 0.5 * (t3 - t2))


def height(T: np.ndarray, wx, wz) -> np.ndarray:
    """Catmull-Rom bicubic height: a copy of OsmWorld.height() (what the game renders), so roads sit on the real surface."""
    wx = np.atleast_1d(np.asarray(wx, dtype=np.float64))
    wz = np.atleast_1d(np.asarray(wz, dtype=np.float64))
    fx = np.clip((wx - X0) / LAT, 0.0, N - 1.001)
    fz = np.clip((wz - X0) / LAT, 0.0, N - 1.001)
    ix = fx.astype(np.int64)
    iz = fz.astype(np.int64)
    wxs = _cr(fx - ix)
    wzs = _cr(fz - iz)
    h = np.zeros_like(fx)
    for j in range(4):
        row = np.clip(iz + j - 1, 0, N - 1)
        acc = np.zeros_like(fx)
        for i in range(4):
            acc += wxs[i] * T[row, np.clip(ix + i - 1, 0, N - 1)]
        h += wzs[j] * acc
    return h


# ---------------------------------------------------------------------------------------------- OSM loading
class Osm:
    def __init__(self):
        self.nodes = {}  # id -> (x, z)
        self.node_tags = {}  # id -> tags
        self.ways = {}  # id -> (node ids, tags)
        self.rels = {}  # id -> (members, tags)
        self.files = []

    def load(self):
        files = sorted(glob.glob(os.path.join(CACHE, "tile_*.json"))) + sorted(glob.glob(os.path.join(CACHE, "landuse_*.json")))
        for fn in files:
            with open(fn, "r", encoding="utf-8") as f:
                d = json.load(f)
            self.files.append((os.path.basename(fn), len(d.get("elements", []))))
            for el in d.get("elements", []):
                t = el.get("type")
                if t == "node":
                    self.nodes[el["id"]] = proj(el["lat"], el["lon"])
                    if el.get("tags"):
                        self.node_tags[el["id"]] = el["tags"]
                elif t == "way":
                    tags = el.get("tags", {})
                    old = self.ways.get(el["id"])
                    if old is None or (not old[1] and tags):  # skeleton copies carry no tags; keep the tagged one
                        self.ways[el["id"]] = (el.get("nodes", []), tags)
                elif t == "relation":
                    self.rels[el["id"]] = (el.get("members", []), el.get("tags", {}))


# ---------------------------------------------------------------------------------------------- roads
def subdivide(pts):
    """pts: [(x, z)]. Insert points so no segment exceeds ROAD_STEP (even split); drop repeated points."""
    out = [pts[0]]
    for (x1, z1) in pts[1:]:
        x0, z0 = out[-1]
        d = math.hypot(x1 - x0, z1 - z0)
        if d < 0.05:
            continue
        k = max(1, int(math.ceil(d / ROAD_STEP)))
        for s in range(1, k + 1):
            f = s / k
            out.append((x0 + (x1 - x0) * f, z0 + (z1 - z0) * f))
    return out


def road_type(hw: str, mean_elev: float) -> str:
    # world/road_graph.gd only knows highway / country / mountain / city / ramp / rural
    if hw in ("motorway", "trunk"):
        return "highway"
    if hw.endswith("_link"):
        return "ramp"
    if mean_elev > MOUNTAIN_ROAD_M:
        return "mountain"
    if hw in ("primary", "secondary", "tertiary"):
        return "country"
    if hw in ("residential", "living_street"):
        return "city"
    return "rural"  # unclassified


def build_roads(osm: Osm, T: np.ndarray):
    # 1. clip every highway way to runs of consecutive in-window nodes
    runs = []  # (way id, tags, [node ids])
    for wid in sorted(osm.ways):
        nodes, tags = osm.ways[wid]
        if tags.get("highway") not in HIGHWAYS:
            continue
        cur = []
        for nid in nodes:
            p = osm.nodes.get(nid)
            if p is not None and inside(p[0], p[1]):
                if not cur or cur[-1] != nid:
                    cur.append(nid)
            else:
                if len(cur) >= 2:
                    runs.append((wid, tags, cur))
                cur = []
        if len(cur) >= 2:
            runs.append((wid, tags, cur))

    # 2. a graph node is every run end and every OSM node shared by two or more runs / twice in one run
    use = {}
    for _, _, ids in runs:
        for nid in ids:
            use[nid] = use.get(nid, 0) + 1
        use[ids[0]] += 2
        use[ids[-1]] += 2

    # 3. cut runs at graph nodes into edges
    pieces = []  # (wid, tags, key_a, key_b, [(x, z)])
    for wid, tags, ids in runs:
        cuts = [0] + [i for i in range(1, len(ids) - 1) if use[ids[i]] >= 2] + [len(ids) - 1]
        for c0, c1 in zip(cuts[:-1], cuts[1:]):
            if ids[c0] == ids[c1]:
                if c1 - c0 < 4:
                    continue  # stub loop
                mid = (c0 + c1) // 2  # a == b is not a usable edge: split the loop at its middle vertex
                mk = ("mid", wid, mid)
                pieces.append((wid, tags, ids[c0], mk, [osm.nodes[i] for i in ids[c0:mid + 1]]))
                pieces.append((wid, tags, mk, ids[c1], [osm.nodes[i] for i in ids[mid:c1 + 1]]))
            else:
                pieces.append((wid, tags, ids[c0], ids[c1], [osm.nodes[i] for i in ids[c0:c1 + 1]]))

    nodes_xz = {}  # key -> (x, z)
    node_order = []
    edges = []
    for wid, tags, ka, kb, xz in pieces:
        xz = subdivide(xz)
        if len(xz) < 2:
            continue
        a = np.asarray(xz, dtype=np.float64)
        y = height(T, a[:, 0], a[:, 1]) + ROAD_LIFT
        hw = tags["highway"]
        edges.append({
            "ka": ka, "kb": kb, "hw": hw,
            "name": tags.get("name") or tags.get("ref") or "",
            "pts": np.column_stack([a[:, 0], y, a[:, 1]]),
            "bridge": tags.get("bridge") not in (None, "no"), "tunnel": tags.get("tunnel") not in (None, "no"),
        })
        for key, p in ((ka, xz[0]), (kb, xz[-1])):
            if key not in nodes_xz:
                nodes_xz[key] = p
                node_order.append(key)
    index = {k: i for i, k in enumerate(node_order)}

    # shared nodes must have one position and one height: edge ends use the node's coordinates exactly
    node_y = {}
    for e in edges:
        for key, row in ((e["ka"], 0), (e["kb"], -1)):
            node_y.setdefault(key, float(e["pts"][row, 1]))
    for e in edges:
        e["pts"][0, 1] = node_y[e["ka"]]
        e["pts"][-1, 1] = node_y[e["kb"]]
        e["a"], e["b"] = index[e["ka"]], index[e["kb"]]

    nodes_out = []
    for k in node_order:
        x, z = nodes_xz[k]
        nodes_out.append({"p": [round(x, 2), round(node_y[k], 2), round(z, 2)], "kind": "normal", "radius": 0.0})

    edges_out = []
    for e in edges:
        p = e["pts"]
        t = road_type(e["hw"], float(p[:, 1].mean()))
        e["type"] = t
        e["len"] = float(np.sqrt((np.diff(p, axis=0) ** 2).sum(axis=1)).sum())
        edges_out.append({
            "a": e["a"], "b": e["b"], "type": t, "kind": "road", "elevated": False,
            "width": WIDTH.get(e["hw"], DEFAULT_WIDTH), "name": e["name"], "dense": True,
            "pts": [[round(float(r[0]), 2), round(float(r[1]), 2), round(float(r[2]), 2)] for r in p],
        })

    # 4. spawn: a motorway/trunk edge closest to the window centre
    best = None
    for rank, classes in enumerate((("motorway", "trunk"), ("primary",), ("secondary", "tertiary"))):
        for i, e in enumerate(edges):
            if e["hw"] not in classes or e["len"] < 200.0 or e["pts"][:, 1].min() < 1.0:
                continue
            d = np.hypot(e["pts"][:, 0], e["pts"][:, 2])
            k = int(d.argmin())
            if best is None or d[k] < best[0]:
                best = (float(d[k]), i, k)
        if best is not None:
            break
    spawn = {"edge": -1, "s": 0.0, "dir": 1}
    yaw = 0.0
    spawn_name = ""
    if best is not None:
        _, ei, k = best
        p = edges[ei]["pts"]
        seg = np.sqrt((np.diff(p, axis=0) ** 2).sum(axis=1))
        arc = np.concatenate([[0.0], np.cumsum(seg)])
        k = int(min(max(k, 1), len(p) - 2))  # keep a neighbour on both sides for the heading
        spawn = {"edge": ei, "s": float(arc[k]), "dir": 1}
        fx, fz = p[k + 1, 0] - p[k - 1, 0], p[k + 1, 2] - p[k - 1, 2]
        yaw = math.degrees(math.atan2(-fx, -fz))  # Godot: yaw 0 looks along -Z
        spawn_name = edges[ei]["name"]
    stats = {
        "ways_used": len(runs), "bridge_edges": sum(1 for e in edges if e["bridge"]), "tunnel_edges": sum(1 for e in edges if e["tunnel"]),
        "types": {},
    }
    for e in edges:
        stats["types"][e["type"]] = stats["types"].get(e["type"], 0) + 1
    km = sum(e["len"] for e in edges) / 1000.0
    return nodes_out, edges_out, spawn, yaw, spawn_name, km, stats


# ---------------------------------------------------------------------------------------------- buildings
def building_height(tags: dict) -> float:
    h = tags.get("height") or tags.get("building:height")
    if h:
        try:
            v = float(str(h).lower().replace("m", "").replace(",", ".").strip())
            if 2.0 <= v <= 120.0:
                return v
        except ValueError:
            pass
    lv = tags.get("building:levels")
    if lv:
        try:
            v = float(str(lv).replace(",", ".").strip())
            if 0.5 <= v <= 40.0:
                return max(3.0, round(v * 3.0 + 1.0, 1))
        except ValueError:
            pass
    return BUILDING_HEIGHT.get(tags.get("building", ""), BUILDING_DEFAULT_HEIGHT)


def build_buildings(osm: Osm):
    bld = {}
    count = 0
    for wid in sorted(osm.ways):
        nodes, tags = osm.ways[wid]
        if "building" not in tags or tags.get("building") == "no":
            continue
        pts = []
        ok = True
        for nid in nodes:
            p = osm.nodes.get(nid)
            if p is None or not inside(p[0], p[1]):
                ok = False
                break
            pts.append(p)
        if not ok:
            continue
        if len(pts) > 1 and nodes[0] == nodes[-1]:
            pts = pts[:-1]
        if len(pts) < 3:
            continue
        area = 0.0
        for i in range(len(pts)):
            x1, z1 = pts[i]
            x2, z2 = pts[(i + 1) % len(pts)]
            area += x1 * z2 - x2 * z1
        if abs(area) < 2.0 * BUILDING_MIN_AREA:  # the shoelace sum is twice the area; baked Triland uses abs(sum) < 8
            continue
        if area < 0:
            pts = pts[::-1]
        cx = sum(p[0] for p in pts) / len(pts)
        cz = sum(p[1] for p in pts) / len(pts)
        key = "%d,%d" % (math.floor(cx / TILE), math.floor(cz / TILE))
        flat = []
        for p in pts:
            flat += [round(p[0], 1), round(p[1], 1)]
        bld.setdefault(key, []).append([round(building_height(tags), 1), BUILDING_STYLE, flat])
        count += 1
    return bld, count


# ---------------------------------------------------------------------------------------------- rasters
def blur(a: np.ndarray, sigma: float) -> np.ndarray:
    if _scipy_gauss is not None:
        return _scipy_gauss(a.astype(np.float64), sigma=sigma, mode="nearest")
    r = int(math.ceil(4.0 * sigma))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    out = a.astype(np.float64)
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r, r)
        p = np.pad(out, pad, mode="edge")
        acc = np.zeros_like(out)
        for i, w in enumerate(k):
            acc += w * (p[i:i + N, :] if axis == 0 else p[:, i:i + N])
        out = acc
    return out


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fill_feature(mask: np.ndarray, rings) -> None:
    """Even-odd scanline fill (cell centres at lattice points) of one feature = a list of rings [(x, z)] in world metres."""
    gr = []
    for r in rings:
        a = np.asarray(r, dtype=np.float64)
        if len(a) >= 3:
            gr.append(np.column_stack([(a[:, 0] - X0) / LAT, (a[:, 1] - X0) / LAT]))
    if not gr:
        return
    vmin = min(float(g[:, 1].min()) for g in gr)
    vmax = max(float(g[:, 1].max()) for g in gr)
    j0 = max(int(math.ceil(vmin)), 0)
    j1 = min(int(math.ceil(vmax)) - 1, N - 1)
    if j1 < j0:
        return
    diff = np.zeros((j1 - j0 + 1, N + 1), dtype=np.int32)
    for g in gr:
        p0 = g
        p1 = np.roll(g, -1, axis=0)
        for (u0, v0), (u1, v1) in zip(p0, p1):
            if v0 == v1:
                continue
            lo, hi = (v0, v1) if v0 < v1 else (v1, v0)
            ja = max(int(math.ceil(lo)), j0)
            jb = min(int(math.ceil(hi)) - 1, j1)
            if jb < ja:
                continue
            js = np.arange(ja, jb + 1)
            u = u0 + (js - v0) * (u1 - u0) / (v1 - v0)
            i0 = np.clip(np.ceil(u), 0, N).astype(np.int64)
            np.add.at(diff, (js - j0, i0), 1)
    inner = (np.cumsum(diff, axis=1)[:, :N] % 2) == 1
    mask[j0:j1 + 1] |= inner


def stitch(way_node_lists):
    """Join member ways end to end into closed rings (open leftovers are dropped)."""
    left = [list(w) for w in way_node_lists if len(w) >= 2]
    rings = []
    while left:
        ring = left.pop(0)
        grown = True
        while grown and ring[0] != ring[-1]:
            grown = False
            for i, w in enumerate(left):
                if w[0] == ring[-1]:
                    ring += w[1:]
                elif w[-1] == ring[-1]:
                    ring += w[::-1][1:]
                elif w[-1] == ring[0]:
                    ring = w[:-1] + ring
                elif w[0] == ring[0]:
                    ring = w[::-1][:-1] + ring
                else:
                    continue
                left.pop(i)
                grown = True
                break
        if ring[0] == ring[-1] and len(ring) >= 4:
            rings.append(ring)
    return rings


def landuse_masks(osm: Osm):
    """CITY and FOREST boolean rasters from OSM polygons (+ place discs for CITY)."""
    city = np.zeros((N, N), dtype=bool)
    forest = np.zeros((N, N), dtype=bool)
    counts = {"city_polys": 0, "forest_polys": 0, "places": 0}

    def klass(tags):
        if tags.get("landuse") in CITY_LANDUSE:
            return "city"
        if tags.get("landuse") == "forest" or tags.get("natural") == "wood":
            return "forest"
        return None

    def rings_of(node_lists):
        out = []
        for nl in node_lists:
            if all(n in osm.nodes for n in nl):
                out.append(nl)
        return out

    for wid in sorted(osm.ways):
        nodes, tags = osm.ways[wid]
        k = klass(tags)
        if k is None or len(nodes) < 4 or nodes[0] != nodes[-1] or any(n not in osm.nodes for n in nodes):
            continue
        fill_feature(city if k == "city" else forest, [[osm.nodes[n] for n in nodes]])
        counts[k + "_polys"] += 1
    for rid in sorted(osm.rels):
        members, tags = osm.rels[rid]
        k = klass(tags)
        if k is None or tags.get("type", "multipolygon") not in ("multipolygon", "boundary"):
            continue
        wl = []
        for m in members:
            if m.get("type") == "way" and m.get("role", "") in ("outer", "inner", "") and m["ref"] in osm.ways:
                wl.append(osm.ways[m["ref"]][0])
        rings = rings_of(stitch(wl))
        if rings:
            fill_feature(city if k == "city" else forest, [[osm.nodes[n] for n in r] for r in rings])
            counts[k + "_polys"] += 1
    # place=town/village: a disc around the node (or the middle of a place way)
    places = []
    for nid in sorted(osm.node_tags):
        if osm.node_tags[nid].get("place") in PLACES and nid in osm.nodes:
            places.append(osm.nodes[nid])
    for wid in sorted(osm.ways):
        nodes, tags = osm.ways[wid]
        if tags.get("place") in PLACES and nodes and all(n in osm.nodes for n in nodes):
            places.append((sum(osm.nodes[n][0] for n in nodes) / len(nodes), sum(osm.nodes[n][1] for n in nodes) / len(nodes)))
    R = int(math.ceil(PLACE_RADIUS_M / LAT)) + 1
    for (x, z) in places:
        ci, cj = (x - X0) / LAT, (z - X0) / LAT
        i0, i1 = max(int(ci) - R, 0), min(int(ci) + R + 1, N)
        j0, j1 = max(int(cj) - R, 0), min(int(cj) + R + 1, N)
        if i1 <= i0 or j1 <= j0:
            continue
        ii, jj = np.meshgrid(np.arange(i0, i1), np.arange(j0, j1))
        city[j0:j1, i0:i1] |= np.hypot((ii - ci) * LAT, (jj - cj) * LAT) <= PLACE_RADIUS_M
    counts["places"] = len(places)
    return city, forest, counts


def sea_mask(T: np.ndarray) -> np.ndarray:
    """elevation == 0 cells 4-connected to the window edge (flood fill)."""
    zero = T <= 0.0
    sea = np.zeros((N, N), dtype=bool)
    dq = deque()
    for i in range(N):
        for (r, c) in ((0, i), (N - 1, i), (i, 0), (i, N - 1)):
            if zero[r, c] and not sea[r, c]:
                sea[r, c] = True
                dq.append((r, c))
    while dq:
        r, c = dq.popleft()
        for rr, cc in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
            if 0 <= rr < N and 0 <= cc < N and zero[rr, cc] and not sea[rr, cc]:
                sea[rr, cc] = True
                dq.append((rr, cc))
    return sea


def dist_to_mask(mask: np.ndarray, max_m: float) -> np.ndarray:
    """Euclidean distance (m) to the nearest True cell, exact up to max_m, max_m + 1 beyond."""
    R = int(math.ceil(max_m / LAT))
    best = np.full((N, N), np.inf)
    for dz in range(-R, R + 1):
        for dx in range(-R, R + 1):
            d = math.hypot(dx, dz) * LAT
            if d > max_m:
                continue
            sh = np.zeros((N, N), dtype=bool)
            zs = slice(max(dz, 0), N + min(dz, 0))
            zd = slice(max(-dz, 0), N + min(-dz, 0))
            xs = slice(max(dx, 0), N + min(dx, 0))
            xd = slice(max(-dx, 0), N + min(-dx, 0))
            sh[zd, xd] = mask[zs, xs]
            best = np.where(sh & (d < best), d, best)
    return np.where(np.isfinite(best), best, max_m + 1.0)


def make_weights(T: np.ndarray, sea: np.ndarray, city_m: np.ndarray, forest_m: np.ndarray):
    e = T.astype(np.float64)
    land = (~sea).astype(np.float64)
    gz, gx = np.gradient(e, LAT)
    slope = np.hypot(gx, gz)  # rise over run
    city = np.clip(blur(city_m * land, BLUR_SIGMA), 0.0, 1.0)
    forest = np.clip(blur(forest_m * land, BLUR_SIGMA), 0.0, 1.0)
    desert = np.zeros((N, N))
    mountain = np.clip(blur(smoothstep(250.0, 350.0, e), BLUR_SIGMA), 0.0, 1.0)
    hills_elev = smoothstep(60.0, 100.0, e) * (1.0 - smoothstep(250.0, 350.0, e))
    hills = np.clip(blur(hills_elev * smoothstep(0.08, 0.25, slope), BLUR_SIGMA), 0.0, 1.0)
    d = dist_to_mask(sea, COAST_RANGE_M)
    coast = np.clip(blur(np.clip(1.0 - d / COAST_RANGE_M, 0.0, 1.0), BLUR_SIGMA), 0.0, 1.0)
    planes = [city, forest, desert, mountain, hills, coast]
    return np.stack([np.clip(np.round(p * 255.0), 0, 255).astype(np.uint8) for p in planes])


# ---------------------------------------------------------------------------------------------- sea polygons
def sea_polygons(sea: np.ndarray):
    """Hole-free sea shapes: every sea lattice cell is the 64 m square around its point; runs of equal row
    extents are merged vertically into rectangles (exact, and cheap for the water scanline fill in osm_world.gd)."""
    rects = []
    active = {}  # (i0, i1) -> first row

    def edge(i):
        return max(min(X0 + LAT * i, HALF), -HALF)

    def close(key, j_first, j_last):
        i0, i1 = key
        xa, xb = edge(i0 - 0.5), edge(i1 + 0.5)
        za, zb = edge(j_first - 0.5), edge(j_last + 0.5)
        rects.append([[round(xa, 1), round(za, 1)], [round(xb, 1), round(za, 1)], [round(xb, 1), round(zb, 1)], [round(xa, 1), round(zb, 1)]])

    for j in range(N):
        row = sea[j]
        d = np.diff(np.concatenate([[0], row.astype(np.int8), [0]]))
        starts = np.flatnonzero(d == 1)
        ends = np.flatnonzero(d == -1) - 1
        cur = {(int(s), int(e)) for s, e in zip(starts, ends)}
        for key in sorted(set(active) - cur):
            close(key, active.pop(key), j - 1)
        for key in sorted(cur - set(active)):
            active[key] = j
    for key in sorted(active):
        close(key, active[key], N - 1)
    return rects


# ---------------------------------------------------------------------------------------------- main
def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    T = load_terrain()
    T.astype("<f4").tofile(os.path.join(OUT, "terrain.bin"))
    print("terrain.bin  %dx%d float32 LE  min %.1f max %.1f m" % (N, N, float(T.min()), float(T.max())))

    osm = Osm()
    osm.load()
    print("osm cache: %d files, %d nodes, %d ways, %d relations" % (len(osm.files), len(osm.nodes), len(osm.ways), len(osm.rels)))
    n_landuse = sum(1 for f in osm.files if f[0].startswith("landuse_"))
    if n_landuse == 0:
        print("WARNING: no landuse_*.json found (run tools/fetch_lofoten_landuse.py); CITY/FOREST planes come from tile_*.json only")

    nodes, edges, spawn, yaw, spawn_name, km, rstats = build_roads(osm, T)
    dump(os.path.join(OUT, "network.json"), {"nodes": nodes, "edges": edges, "spawn": spawn})
    print("network.json %d nodes, %d edges, %.1f km  types %s  bridges %d tunnels %d (all written as kind=road)" % (
        len(nodes), len(edges), km, rstats["types"], rstats["bridge_edges"], rstats["tunnel_edges"]))
    print("  spawn edge %d s %.1f yaw %.1f (%s)" % (spawn["edge"], spawn["s"], yaw, spawn_name))

    bld, n_b = build_buildings(osm)
    dump(os.path.join(OUT, "buildings.json"), bld)
    print("buildings.json %d footprints in %d tiles" % (n_b, len(bld)))

    sea = sea_mask(T)
    city_m, forest_m, lc = landuse_masks(osm)
    W = make_weights(T, sea, city_m, forest_m)
    W.tofile(os.path.join(OUT, "weights.bin"))
    land = ~sea
    names = ["city", "forest", "desert", "mountain", "hills", "coast"]
    print("weights.bin  %d bytes; landuse polys %s" % (W.size, lc))
    print("  mean weight per plane (0..1): " + ", ".join("%s %.3f" % (n, float(W[i].mean()) / 255.0) for i, n in enumerate(names)))

    rects = sea_polygons(sea)
    default_spawn = {"edge": spawn["edge"], "s": spawn["s"], "id": "lofoten_spawn", "region": "lofoten", "yaw": round(yaw, 1)}
    meta = {
        "n": N, "lattice": LAT, "origin": X0,
        "regions": [{"id": "lofoten", "name": "Lofoten", "bounds": [-16384, -16384, 16384, 16384]}],
        "spawns": [], "petrol": [], "landmarks": [], "water": [], "sea": rects, "labels": [],
        "default_spawn": default_spawn, "attribution": ATTRIBUTION,
    }
    dump(os.path.join(OUT, "meta.json"), meta)
    print("meta.json    %d sea rectangles" % len(rects))

    land_pct = 100.0 * float(land.mean())
    forest_pct = 100.0 * float((W[1][land] > 127).mean()) if land.any() else 0.0
    forest_all = 100.0 * float((W[1] > 127).mean())
    print("SUMMARY nodes=%d edges=%d road_km=%.1f buildings=%d land%%=%.1f forest%%_of_land(w>0.5)=%.1f forest%%_of_window=%.1f" % (
        len(nodes), len(edges), km, n_b, land_pct, forest_pct, forest_all))


if __name__ == "__main__":
    main()
