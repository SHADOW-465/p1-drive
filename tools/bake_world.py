#!/usr/bin/env python3
"""tools/bake_world.py - bakes data/world/country.json + regions/*.json (real OSM, see docs/REGION_SCHEMA.md)
into the compact runtime files in data/world/baked/ that the game loads (world/osm_world.gd):

  network.json   road graph in the RoadGraph format (dense 10 m splines, per-edge width, vertical profile fixed)
  terrain.bin    513x513 float32, 64 m lattice, world x/z = -16384 + 64 * i; country heightfield conformed to the ground roads
  weights.bin    6 x 513x513 uint8 biome planes (CITY, FOREST, DESERT, MOUNTAIN, HILLS, COAST); COUNTRY = remainder
  buildings.json OSM footprints per 1024 m tile
  meta.json      regions, labels, spawns, petrol stations, landmarks, water polygons (with level), sea polygons

Why a bake step: the region files are ~11 MB of JSON, and the OSM data disagrees with the SRTM country heightfield in
the mountains (Hakone roads sit up to 300 m under it) and puts every overpass on the ground. The bake
  1. conforms the terrain to the ground roads with a smooth residual field (so the terrain follows the roads),
  2. re-profiles the three motorways over that terrain (grade/curvature limited, anchored on the interchange nodes),
  3. lifts roads that cross another road at the same height (overpasses) and splits bridges/tunnels off,
so the game never has to cut a 300 m canyon or drive through a crossing.
Needs numpy, scipy, Pillow. Run: python tools/bake_world.py   (deterministic)
"""
import json
import math
import collections
import heapq
import os
import struct
import sys
import numpy as np
from scipy.ndimage import gaussian_filter, gaussian_filter1d
from scipy.spatial import cKDTree
from PIL import Image, ImageDraw
from clean_network import build_clean_network

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "data", "world")
OUT = os.path.join(SRC, "baked")
X0 = -16384.0
LAT = 64.0
N = 513
DENSE = 10.0
TILE = 1024.0
CLEAR = 6.2  # vertical clearance between a deck and the road under it
RK = 1400.0  # radius of the terrain conforming kernel
TYPE_MAP = {"highway": "highway", "arterial": "arterial", "city": "city", "country": "country", "mountain": "mountain", "jebel_jais": "mountain", "ramp": "ramp"}
LABELS = {"tokyo_ginza_c1": ("TOKYO GINZA C1", True), "tokyo_shibuya": ("TOKYO SHIBUYA", False), "hakone": ("HAKONE", True), "shonan_coast": ("SHONAN COAST", False),
          "monaco": ("MONACO", True), "col_de_turini": ("COL DE TURINI", True), "turini_coast_link": ("TURINI COAST LINK", False),
          "dubai_downtown": ("DUBAI DOWNTOWN", True), "dubai_marina": ("DUBAI MARINA", False), "dubai_desert": ("DUBAI DESERT", False), "jebel_jais": ("JEBEL JAIS", True)}
KIND_RANK = {"overpass": 2, "bridge": 2, "road": 1, "tunnel": 0}
CLASS_RANK = {"highway": 3, "ramp": 2, "arterial": 2, "city": 1, "country": 1, "mountain": 1}


def load(name):
    with open(os.path.join(SRC, name), "r", encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------------ country heightfield (Catmull-Rom bicubic, as the data builder)
class Heightfield:
    def __init__(self, hf):
        self.v = np.array(hf["values_m"], dtype=np.float64)
        self.n = self.v.shape[0]
        b = hf["bounds_m"]
        self.x0 = b["min"][0]
        self.z0 = b["min"][1]
        self.cell = (b["max"][0] - b["min"][0]) / (self.n - 1)

    @staticmethod
    def _w(t):
        t2 = t * t
        t3 = t2 * t
        return [0.5 * (-t3 + 2 * t2 - t), 0.5 * (3 * t3 - 5 * t2 + 2), 0.5 * (-3 * t3 + 4 * t2 + t), 0.5 * (t3 - t2)]

    def at(self, x, z):
        x = np.asarray(x, dtype=np.float64)
        z = np.asarray(z, dtype=np.float64)
        fx = np.clip((x - self.x0) / self.cell, 0, self.n - 1.0001)
        fz = np.clip((z - self.z0) / self.cell, 0, self.n - 1.0001)
        ix = np.floor(fx).astype(int)
        iz = np.floor(fz).astype(int)
        wx = self._w(fx - ix)
        wz = self._w(fz - iz)
        out = np.zeros_like(fx)
        for j in range(4):
            jj = np.clip(iz + j - 1, 0, self.n - 1)
            for i in range(4):
                ii = np.clip(ix + i - 1, 0, self.n - 1)
                out += wz[j] * wx[i] * self.v[jj, ii]
        return out


# ------------------------------------------------------------------ splines
def spline(ctrl, sub=8):
    """Centripetal Catmull-Rom through ctrl (Nx3), same maths as RoadGraph.spline."""
    n = len(ctrl)
    if n < 3:
        return np.array(ctrl, dtype=np.float64)
    out = []
    for i in range(n - 1):
        p1 = ctrl[i]
        p2 = ctrl[i + 1]
        p0 = ctrl[i - 1] if i > 0 else p1 * 2.0 - p2
        p3 = ctrl[i + 2] if i < n - 2 else p2 * 2.0 - p1
        t1 = math.sqrt(np.linalg.norm(p0 - p1))
        t2 = t1 + math.sqrt(np.linalg.norm(p1 - p2))
        t3 = t2 + math.sqrt(np.linalg.norm(p2 - p3))
        if t2 - t1 < 1e-9:
            continue
        for k in range(sub):
            t = t1 + (t2 - t1) * k / sub
            a1 = p0 + (p1 - p0) * (t / t1) if t1 > 0 else p1
            a2 = p1 + (p2 - p1) * ((t - t1) / (t2 - t1))
            a3 = p2 + (p3 - p2) * ((t - t2) / (t3 - t2)) if t3 > t2 else p2
            b1 = a1 + (a2 - a1) * (t / t2)
            b2 = a2 + (a3 - a2) * ((t - t1) / (t3 - t1))
            out.append(b1 + (b2 - b1) * ((t - t1) / (t2 - t1)))
    out.append(ctrl[-1])
    return np.array(out)


def resample(pts, step):
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    total = s[-1]
    count = max(int(round(total / step)), 1)
    u = np.linspace(0.0, total, count + 1)
    return np.stack([np.interp(u, s, pts[:, c]) for c in range(3)], axis=1)


def dedupe(ctrl, eps=0.4):
    out = [ctrl[0]]
    for p in ctrl[1:]:
        if np.linalg.norm(p - out[-1]) > eps:
            out.append(p)
    if len(out) == 1:
        out.append(ctrl[-1] + np.array([0.5, 0.0, 0.0]))
    return np.array(out)


def densify(ctrl):
    ctrl = dedupe(np.array(ctrl, dtype=np.float64))
    return resample(spline(ctrl, 8), DENSE)


def arclen(p):
    return np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(p[:, [0, 2]], axis=0), axis=1))])


# ------------------------------------------------------------------ graph assembly
class Graph:
    def __init__(self):
        self.nodes = []  # dict(p, kind, id)
        self.nid = {}
        self.edges = []  # dict(...)

    def node(self, key, p, kind="normal"):
        if key in self.nid:
            return self.nid[key]
        self.nodes.append({"p": [float(p[0]), float(p[1]), float(p[2])], "kind": kind, "id": key})
        self.nid[key] = len(self.nodes) - 1
        return self.nid[key]

    def new_node(self, p, kind="normal"):
        key = "n%d" % len(self.nodes)
        return self.node(key, p, kind)

    def edge(self, **kw):
        self.edges.append(kw)
        return len(self.edges) - 1


def build_graph(country, regions):
    g = Graph()
    for r in regions:
        for j in r["junctions"]:
            kind = "merge" if j["type"] == "merge" else "normal"
            g.node(j["id"], j["position"], kind)
    for r in regions:
        for x in r["roads"]:
            t = TYPE_MAP.get(x["type"], "country")
            kind = x["kind"] if x["kind"] in ("road", "overpass", "tunnel", "bridge") else "road"
            g.edge(src=x["id"], type=t, kind=kind, width=float(x["width_m"]), ctrl=np.array(x["control_points"], dtype=np.float64),
                   a=g.nid[x["start_junction"]], b=g.nid[x["end_junction"]], name=x.get("name", ""), motorway=False, region=r["region_id"],
                   road_class=x.get("road_class", ""), osm=x.get("osm_highway", ""), orig_type=x["type"])
    ics = {i["id"]: i for i in country["interchanges"]}
    for m in country["motorways"]:
        cp = np.array(m["control_points"], dtype=np.float64)
        cut = []  # (ctrl index, node idx)
        for iid in m["interchange_ids"]:
            ic = ics[iid]
            p = np.array(ic["position"], dtype=np.float64)
            d = np.hypot(cp[:, 0] - p[0], cp[:, 2] - p[2])
            k = int(np.argmin(d))
            if d[k] > 2.0:
                raise SystemExit("interchange %s not on %s" % (iid, m["id"]))
            if ic.get("region_junction_id") and ic["region_junction_id"] in g.nid:
                ni = g.nid[ic["region_junction_id"]]
            else:
                ni = g.node(iid, [cp[k][0], cp[k][1], cp[k][2]], "normal")
            cut.append((k, ni))
        cut.sort()
        for (k0, n0), (k1, n1) in zip(cut, cut[1:]):
            seg = cp[k0:k1 + 1].copy()
            g.edge(src="%s_%d" % (m["id"], k0), type="highway", kind="road", width=22.0, ctrl=seg, a=n0, b=n1, name=m["name"], motorway=True, region="",
                   road_class="motorway", osm="motorway", orig_type="highway")
        # the motorway keeps its y here; re-profiled later
    return g


def _edge_len_xz(ctrl):
    if len(ctrl) < 2:
        return 0.0
    d = np.diff(ctrl[:, [0, 2]], axis=0)
    return float(np.sum(np.hypot(d[:, 0], d[:, 1])))


def _smooth_ctrl_xz(ctrl, max_shift=2.2):
    """Gentle horizontal relaxation for interior points of city/country boulevards so cruising flows
    smoothly instead of following jagged OSM digitization kinks. Endpoints and heights stay exact."""
    if len(ctrl) < 5:
        return ctrl
    out = ctrl.copy()
    for col in (0, 2):
        v = out[:, col].copy()
        s = gaussian_filter1d(v, 1.0, mode="nearest")
        # Taper smoothing to 0 at endpoints so junction tangents stay clean
        w = np.ones(len(v))
        w[0] = 0.0
        w[-1] = 0.0
        if len(v) > 3:
            w[1] = 0.45
            w[-2] = 0.45
        delta = np.clip((s - v) * w, -max_shift, max_shift)
        out[:, col] = v + delta
    return out


def relax_network(g, country, regions):
    """Curates the raw OSM road graph into a relaxing, loop-connected driving network:
      1. Drops redundant low-hierarchy city maze clutter (residential/service/unclassified alleys,
         narrow dense tertiary streets, short slip fragments) ONLY when an alternate route exists.
      2. Iteratively prunes city dead-end stubs while preserving scenic mountain passes, long
         scenic highway/desert spurs (>= 1200 m), motorways, interchanges, spawns & petrol access.
      3. Prunes short redundant chords and high-degree tangle knots (deg >= 5).
      4. Merges degree-2 continuation chains into long, sweeping uninterrupted boulevards.
      5. Smooths jagged horizontal kinks on non-mountain roads and compacts unused nodes.
    Guarantees a single connected component across the entire country."""
    ic_nodes = set()
    for ic in country["interchanges"]:
        if ic.get("region_junction_id") and ic["region_junction_id"] in g.nid:
            ic_nodes.add(g.nid[ic["region_junction_id"]])
        elif ic["id"] in g.nid:
            ic_nodes.add(g.nid[ic["id"]])

    # Anchors that must stay directly served by the road network (spawns, petrol stations, gate routes)
    anchors = [
        (8233.6, 461.8), (-7394.9, -1119.6), (-3656.9, 5441.1),  # smoothness gate starts
        (9777.0, -1692.0), (-8057.4, 241.2), (-553.0, 5500.0),   # fps gate spawns
    ]
    for r in regions:
        for sp in r["spawns"]:
            anchors.append((sp["position"][0], sp["position"][2]))
        for p in r["petrol_stations"]:
            anchors.append((p["position"][0], p["position"][2]))

    for e in g.edges:
        e["len"] = _edge_len_xz(e["ctrl"])

    def edge_min_dist(e, ax, az):
        c = e["ctrl"]
        return float(np.min(np.hypot(c[:, 0] - ax, c[:, 2] - az)))

    protected = set()
    for ax, az in anchors:
        best_e = min(g.edges, key=lambda e: edge_min_dist(e, ax, az))
        protected.add(best_e["src"])
    for e in g.edges:
        if e["motorway"] or e["a"] in ic_nodes or e["b"] in ic_nodes or e["orig_type"] in ("mountain", "jebel_jais"):
            protected.add(e["src"])

    def build_adj(elist):
        adj = collections.defaultdict(list)
        for e in elist:
            adj[e["a"]].append((e["b"], e["src"]))
            adj[e["b"]].append((e["a"], e["src"]))
        return adj

    def remove_adj(adj, e):
        sid = e["src"]
        adj[e["a"]] = [(v, eid) for v, eid in adj[e["a"]] if eid != sid]
        adj[e["b"]] = [(v, eid) for v, eid in adj[e["b"]] if eid != sid]

    def has_alt_path(adj, a, b, skip_id, max_hops=12):
        vis = {a}
        q = collections.deque([(a, 0)])
        while q:
            u, d = q.popleft()
            if d >= max_hops:
                continue
            for v, eid in adj[u]:
                if eid == skip_id:
                    continue
                if v == b:
                    return True
                if v not in vis:
                    vis.add(v)
                    q.append((v, d + 1))
        return False

    def drop_priority(e):
        osm = e.get("osm", "")
        if osm == "service":
            return 0
        if osm == "residential":
            return 1
        if osm == "unclassified" and e["orig_type"] not in ("mountain", "jebel_jais"):
            return 2
        if e.get("road_class") == "street":
            return 3
        if osm == "tertiary_link":
            return 4
        if osm == "tertiary" and e["region"] in ("monaco_alps", "tokyo_hakone"):
            return 5
        if osm == "secondary_link":
            return 6
        if osm == "primary_link":
            return 7
        if osm == "motorway_link" and e["len"] < 180.0:
            return 8
        return 99

    cur = list(g.edges)
    raw_n = len(cur)
    adj = build_adj(cur)

    # 1. Drop redundant low-class maze edges while keeping alternate loop paths
    cands = [e for e in cur if e["src"] not in protected and drop_priority(e) < 10]
    cands.sort(key=lambda e: (drop_priority(e), e["len"]))
    dropped = set()
    for e in cands:
        if has_alt_path(adj, e["a"], e["b"], e["src"], max_hops=12):
            dropped.add(e["src"])
            remove_adj(adj, e)
    cur = [e for e in cur if e["src"] not in dropped]

    # 2. Iteratively prune city dead ends (keep protected, mountain passes, and scenic spurs >= 1200 m)
    def prune_dead_ends(elist):
        adj_d = build_adj(elist)
        changed = True
        pruned = 0
        while changed:
            changed = False
            nxt = []
            for e in elist:
                da, db = len(adj_d[e["a"]]), len(adj_d[e["b"]])
                if (da == 1 or db == 1) and e["src"] not in protected and e["orig_type"] not in ("mountain", "jebel_jais"):
                    osm = e.get("osm", "")
                    if e["len"] < 1200.0 or e.get("road_class") == "street" or "_link" in osm or osm in ("residential", "service", "unclassified"):
                        remove_adj(adj_d, e)
                        pruned += 1
                        changed = True
                        continue
                nxt.append(e)
            elist = nxt
        return elist, pruned

    cur, n_de1 = prune_dead_ends(cur)

    # 3. Prune short redundant chords (< 65 m), high-degree knot clutter (deg >= 5), and tight Monaco maze webs
    adj = build_adj(cur)
    cands3 = sorted(cur, key=lambda e: (e["width"], e["len"]))
    dropped3 = set()
    for e in cands3:
        if e["src"] in protected or e["motorway"]:
            continue
        da, db = len(adj[e["a"]]), len(adj[e["b"]])
        is_short_chord = e["len"] < 65.0 and da >= 3 and db >= 3
        is_knot = (da >= 5 or db >= 5) and e["len"] < 220.0
        is_monaco_web = e["region"] == "monaco_alps" and e.get("osm") in ("secondary", "tertiary") and e["len"] < 160.0 and da >= 3 and db >= 3
        if (is_short_chord or is_knot or is_monaco_web) and has_alt_path(adj, e["a"], e["b"], e["src"], max_hops=6):
            dropped3.add(e["src"])
            remove_adj(adj, e)
    cur = [e for e in cur if e["src"] not in dropped3]
    cur, n_de2 = prune_dead_ends(cur)

    # 4. Merge degree-2 continuation chains into smooth, flowing boulevards
    merges = 0
    changed = True
    while changed:
        changed = False
        adj_e = collections.defaultdict(list)
        for i, e in enumerate(cur):
            adj_e[e["a"]].append(i)
            adj_e[e["b"]].append(i)
        for n, eis in list(adj_e.items()):
            if len(eis) != 2 or n in ic_nodes:
                continue
            i0, i1 = eis
            if i0 == i1:
                continue
            e0, e1 = cur[i0], cur[i1]
            if e0["motorway"] or e1["motorway"]:
                continue
            if e0["type"] != e1["type"] or e0["kind"] != e1["kind"]:
                continue
            if abs(e0["width"] - e1["width"]) > 2.5:
                continue
            na = e0["a"] if e0["b"] == n else e0["b"]
            nb = e1["b"] if e1["a"] == n else e1["a"]
            if na == nb:
                continue
            p0 = e0["ctrl"] if e0["b"] == n else e0["ctrl"][::-1]
            p1 = e1["ctrl"] if e1["a"] == n else e1["ctrl"][::-1]
            if len(p0) >= 2 and len(p1) >= 2:
                v0 = p0[-1, [0, 2]] - p0[-2, [0, 2]]
                v1 = p1[1, [0, 2]] - p1[0, [0, 2]]
                l0, l1 = float(np.linalg.norm(v0)), float(np.linalg.norm(v1))
                if l0 > 1e-3 and l1 > 1e-3 and float(np.dot(v0, v1)) / (l0 * l1) < 0.2:
                    continue  # sharp corner: keep junction node
            ne = dict(e0)
            ne["a"] = na
            ne["b"] = nb
            ne["ctrl"] = np.concatenate([p0, p1[1:]], axis=0)
            ne["len"] = e0["len"] + e1["len"]
            ne["width"] = max(e0["width"], e1["width"])
            if e1["src"] in protected:
                protected.add(ne["src"])
            cur[i0] = ne
            cur.pop(i1)
            merges += 1
            changed = True
            break

    # 5. Gentle horizontal smoothing on non-mountain roads (endpoints stay pinned on junctions)
    for e in cur:
        if not e["motorway"] and e["orig_type"] not in ("mountain", "jebel_jais"):
            e["ctrl"] = _smooth_ctrl_xz(e["ctrl"], max_shift=2.0)

    # 6. Compact unused nodes so network.json stays lean and has zero orphan nodes
    used = sorted({e["a"] for e in cur} | {e["b"] for e in cur})
    remap = {old: new for new, old in enumerate(used)}
    new_nodes = []
    new_nid = {}
    for old in used:
        nd = g.nodes[old]
        new_nid[nd["id"]] = len(new_nodes)
        new_nodes.append(nd)
    for e in cur:
        e["a"] = remap[e["a"]]
        e["b"] = remap[e["b"]]
    g.nodes = new_nodes
    g.nid = new_nid
    g.edges = cur

    # Verify single connected component
    adj_chk = build_adj(g.edges)
    start = next(iter(adj_chk))
    vis = {start}
    q = [start]
    while q:
        u = q.pop()
        for v, _ in adj_chk[u]:
            if v not in vis:
                vis.add(v)
                q.append(v)
    if len(vis) != len(adj_chk):
        raise SystemExit("relax_network disconnected graph: %d / %d reachable" % (len(vis), len(adj_chk)))
    degs = collections.Counter(len(v) for v in adj_chk.values())
    print("relax_network: %d -> %d edges (%d maze, %d dead-ends, %d chords/knots, %d merged), %d nodes, deg1=%d, deg>=5=%d" % (
        raw_n, len(g.edges), len(dropped), n_de1 + n_de2, len(dropped3), merges, len(g.nodes),
        degs[1], sum(c for d, c in degs.items() if d >= 5)))


# ------------------------------------------------------------------ terrain conforming
def conform_terrain(hf, g):
    xs = X0 + LAT * np.arange(N)
    gx, gz = np.meshgrid(xs, xs)  # [row=z, col=x]
    base = hf.at(gx, gz)
    num = np.zeros(N * N)
    den = np.zeros(N * N)
    pts = []
    for e in g.edges:
        if e["motorway"]:
            continue
        d = e["dense"][::2]
        dev = d[:, 1] - hf.at(d[:, 0], d[:, 2])
        # real tunnels (a little under the heightfield) keep their cover; everything else is a ground road the terrain must follow
        pts.append(d if e["kind"] != "tunnel" else d[dev < -30.0])
    pts = np.concatenate(pts)
    res = pts[:, 1] - hf.at(pts[:, 0], pts[:, 2])
    K = int(RK / LAT) + 1
    fxi = (pts[:, 0] - X0) / LAT
    fzi = (pts[:, 2] - X0) / LAT
    bx = np.floor(fxi).astype(int)
    bz = np.floor(fzi).astype(int)
    for dz in range(-K, K + 2):
        for dx in range(-K, K + 2):
            cx = bx + dx
            cz = bz + dz
            ok = (cx >= 0) & (cx < N) & (cz >= 0) & (cz < N)
            ddx = (cx - fxi) * LAT
            ddz = (cz - fzi) * LAT
            q = (ddx * ddx + ddz * ddz) / (RK * RK)
            ok &= q < 1.0
            if not ok.any():
                continue
            w = (1.0 - q[ok]) ** 2 / (1.0 + (ddx[ok] ** 2 + ddz[ok] ** 2) / (120.0 ** 2)) ** 2
            idx = cz[ok] * N + cx[ok]
            num += np.bincount(idx, weights=w * res[ok], minlength=N * N)
            den += np.bincount(idx, weights=w, minlength=N * N)
    corr = (num / (den + 0.4)).reshape(N, N)
    print("terrain residual: min %.1f max %.1f  (roads under the heightfield -> terrain lowered)" % (corr.min(), corr.max()))
    return base, base + corr


def poly_mask(polys, scale=1.0):
    """Rasterise polygons (world xz lists) onto the lattice; returns float mask 0/1."""
    im = Image.new("L", (N, N), 0)
    dr = ImageDraw.Draw(im)
    for poly in polys:
        pts = [((p[0] - X0) / LAT, (p[1] - X0) / LAT) for p in poly]
        if len(pts) >= 3:
            dr.polygon(pts, fill=255)
    return np.asarray(im, dtype=np.float64) / 255.0


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ vertical profile helpers
def sample_grid(T, x, z):
    fx = np.clip((np.asarray(x) - X0) / LAT, 0, N - 1.001)
    fz = np.clip((np.asarray(z) - X0) / LAT, 0, N - 1.001)
    ix = fx.astype(int)
    iz = fz.astype(int)
    tx = fx - ix
    tz = fz - iz
    return (T[iz, ix] * (1 - tx) + T[iz, ix + 1] * tx) * (1 - tz) + (T[iz + 1, ix] * (1 - tx) + T[iz + 1, ix + 1] * tx) * tz


def lipschitz(y, dy):
    """Closest profile with |y[i]-y[i-1]| <= dy[i]; dy is a scalar or a per-step array."""
    y = y.copy()
    dy = np.broadcast_to(dy, y.shape)
    for i in range(1, len(y)):
        y[i] = min(max(y[i], y[i - 1] - dy[i]), y[i - 1] + dy[i])
    for i in range(len(y) - 2, -1, -1):
        y[i] = min(max(y[i], y[i + 1] - dy[i + 1]), y[i + 1] + dy[i + 1])
    return y


def profile_motorway(T, pts_xz, anchors, h, gmax):
    """Terrain-following grade-limited profile: smoothed terrain, pinned at the interchange heights."""
    ystar = sample_grid(T, pts_xz[:, 0], pts_xz[:, 1])
    y = gaussian_filter1d(ystar, 200.0 / h, mode="nearest")
    n = len(y)
    pins = dict(anchors)
    ks = sorted(pins)
    if not ks or ks[0] != 0:
        ks = [0] + ks
        pins.setdefault(0, y[0])
    if ks[-1] != n - 1:
        ks.append(n - 1)
        pins.setdefault(n - 1, y[-1])
    # local mismatch correction around each pin: a cosine bump wide enough that it adds at most ~0.7 gmax of slope
    idx = np.arange(n)
    corr = np.zeros(n)
    for k in ks:
        d = pins[k] - y[k]
        W = max(40.0, abs(d) * math.pi / 2.0 / (0.7 * gmax) / h)
        u = np.clip(np.abs(idx - k) / W, 0.0, 1.0)
        corr += d * (0.5 + 0.5 * np.cos(math.pi * u)) * (u < 1.0)
    y = y + corr
    # grade allowed per step: gmax, or what the pins force (a coastal interchange 150 m under the next one is steep, not impossible)
    dy = np.full(n, gmax * h)
    lo = np.full(n, -1e9)
    hi = np.full(n, 1e9)
    for k0, k1 in zip(ks, ks[1:]):
        need = abs(pins[k1] - pins[k0]) / max((k1 - k0) * h, 1.0) * 1.15
        if need > gmax:
            print("   note: pins %d-%d force %.1f%% grade" % (k0, k1, need * 100))
        g = max(gmax, need)
        dy[k0 + 1:k1 + 1] = g * h
        i = np.arange(k0, k1 + 1)
        lo[k0:k1 + 1] = np.maximum(pins[k0] - (i - k0) * g * h, pins[k1] - (k1 - i) * g * h)
        hi[k0:k1 + 1] = np.minimum(pins[k0] + (i - k0) * g * h, pins[k1] + (k1 - i) * g * h)
    hi = np.maximum(hi, lo)
    for _ in range(40):
        y = np.clip(y, lo, hi)
        y = lipschitz(y, dy)
        y = gaussian_filter1d(y, 85.0 / h, mode="nearest")
    y = np.clip(np.maximum(y, 1.5), lo, hi)
    for k in ks:
        y[k] = pins[k]
    return y


# ------------------------------------------------------------------ crossings
def seg_inter(a, b, c, d):
    r = (b[0] - a[0], b[1] - a[1])
    s = (d[0] - c[0], d[1] - c[1])
    den = r[0] * s[1] - r[1] * s[0]
    if abs(den) < 1e-9:
        return None
    qp = (c[0] - a[0], c[1] - a[1])
    t = (qp[0] * s[1] - qp[1] * s[0]) / den
    u = (qp[0] * r[1] - qp[1] * r[0]) / den
    if 0.0 <= t <= 1.0 and 0.0 <= u <= 1.0:
        return t, u
    return None


def find_crossings(g):
    grid = collections.defaultdict(list)
    for ei, e in enumerate(g.edges):
        d = e["dense"]
        for i in range(len(d) - 1):
            x0, x1 = d[i][0], d[i + 1][0]
            z0, z1 = d[i][2], d[i + 1][2]
            for cx in range(int(min(x0, x1) // 64), int(max(x0, x1) // 64) + 1):
                for cz in range(int(min(z0, z1) // 64), int(max(z0, z1) // 64) + 1):
                    grid[(cx, cz)].append((ei, i))
    seen = set()
    out = []
    for cell, lst in grid.items():
        for ia in range(len(lst)):
            ea, ia_s = lst[ia]
            for ib in range(ia + 1, len(lst)):
                eb, ib_s = lst[ib]
                if ea == eb:
                    continue
                key = (ea, ia_s, eb, ib_s) if ea < eb else (eb, ib_s, ea, ia_s)
                if key in seen:
                    continue
                seen.add(key)
                A = g.edges[ea]
                B = g.edges[eb]
                da, db = A["dense"], B["dense"]
                h = seg_inter(da[ia_s][[0, 2]], da[ia_s + 1][[0, 2]], db[ib_s][[0, 2]], db[ib_s + 1][[0, 2]])
                if h is None:
                    continue
                t, u = h
                # Edges sharing a node cross there by construction. A ramp that leaves a node and loops back
                # over the same motorway further on is a real crossing and needs its clearance.
                shared = {A["a"], A["b"]} & {B["a"], B["b"]}
                if shared:
                    px = da[ia_s][[0, 2]] + (da[ia_s + 1][[0, 2]] - da[ia_s][[0, 2]]) * t
                    if min(math.hypot(px[0] - g.nodes[n]["p"][0], px[1] - g.nodes[n]["p"][2]) for n in shared) < 60.0:
                        continue
                out.append((ea, ia_s + t, eb, ib_s + u))
    return out


def smooth_bump(d, plat, wl, wr):
    """Lift profile along signed distance d: 1 on [-plat, plat], smoothstep to 0 over wl before / wr after."""
    v = np.zeros_like(d)
    inside = np.abs(d) <= plat
    v[inside] = 1.0
    l = (d < -plat) & (d > -plat - wl)
    v[l] = 1.0 - smoothstep(0.0, 1.0, (-d[l] - plat) / max(wl, 1.0))
    r = (d > plat) & (d < plat + wr)
    v[r] = 1.0 - smoothstep(0.0, 1.0, (d[r] - plat) / max(wr, 1.0))
    return v


def resolve_crossings(g):
    cr = find_crossings(g)
    inc = collections.defaultdict(list)  # node -> [(edge, end)]
    for ei, e in enumerate(g.edges):
        inc[e["a"]].append((ei, 0))
        inc[e["b"]].append((ei, 1))
    lift = [np.zeros(len(e["dense"])) for e in g.edges]
    n_lift = 0
    for ea, fa, eb, fb in cr:
        A, B = g.edges[ea], g.edges[eb]
        ya = np.interp(fa, np.arange(len(A["dense"])), A["dense"][:, 1])
        yb = np.interp(fb, np.arange(len(B["dense"])), B["dense"][:, 1])
        if abs(ya - yb) >= CLEAR:
            continue
        ra = (KIND_RANK[A["orig_kind"]], CLASS_RANK[A["type"]], ya)
        rb = (KIND_RANK[B["orig_kind"]], CLASS_RANK[B["type"]], yb)
        if ra >= rb:
            top, ft, ytop, ybot, other = ea, fa, ya, yb, B
        else:
            top, ft, ytop, ybot, other = eb, fb, yb, ya, A
        need = ybot + CLEAR - ytop
        if need <= 0.05:
            continue
        # distance along the chain from the crossing to the nearest non-through node each way
        E = g.edges[top]
        s = arclen(E["dense"])
        s0 = np.interp(ft, np.arange(len(s)), s)
        W = 150.0
        plat = 0.5 * other["width"] + 6.0
        avail = [s0, s[-1] - s0]
        # walk through degree-2 nodes
        chain = [(top, 0.0)]
        for side in (0, 1):
            cur, cend, acc = top, (0 if side == 0 else 1), (s0 if side == 0 else s[-1] - s0)
            guard = 0
            while acc < plat + W and guard < 8:
                guard += 1
                node = g.edges[cur]["a"] if cend == 0 else g.edges[cur]["b"]
                lst = inc[node]
                if len(lst) != 2:
                    break
                nxt = lst[0] if lst[1] == (cur, cend) else lst[1]
                if nxt[0] == cur:
                    break
                ne, nend = nxt
                nlen = arclen(g.edges[ne]["dense"])[-1]
                chain.append((ne, (acc, nend)))
                acc += nlen
                cur, cend = ne, 1 - nend
            avail[side] = acc
        wl = min(W, max(avail[0] - plat, 8.0))
        wr = min(W, max(avail[1] - plat, 8.0))
        # apply on the top edge
        d = s - s0
        lift[top] = np.maximum(lift[top], need * smooth_bump(d, plat, wl, wr))
        # spill into neighbours along the chain
        for side in (0, 1):
            cur, cend, acc = top, (0 if side == 0 else 1), (s0 if side == 0 else s[-1] - s0)
            guard = 0
            while acc < plat + (wl if side == 0 else wr) and guard < 8:
                guard += 1
                node = g.edges[cur]["a"] if cend == 0 else g.edges[cur]["b"]
                lst = inc[node]
                if len(lst) != 2:
                    break
                nxt = lst[0] if lst[1] == (cur, cend) else lst[1]
                if nxt[0] == cur:
                    break
                ne, nend = nxt
                sn = arclen(g.edges[ne]["dense"])
                dist = acc + (sn if nend == 0 else sn[-1] - sn)  # distance from crossing
                sign = -1.0 if side == 0 else 1.0
                lift[ne] = np.maximum(lift[ne], need * smooth_bump(sign * dist, plat, wl, wr))
                acc += sn[-1]
                cur, cend = ne, 1 - nend
        n_lift += 1
    for ei, e in enumerate(g.edges):
        if lift[ei].max() > 0.0:
            e["lift"] = lift[ei]
    print("crossings %d, lifted %d" % (len(cr), n_lift))


# ------------------------------------------------------------------ main
def pick_spawn(g, sp_pos):
    """(dist, edge, i, dir): the ground motorway sample nearest sp_pos with 650 m of near-straight, level road ahead,
    preferring the direction that heads into the longer open motorway corridor."""
    pts = np.concatenate([e["dense"][:, [0, 2]] for e in g.edges])
    owner = np.concatenate([np.full(len(e["dense"]), ei) for ei, e in enumerate(g.edges)])
    tree = cKDTree(pts)
    ahead = int(650.0 / DENSE)
    best = (1e18, 0, 0, 1)
    for ei, e in enumerate(g.edges):
        dd = e["dense"]
        if e["type"] != "highway" or e["kind"] != "road" or len(dd) <= ahead + 2:
            continue
        # Check both +1 and -1 directions along the motorway edge; prefer the longer side ahead
        for d_sgn in (-1, 1):
            lo_k = 0 if d_sgn > 0 else ahead
            hi_k = len(dd) - ahead - 1 if d_sgn > 0 else len(dd)
            for k in range(lo_k, hi_k, 3):
                dist = math.hypot(dd[k, 0] - sp_pos[0], dd[k, 2] - sp_pos[2])
                # Slight bonus for having >= 1500 m of runway ahead on the edge
                runway = (len(dd) - 1 - k) * DENSE if d_sgn > 0 else k * DENSE
                score = dist - min(runway, 2500.0) * 0.25
                if score >= best[0] or dist > 6000.0:
                    continue
                seg = dd[k:k + ahead + 1] if d_sgn > 0 else dd[k - ahead:k + 1][::-1]
                hd = np.unwrap(np.arctan2(np.diff(seg[:, 2]), np.diff(seg[:, 0])))
                if np.ptp(hd) > 0.06 or np.ptp(seg[:, 1]) > 12.0:
                    continue
                near = tree.query_ball_point(seg[:, [0, 2]], 0.5 * e["width"] + 9.0)
                if any(owner[j] != ei for lst in near for j in lst):
                    continue
                best = (score, ei, k, d_sgn)
    if best[0] < 1e17:
        return best
    for ei, e in enumerate(g.edges):
        dd = e["dense"]
        dist = np.hypot(dd[:, 0] - sp_pos[0], dd[:, 2] - sp_pos[2])
        k = int(np.argmin(dist))
        if dist[k] < best[0]:
            best = (dist[k], ei, k, 1)
    return best


def main():
    country = load("country.json")
    regions = [load("regions/%s.json" % r["id"]) for r in country["regions"]]
    hf = Heightfield(country["terrain"]["heightfield"])
    g = build_clean_network(Graph, country, regions, hf)
    for e in g.edges:
        e["orig_kind"] = e["kind"]
        e["dense"] = densify(e["ctrl"])
    print("edges %d nodes %d" % (len(g.edges), len(g.nodes)))

    # 1. terrain conformed to ground roads
    base, T = conform_terrain(hf, g)

    # sea / water polygons
    sea_polys = [s["polygon"] for s in country["terrain"]["sea_polygons"]]
    sea = poly_mask(sea_polys)
    sea = np.maximum(sea, (base < -0.5).astype(float))
    sea_s = gaussian_filter(sea, 1.2)
    T = np.where(sea_s > 0.5, np.minimum(T, -2.5 - 3.0 * (sea_s - 0.5)), T)
    waters = []
    for r in regions:
        for w in r["terrain"]["water_polygons"]:
            poly = w["polygon"]
            if len(poly) < 4:
                continue
            xs = np.array([p[0] for p in poly])
            zs = np.array([p[1] for p in poly])
            if xs.max() - xs.min() < 6 and zs.max() - zs.min() < 6:
                continue
            hb = sample_grid(T, xs, zs)
            y = float(np.percentile(hb, 12)) - 0.4
            if y < 0.0:
                y = 0.0
            waters.append({"name": w.get("name", "Water"), "y": round(y, 2), "poly": [[round(p[0], 1), round(p[1], 1)] for p in poly[:-1]] if poly[0] == poly[-1] else [[round(p[0], 1), round(p[1], 1)] for p in poly]})
    for w in waters:
        m = poly_mask([w["poly"]])
        T = np.where(m > 0.5, np.minimum(T, w["y"] - 2.2), T)

    # 2. motorway profiles over the conformed terrain
    node_y = {}
    for ni, nd in enumerate(g.nodes):
        node_y[ni] = nd["p"][1]
    mot = [e for e in g.edges if e["motorway"]]
    # order motorway edges into their route chains by src name prefix
    by_m = collections.defaultdict(list)
    for e in mot:
        by_m[e["src"].split("_")[0]].append(e)
    mfixed = {}
    for ni, nd in enumerate(g.nodes):
        if str(nd["id"]).startswith(("tk_junc_ic", "mc_junc_ic", "db_junc_ic")) or str(nd["id"]) in ("M1_WEST", "M1_MC", "M1_TKO", "M2_DBM", "M2_DES"):
            mfixed[ni] = nd["p"][1]
    for mid, lst in by_m.items():
        lst.sort(key=lambda e: int(e["src"].split("_")[1]))
        # concatenate dense paths
        full = [lst[0]["dense"]]
        cuts = [0]
        for e in lst[1:]:
            full.append(e["dense"][1:])
        full = np.concatenate(full)
        cuts = [0]
        acc = 0
        for e in lst:
            acc += len(e["dense"]) - (0 if e is lst[0] else 1)
            cuts.append(acc - 1)
        anchors = []
        node_of = [lst[0]["a"]] + [e["b"] for e in lst]
        for ci, ni in zip(cuts, node_of):
            if ni in mfixed:
                anchors.append((ci, mfixed[ni]))
        y = profile_motorway(T, full[:, [0, 2]], anchors, DENSE, 0.05)
        gr = np.abs(np.diff(y)) / np.hypot(np.diff(full[:, 0]), np.diff(full[:, 2]))
        print("motorway %s: %.1f km, max grade %.3f, y %.0f..%.0f, %d anchors" % (mid, arclen(full)[-1] / 1000.0, gr.max(), y.min(), y.max(), len(anchors)))
        bad = np.where(gr > 0.05)[0]
        if len(bad):
            print('   steep (>5%%) samples: %d, first at world %s, idx %s' % (len(bad), full[bad[0]][[0,2]].round(), bad[:12]))
        pos = 0
        for e, c0, c1 in zip(lst, cuts[:-1], cuts[1:]):
            seg = full[c0:c1 + 1].copy()
            seg[:, 1] = y[c0:c1 + 1]
            e["dense"] = seg
            e["ctrl"] = seg
        # node heights follow the profile (interchange nodes pinned above)
        for ci, ni in zip(cuts, node_of):
            g.nodes[ni]["p"][1] = float(y[ci])
    # smoothly blend non-motorway edges whose endpoints touch a re-profiled motorway node (grade-limited!)
    for e in g.edges:
        if e["motorway"]:
            continue
        d = e["dense"]
        s = arclen(d)
        for end_i, ni in ((0, e["a"]), (1, e["b"])):
            dy = g.nodes[ni]["p"][1] - d[0 if end_i == 0 else -1, 1]
            if abs(dy) > 0.02:
                dist = s if end_i == 0 else (s[-1] - s)
                span = min(s[-1], max(240.0, abs(dy) / 0.045))
                w = 1.0 - smoothstep(0.0, max(span, 20.0), dist)
                d[:, 1] += dy * w
                # if dy is large relative to length, enforce gentle grade along the whole edge
                if abs(dy) > 15.0:
                    d[:, 1] = lipschitz(d[:, 1], 0.11 * DENSE)
                    d[0, 1] = g.nodes[e["a"]]["p"][1] if end_i == 0 else d[0, 1]
                    d[-1, 1] = g.nodes[e["b"]]["p"][1] if end_i == 1 else d[-1, 1]
    # edges meeting at region nodes keep their y; motorway edges now start at those y's.

    # 3. crossings -> lifts
    resolve_crossings(g)
    for e in g.edges:
        if "lift" in e:
            e["dense"] = e["dense"].copy()
            e["dense"][:, 1] += e["lift"]

    # 4. classify bridges / tunnels, split edges
    new_edges = []
    n_split = 0
    for e in g.edges:
        d = e["dense"]
        clr = d[:, 1] - sample_grid(T, d[:, 0], d[:, 2])
        cand = e["orig_kind"] in ("overpass", "bridge") or e["motorway"] or ("lift" in e)
        if not cand and e["orig_kind"] != "tunnel":
            e["kind"] = "road"
            new_edges.append(e)
            continue
        if e["orig_kind"] == "tunnel" and not cand:
            cover = sample_grid(T, d[:, 0], d[:, 2]) - d[:, 1]
            kinds = np.where(cover > 6.8, 2, 0)  # 2 = tunnel
        else:
            kinds = np.where(clr > 3.0, 1, 0)  # 1 = elevated
            # extend elevated runs down to 1.5 m clearance
            for i in range(1, len(kinds)):
                if kinds[i] == 0 and kinds[i - 1] == 1 and clr[i] > 1.5:
                    kinds[i] = 1
            for i in range(len(kinds) - 2, -1, -1):
                if kinds[i] == 0 and kinds[i + 1] == 1 and clr[i] > 1.5:
                    kinds[i] = 1
            if e["motorway"]:
                cover = sample_grid(T, d[:, 0], d[:, 2]) - d[:, 1]
                kinds = np.where(cover > 12.0, 2, kinds)
        # runs
        runs = []
        i = 0
        while i < len(kinds):
            j = i
            while j + 1 < len(kinds) and kinds[j + 1] == kinds[i]:
                j += 1
            runs.append([i, j, int(kinds[i])])
            i = j + 1
        # merge tiny elevated/tunnel runs into ground; merge tiny ground runs between two equal runs
        def run_len(r):
            return (r[1] - r[0]) * DENSE
        for r in runs:
            if r[2] != 0 and run_len(r) < (35.0 if r[2] == 1 else 80.0):
                r[2] = 0
        merged = []
        for r in runs:
            if merged and merged[-1][2] == r[2]:
                merged[-1][1] = r[1]
            else:
                merged.append(r)
        # runs under 4 samples (30 m) are absorbed into a neighbour so no sliver edges appear
        changed = True
        while changed and len(merged) > 1:
            changed = False
            for ri, r in enumerate(merged):
                if r[1] - r[0] < 3:
                    nb = merged[ri - 1] if ri > 0 else merged[ri + 1]
                    nb[0] = min(nb[0], r[0])
                    nb[1] = max(nb[1], r[1])
                    merged.pop(ri)
                    k = 0
                    while k + 1 < len(merged):
                        if merged[k][2] == merged[k + 1][2]:
                            merged[k][1] = merged[k + 1][1]
                            merged.pop(k + 1)
                        else:
                            k += 1
                    changed = True
                    break
        if len(merged) == 1:
            k = merged[0][2]
            e["kind"] = ["road", "overpass", "tunnel"][k]
            if k == 1:
                e["kind"] = "bridge" if float(np.mean(clr)) > 9.0 else "overpass"
            new_edges.append(e)
            continue
        # split at run boundaries: piece k spans [previous run end, this run end], sharing the boundary sample
        prev_node = e["a"]
        start = 0
        for ri, (r0, r1, k) in enumerate(merged):
            last = ri == len(merged) - 1
            piece = d[start:r1 + 1].copy()
            if last:
                nb = e["b"]
            else:
                nb = g.new_node(d[r1], "normal")
            ne = dict(e)
            ne["dense"] = piece
            ne["a"] = prev_node
            ne["b"] = nb
            ne["src"] = e["src"] if ri == 0 else "%s#%d" % (e["src"], ri)
            if k == 1:
                ne["kind"] = "bridge" if float(np.mean(clr[start:r1 + 1])) > 9.0 else "overpass"
            elif k == 2:
                ne["kind"] = "tunnel"
            else:
                ne["kind"] = "road"
            ne.pop("lift", None)
            new_edges.append(ne)
            prev_node = nb
            start = r1
            n_split += 1
    g.edges = new_edges
    # node heights: take the first edge end that touches them (all edges already agree except region nodes untouched by lift)
    for ei, e in enumerate(g.edges):
        g.nodes[e["a"]]["p"][1] = float(e["dense"][0][1])
        g.nodes[e["b"]]["p"][1] = float(e["dense"][-1][1])
        # make the polyline ends exact node positions
        e["dense"][0][[0, 2]] = [g.nodes[e["a"]]["p"][0], g.nodes[e["a"]]["p"][2]]
        e["dense"][-1][[0, 2]] = [g.nodes[e["b"]]["p"][0], g.nodes[e["b"]]["p"][2]]
    kc = collections.Counter(e["kind"] for e in g.edges)
    print("edges after classification:", dict(kc), "pieces", n_split)

    # spawn
    spawn = None
    ds = country["default_spawn"]
    for r in regions:
        for sp in r["spawns"]:
            if sp["id"] == ds["spawn_id"]:
                spawn = sp
    sp_pos = np.array(spawn["position"])
    best = pick_spawn(g, sp_pos)

    # 5. weights
    h = T
    cb_polys = []
    forest_polys = []
    sand_polys = []
    park_polys = []
    for r in regions:
        for b in r["city_blocks"]:
            cb_polys.append(b["polygon"])
        for z in r["terrain"]["landuse_zones"]:
            (forest_polys if z["kind"] == "forest" else (sand_polys if z["kind"] == "sand" else park_polys)).append(z["polygon"])
    urban = poly_mask(cb_polys)
    urban = gaussian_filter(urban, 2.6)
    w_city = np.clip(urban * 2.2, 0, 1)
    # road density also reads as urban
    dens = np.zeros((N, N))
    for e in g.edges:
        if e["type"] in ("city", "arterial"):
            d = e["dense"]
            ix = np.clip(((d[:, 0] - X0) / LAT).astype(int), 0, N - 1)
            iz = np.clip(((d[:, 2] - X0) / LAT).astype(int), 0, N - 1)
            np.add.at(dens, (iz, ix), 1.0)
    dens = gaussian_filter(dens, 3.0)
    w_city = np.clip(np.maximum(w_city, smoothstep(0.35, 1.1, dens) * 0.85), 0, 1)
    w_city = np.where(sea_s > 0.5, 0.0, w_city)
    # desert: dubai region
    db = [r for r in regions if r["region_id"] == "dubai_jais"][0]["bounds_m"]
    dmask = poly_mask([[[db["min"][0], db["min"][1]], [db["max"][0], db["min"][1]], [db["max"][0], db["max"][1]], [db["min"][0], db["max"][1]]]])
    dmask = gaussian_filter(dmask, 4.0)
    w_desert = np.clip(np.maximum(dmask * 1.1, poly_mask(sand_polys) * 0.9), 0, 1) * (1 - w_city)
    w_desert = np.where(sea_s > 0.5, 0.0, w_desert)
    forest_poly = gaussian_filter(poly_mask(forest_polys), 1.0)
    veg = smoothstep(25.0, 120.0, h) * (1.0 - smoothstep(1000.0, 1400.0, h))
    w_forest = np.clip(np.maximum(forest_poly * 1.3, veg * 0.55 * (1 - dmask)), 0, 1) * (1 - w_city) * (1 - w_desert)
    w_mount = smoothstep(250.0, 650.0, h) * (1 - w_desert) * (1 - w_city)
    w_hills = smoothstep(60.0, 260.0, h) * (1 - w_mount) * (1 - w_desert) * (1 - w_city)
    near_sea = gaussian_filter(sea_s, 7.0)
    w_coast = np.clip(near_sea * 3.0, 0, 1) * (1 - smoothstep(6.0, 40.0, h)) * (1 - w_city) * (1 - w_desert)
    planes = [w_city, w_forest, w_desert, w_mount, w_hills, w_coast]
    S = sum(planes)
    sc = np.where(S > 1.0, 1.0 / np.maximum(S, 1e-6), 1.0)
    planes = [np.clip(p * sc, 0, 1) for p in planes]

    # urban streets keep kerbs and sidewalks ("city"); the same OSM class outside the built-up area is a plain country road
    for e in g.edges:
        if e["type"] in ("arterial", "city"):
            d = e["dense"]
            e["type"] = "city" if float(sample_grid(planes[0], d[::3, 0], d[::3, 2]).mean()) > 0.3 else "country"
    print("edge types:", dict(collections.Counter(e["type"] for e in g.edges)))

    # 6. buildings
    bld = collections.defaultdict(list)
    n_b = 0
    for r in regions:
        for b in r["city_blocks"]:
            tags = b.get("style_tags", [])
            st = 1
            if any(t in tags for t in ("glass_highrise", "supertall_glass", "curtain_wall_tower")):
                st = 0
            elif any(t in tags for t in ("belle_epoque", "mediterranean_pastel", "harbour_terrace")):
                st = 2
            elif any(t in tags for t in ("neon_commercial",)):
                st = 3
            for f in b["footprints"]:
                poly = f["poly"][:-1] if f["poly"][0] == f["poly"][-1] else f["poly"]
                if len(poly) < 3:
                    continue
                a = 0.0
                for i in range(len(poly)):
                    x1, z1 = poly[i]
                    x2, z2 = poly[(i + 1) % len(poly)]
                    a += x1 * z2 - x2 * z1
                if abs(a) < 8.0:
                    continue
                if a < 0:
                    poly = poly[::-1]
                cx = sum(p[0] for p in poly) / len(poly)
                cz = sum(p[1] for p in poly) / len(poly)
                key = "%d,%d" % (math.floor(cx / TILE), math.floor(cz / TILE))
                hgt = float(f["height_m"])
                flat = []
                for p in poly:
                    flat += [round(p[0], 1), round(p[1], 1)]
                bld[key].append([round(hgt, 1), st, flat])
                n_b += 1
    print("buildings", n_b, "tiles", len(bld))

    # 7. meta
    meta = {"n": N, "lattice": LAT, "origin": X0, "regions": [], "spawns": [], "petrol": [], "landmarks": [], "water": waters,
            "sea": [[[round(p[0], 1), round(p[1], 1)] for p in poly] for poly in sea_polys], "labels": []}
    for r in regions:
        meta["regions"].append({"id": r["region_id"], "name": r["display_name"], "bounds": [r["bounds_m"]["min"][0], r["bounds_m"]["min"][1], r["bounds_m"]["max"][0], r["bounds_m"]["max"][1]]})
        for sb in r["source_bboxes"]:
            ox = sb["world_offset_xz"]
            nm, major = LABELS.get(sb["area_id"], (sb["area_id"].replace("_", " ").upper(), False))
            if any(l["pos"] == [ox[0], ox[1]] for l in meta["labels"]):
                continue  # bboxes stitched at one offset share a spot: one label there, not stacked text
            meta["labels"].append({"name": nm, "pos": [ox[0], ox[1]], "region": r["region_id"], "major": major})
        for sp in r["spawns"]:
            meta["spawns"].append({"id": sp["id"], "region": r["region_id"], "pos": sp["position"], "yaw": sp.get("yaw_deg", 0.0)})
        for p in r["petrol_stations"]:
            meta["petrol"].append({"name": p["name"], "pos": p["position"], "yaw": p.get("yaw_deg", 0.0), "region": r["region_id"]})
        for l in r["landmarks"]:
            meta["landmarks"].append({"name": l["name"], "cat": l["category"], "pos": l["position"], "region": r["region_id"]})
    spawn_s = float(arclen(g.edges[best[1]]["dense"])[best[2]])
    meta["default_spawn"] = {"edge": best[1], "s": spawn_s, "id": ds["spawn_id"], "region": ds["region"], "yaw": spawn.get("yaw_deg", 0.0)}
    meta["attribution"] = country["attribution"]

    # 8. write
    os.makedirs(OUT, exist_ok=True)
    nodes_out = [{"p": [round(n["p"][0], 2), round(n["p"][1], 2), round(n["p"][2], 2)], "kind": n["kind"], "radius": round(float(n.get("radius", 0.0)), 1)} for n in g.nodes]
    edges_out = []
    for e in g.edges:
        d = e["dense"]
        edges_out.append({"a": e["a"], "b": e["b"], "type": e["type"], "kind": e["kind"], "elevated": e["kind"] in ("bridge", "overpass"), "width": e["width"],
                          "name": e.get("name", ""), "dense": True, "pts": [[round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2)] for p in d]})
    with open(os.path.join(OUT, "network.json"), "w") as f:
        json.dump({"nodes": nodes_out, "edges": edges_out, "spawn": {"edge": best[1], "s": spawn_s, "dir": best[3]}}, f, separators=(",", ":"))
    T.astype("<f4").tofile(os.path.join(OUT, "terrain.bin"))
    np.stack([np.clip(np.round(p * 255), 0, 255).astype(np.uint8) for p in planes]).tofile(os.path.join(OUT, "weights.bin"))
    with open(os.path.join(OUT, "buildings.json"), "w") as f:
        json.dump(bld, f, separators=(",", ":"))
    with open(os.path.join(OUT, "meta.json"), "w") as f:
        json.dump(meta, f, separators=(",", ":"))
    km = sum(float(arclen(e["dense"])[-1]) for e in g.edges) / 1000.0
    print("wrote %s  (%.1f km of road, %d edges, %d nodes)" % (OUT, km, len(g.edges), len(g.nodes)))


if __name__ == "__main__":
    main()
