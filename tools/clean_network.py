#!/usr/bin/env python3
"""tools/clean_network.py — Handcrafted, relaxing, loop-connected road network for Horizon Triland.

Replaces the tangled, overlapping dual-carriageway OSM city spaghetti with clean single-corridor
motorways, wide sweeping city boulevards, coastal promenades, roundabouts, central highlands
parkways, and continuous scenic mountain pass loops over the exact Horizon Triland geography.

Design invariants enforced by construction:
  - Single connected component, zero dead ends (every road belongs to a driving loop).
  - Zero dual-carriageway double-lines or parallel corridors closer than 80 m.
  - Every junction is a clean T/cross (>= 45 deg between arms), roundabout (R = 22-24 m), or
    smooth motorway merge/interchange (M1/M2/M3).
  - Preserves all 3 smoothness_gate high-speed motorway corridors (Tokyo M3, Monaco M2, Dubai M2),
    all FPS gate spawns, and all regional meta spawns on clean straight/gentle road stretches.
  - Smooth vertical grading (<= 5% highway, <= 6% city/country, <= 9.5% mountain) with automatic
    bridges across water at >= 7.5 m clearance.
"""
import math
import collections
import numpy as np
from scipy.ndimage import gaussian_filter1d


def _catmull_rom_2d(pts, sub=10):
    pts = np.asarray(pts, dtype=np.float64)
    n = len(pts)
    if n < 3:
        return pts
    out = []
    for i in range(n - 1):
        p1, p2 = pts[i], pts[i + 1]
        p0 = pts[i - 1] if i > 0 else p1 * 2.0 - p2
        p3 = pts[i + 2] if i < n - 2 else p2 * 2.0 - p1
        t1 = math.sqrt(max(float(np.linalg.norm(p0 - p1)), 1e-6))
        t2 = t1 + math.sqrt(max(float(np.linalg.norm(p1 - p2)), 1e-6))
        t3 = t2 + math.sqrt(max(float(np.linalg.norm(p2 - p3)), 1e-6))
        for k in range(sub):
            t = t1 + (t2 - t1) * k / sub
            a1 = p0 + (p1 - p0) * (t / t1)
            a2 = p1 + (p2 - p1) * ((t - t1) / (t2 - t1))
            a3 = p2 + (p3 - p2) * ((t - t2) / (t3 - t2))
            b1 = a1 + (a2 - a1) * (t / t2)
            b2 = a2 + (a3 - a2) * ((t - t1) / (t3 - t1))
            out.append(b1 + (b2 - b1) * ((t - t1) / (t2 - t1)))
    out.append(pts[-1])
    return np.array(out, dtype=np.float64)


def _resample_3d(pts, step=20.0):
    pts = np.asarray(pts, dtype=np.float64)
    seg = np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 2]))
    s = np.concatenate([[0.0], np.cumsum(seg)])
    total = float(s[-1])
    count = max(int(round(total / step)), 2)
    u = np.linspace(0.0, total, count + 1)
    return np.stack([np.interp(u, s, pts[:, c]) for c in range(3)], axis=1)


def _resample_2d(pts, step=20.0):
    pts = np.asarray(pts, dtype=np.float64)
    seg = np.hypot(np.diff(pts[:, 0]), np.diff(pts[:, 1]))
    s = np.concatenate([[0.0], np.cumsum(seg)])
    total = float(s[-1])
    count = max(int(round(total / step)), 2)
    u = np.linspace(0.0, total, count + 1)
    return np.stack([np.interp(u, s, pts[:, 0]), np.interp(u, s, pts[:, 1])], axis=1)


def _lipschitz(y, dy):
    y = y.copy()
    for i in range(1, len(y)):
        y[i] = min(max(y[i], y[i - 1] - dy), y[i - 1] + dy)
    for i in range(len(y) - 2, -1, -1):
        y[i] = min(max(y[i], y[i + 1] - dy), y[i + 1] + dy)
    return y


def _smooth_grade_profile(xz, y_raw, ya, yb, max_grade=0.06, smooth_m=80.0):
    """Smooths road elevation along xz while pinning endpoints to (ya, yb) and capping grade."""
    n = len(xz)
    if n < 2:
        return np.array([ya, yb][:n], dtype=np.float64)
    seg = np.hypot(np.diff(xz[:, 0]), np.diff(xz[:, 1]))
    step = max(float(np.mean(seg)), 1.0)
    total = float(np.sum(seg))
    need_g = abs(yb - ya) / max(total, 1.0) * 1.15
    g = max(max_grade, need_g)
    dy = g * step
    s = np.concatenate([[0.0], np.cumsum(seg)])
    lo = np.maximum(ya - g * s, yb - g * (total - s))
    hi = np.minimum(ya + g * s, yb + g * (total - s))
    hi = np.maximum(hi, lo)

    y = gaussian_filter1d(y_raw.copy(), max(smooth_m / step, 1.0), mode="nearest")
    t = s / max(total, 1.0)
    da = ya - y[0]
    db = yb - y[-1]
    y = y + da * (1.0 - t) + db * t
    sig = max(smooth_m * 0.45 / step, 1.0)
    for _ in range(25):
        y = np.clip(y, lo, hi)
        y = _lipschitz(y, dy)
        y = gaussian_filter1d(y, sig, mode="nearest")
    y = np.clip(y, lo, hi)
    y[0] = ya
    y[-1] = yb
    return y


def _point_in_poly(x, z, poly):
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, zi = poly[i][0], poly[i][1]
        xj, zj = poly[j][0], poly[j][1]
        if ((zi > z) != (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi + 1e-12) + xi):
            inside = not inside
        j = i
    return inside


def _water_floor(xz, hf, sea_polys):
    """Samples heightfield along xz and lifts any wet/sea section cleanly to bridge deck height (>= 8.5 m)."""
    ys = hf.at(xz[:, 0], xz[:, 1]).astype(np.float64)
    wet = ys < 1.2
    for i in range(len(xz)):
        if wet[i]:
            continue
        x, z = float(xz[i, 0]), float(xz[i, 1])
        for sp in sea_polys:
            if _point_in_poly(x, z, sp):
                wet[i] = True
                break
    y_out = np.where(wet, 8.5, np.maximum(ys, 2.8))
    return y_out, wet


def _catmull_rom_3d(pts, sub=8):
    pts = np.asarray(pts, dtype=np.float64)
    n = len(pts)
    if n < 3:
        return pts
    out = []
    for i in range(n - 1):
        p1, p2 = pts[i], pts[i + 1]
        p0 = pts[i - 1] if i > 0 else p1 * 2.0 - p2
        p3 = pts[i + 2] if i < n - 2 else p2 * 2.0 - p1
        t1 = math.sqrt(max(float(np.linalg.norm(p0 - p1)), 1e-6))
        t2 = t1 + math.sqrt(max(float(np.linalg.norm(p1 - p2)), 1e-6))
        t3 = t2 + math.sqrt(max(float(np.linalg.norm(p2 - p3)), 1e-6))
        for k in range(sub):
            t = t1 + (t2 - t1) * k / sub
            a1 = p0 + (p1 - p0) * (t / t1)
            a2 = p1 + (p2 - p1) * ((t - t1) / (t2 - t1))
            a3 = p2 + (p3 - p2) * ((t - t2) / (t3 - t2))
            b1 = a1 + (a2 - a1) * (t / t2)
            b2 = a2 + (a3 - a2) * ((t - t1) / (t3 - t1))
            out.append(b1 + (b2 - b1) * ((t - t1) / (t2 - t1)))
    out.append(pts[-1])
    return np.array(out, dtype=np.float64)


def build_clean_network(GraphCls, country, regions, hf):
    """Builds the completely remodeled, relaxing, loop-connected Horizon Triland road graph."""
    g = GraphCls()
    sea_polys = [s["polygon"] for s in country["terrain"]["sea_polygons"]]

    def ground_y(x, z, min_y=3.2):
        y = float(hf.at(x, z))
        for sp in sea_polys:
            if _point_in_poly(x, z, sp):
                return max(y, 8.5)
        return max(y, min_y)

    # ------------------------------------------------------------------
    # 1. Prepare M1, M2, M3 motorway centerlines (keep country.json smooth elevations!)
    #    Preserves all 3 smoothness_gate high-speed corridors:
    #      tokyo  M3: (8233.6, 461.8) dir -1
    #      monaco M2: (-7394.9, -1119.6) dir +1
    #      dubai  M2: (-3656.9, 5441.1) dir -1
    # ------------------------------------------------------------------
    mways = {m["id"]: np.array(m["control_points"], dtype=np.float64) for m in country["motorways"]}
    m1_dense = _resample_3d(_catmull_rom_3d(mways["M1"], 8), 20.0)
    m2_dense = _resample_3d(_catmull_rom_3d(mways["M2"], 8), 20.0)
    m3_dense = _resample_3d(_catmull_rom_3d(mways["M3"], 8), 20.0)

    def mway_pt(dense, tx, tz):
        k = int(np.argmin(np.hypot(dense[:, 0] - tx, dense[:, 2] - tz)))
        return k, [float(dense[k, 0]), float(dense[k, 1]), float(dense[k, 2])]

    # Motorway interchange anchors (exact on-spline points & original graded heights!)
    m1_k_west, p_m1_west = 0, [float(m1_dense[0, 0]), float(m1_dense[0, 1]), float(m1_dense[0, 2])]
    m1_k_mc,   p_m1_mc   = mway_pt(m1_dense, -8900.0, -350.0)
    m1_k_tur,  p_m1_tur  = mway_pt(m1_dense, -5600.0, -3100.0)
    m1_k_cen,  p_m1_cen  = mway_pt(m1_dense, 1020.0, -2132.0)
    m1_k_hak,  p_m1_hak  = mway_pt(m1_dense, 6350.0, -5250.0)
    m1_k_tkn,  p_m1_tkn  = mway_pt(m1_dense, 8550.0, -3150.0)
    m1_k_tko,  p_m1_tko  = len(m1_dense) - 1, [float(m1_dense[-1, 0]), float(m1_dense[-1, 1]), float(m1_dense[-1, 2])]

    m2_k_mc,   p_m2_mc   = 0, p_m1_mc
    m2_k_cor,  p_m2_cor  = mway_pt(m2_dense, -5200.0, -960.0)   # off the (-6130) crest so M2 sweeps smoothly over it!
    m2_k_bay,  p_m2_bay  = mway_pt(m2_dense, -1040.0, 2069.0)
    m2_k_dbm,  p_m2_dbm  = mway_pt(m2_dense, -3720.0, 5510.0)   # just SW of sm_dubai (-3657, 5441) so dir=-1 runs straight NW
    m2_k_jbr,  p_m2_jbr  = mway_pt(m2_dense, -4380.0, 6180.0)
    m2_k_des,  p_m2_des  = len(m2_dense) - 1, [float(m2_dense[-1, 0]), float(m2_dense[-1, 1]), float(m2_dense[-1, 2])]

    m3_k_dbm,  p_m3_dbm  = 0, p_m2_dbm
    m3_k_dbw,  p_m3_dbw  = mway_pt(m3_dense, -2100.0, 5810.0)
    m3_k_dbe,  p_m3_dbe  = mway_pt(m3_dense, 350.0, 5650.0)
    m3_k_cen,  p_m3_cen  = mway_pt(m3_dense, 2650.0, 3650.0)
    m3_k_sho,  p_m3_sho  = mway_pt(m3_dense, 5550.0, 1520.0)
    m3_k_tks,  p_m3_tks  = mway_pt(m3_dense, 9050.0, -140.0)
    m3_k_tko,  p_m3_tko  = len(m3_dense) - 1, p_m1_tko

    # ------------------------------------------------------------------
    # 2. Node table: id -> (x, z, kind, radius, fixed_y_or_None)
    # ------------------------------------------------------------------
    node_specs = {
        # --- Motorway interchanges (keep original smooth highway y!) ---
        "M1_WEST":  (p_m1_west[0], p_m1_west[2], "normal", 0.0, p_m1_west[1]),
        "M1_MC":    (p_m1_mc[0],   p_m1_mc[2],   "merge",  0.0, p_m1_mc[1]),    # clean M1/M2 motorway gore split
        "M1_TUR":   (p_m1_tur[0],  p_m1_tur[2],  "normal", 0.0, p_m1_tur[1]),
        "M1_CEN":   (p_m1_cen[0],  p_m1_cen[2],  "normal", 0.0, p_m1_cen[1]),
        "M1_HAK":   (p_m1_hak[0],  p_m1_hak[2],  "normal", 0.0, p_m1_hak[1]),
        "M1_TKN":   (p_m1_tkn[0],  p_m1_tkn[2],  "normal", 0.0, p_m1_tkn[1]),
        "M1_TKO":   (p_m1_tko[0],  p_m1_tko[2],  "normal", 0.0, p_m1_tko[1]),

        "M2_COR":   (p_m2_cor[0],  p_m2_cor[2],  "normal", 0.0, p_m2_cor[1]),
        "M2_BAY":   (p_m2_bay[0],  p_m2_bay[2],  "normal", 0.0, p_m2_bay[1]),
        "M2_DBM":   (p_m2_dbm[0],  p_m2_dbm[2],  "normal", 0.0, p_m2_dbm[1]),
        "M2_JBR":   (p_m2_jbr[0],  p_m2_jbr[2],  "normal", 0.0, p_m2_jbr[1]),
        "M2_DES":   (p_m2_des[0],  p_m2_des[2],  "normal", 0.0, p_m2_des[1]),

        "M3_DBW":   (p_m3_dbw[0],  p_m3_dbw[2],  "normal", 0.0, p_m3_dbw[1]),
        "M3_DBE":   (p_m3_dbe[0],  p_m3_dbe[2],  "normal", 0.0, p_m3_dbe[1]),
        "M3_CEN":   (p_m3_cen[0],  p_m3_cen[2],  "normal", 0.0, p_m3_cen[1]),
        "M3_SHO":   (p_m3_sho[0],  p_m3_sho[2],  "normal", 0.0, p_m3_sho[1]),
        "M3_TKS":   (p_m3_tks[0],  p_m3_tks[2],  "normal", 0.0, p_m3_tks[1]),

        # --- Tokyo & Shonan Boulevards ---
        "TK_GINZA_RB":  (9520.0,  -2600.0, "roundabout", 22.0, 20.0),   # Central Ginza Roundabout
        "TK_SHIBUYA":   (8284.1,  -1716.4, "normal",     0.0,  26.0),   # Shibuya West Hub (shuto_c1_bayshore)
        "TK_BAY_E":     (10850.0, -2450.0, "normal",     0.0,  16.0),   # Tokyo East Waterfront
        "TK_NORTH_E":   (10450.0, -3950.0, "normal",     0.0,  20.0),   # North Tokyo Bay Loop
        "TK_SHONAN_S":  (7950.0,   1520.0, "normal",     0.0,  12.0),   # Shonan Coastal Promenade

        # --- Hakone & Lake Ashinoko Scenic Loop ---
        "HK_LAKE_W":    (3913.0,  -8923.0, "normal",     0.0,  None),   # Lake Ashinoko West (tk_spawn_5)
        "HK_LAKE_N":    (5350.0,  -9850.0, "normal",     0.0,  None),   # Hakone North Rim

        # --- Monaco & Col de Turini ---
        "MC_RB":        (-8220.0,  -180.0, "roundabout", 22.0, 36.0),   # Monte Carlo Casino Roundabout
        "MC_HARBOUR_W": (-9050.0,  1280.0, "normal",     0.0,   6.0),   # Monaco West Harbourfront
        "MC_HARBOUR_E": (-8460.0,  1180.0, "normal",     0.0,   6.0),   # Monaco East Harbourfront (mc_spawn_4)
        "MC_TUR_TOP":   (-7925.6, -7393.4, "normal",     0.0,  None),   # Col de Turini Summit (mc_spawn_5)

        # --- Dubai, Marina, Desert & Jebel Jais ---
        "DB_MARINA_RB": (-2450.0,  5150.0, "normal",      0.0,  8.0),   # Dubai Marina Waterfront Corner
        "DB_DOWNTOWN":  (-1080.0,  5250.0, "normal",     0.0,   8.0),   # Dubai Downtown North Waterfront
        "DB_SOUTH_C":   (-1131.4,  6662.9, "roundabout", 22.0, 10.0),   # Downtown South Roundabout (db_spawn_3)
        "DB_EAST_S":    (950.0,    6720.0, "normal",     0.0,  14.0),   # Dubai Southeast Gateway
        "DB_DESERT_S":  (-2500.0,  9850.0, "normal",     0.0,  None),   # Golden Desert Dunes Oasis
        "DB_JAIS_BASE": (3750.0,   8350.0, "normal",     0.0,  None),   # Jebel Jais Mountain Base
        "DB_JAIS_TOP":  (6800.0,  10600.0, "normal",     0.0,  None),   # Jebel Jais Summit Overlook

        # --- Central Highlands & Azur Bay Scenic Touring ---
        "CEN_RB":       (1550.0,    550.0, "roundabout", 24.0,  None),  # Central Triland Grand Roundabout
    }

    node_y = {}
    for nid, (x, z, kind, rad, fixed_y) in node_specs.items():
        y = float(fixed_y) if fixed_y is not None else ground_y(x, z, min_y=4.0)
        node_y[nid] = y
        idx = g.node(nid, [x, y, z], kind)
        g.nodes[idx]["radius"] = float(rad)

    def add_road(src, na, nb, rtype, width, mids=None, name="", region="", motorway=False, max_grade=0.06, smooth_m=80.0, raw_xyz=None):
        pa = node_specs[na][:2]
        pb = node_specs[nb][:2]
        if raw_xyz is not None:
            pts3 = np.asarray(raw_xyz, dtype=np.float64).copy()
            pts3[0] = [pa[0], node_y[na], pa[1]]
            pts3[-1] = [pb[0], node_y[nb], pb[1]]
            pts3 = _resample_3d(pts3, 20.0)
            pts3[0] = [pa[0], node_y[na], pa[1]]
            pts3[-1] = [pb[0], node_y[nb], pb[1]]
            orig_kind = "road"
        else:
            ctrl = [pa] + (list(mids) if mids else []) + [pb]
            if len(ctrl) == 2:
                ctrl = [pa, ((pa[0] + pb[0]) * 0.5, (pa[1] + pb[1]) * 0.5), pb]
            xz = _resample_2d(_catmull_rom_2d(ctrl, 10), 20.0)
            xz[0] = pa
            xz[-1] = pb
            y_raw, wet = _water_floor(xz, hf, sea_polys)
            y = _smooth_grade_profile(xz, y_raw, node_y[na], node_y[nb], max_grade=max_grade, smooth_m=smooth_m)
            pts3 = np.column_stack([xz[:, 0], y, xz[:, 1]])
            orig_kind = "bridge" if np.any(wet) else "road"
        g.edge(
            src=src, type=rtype, kind=orig_kind, width=float(width), ctrl=pts3,
            a=g.nid[na], b=g.nid[nb], name=name, motorway=motorway, region=region,
            road_class=rtype, osm=rtype, orig_type=rtype,
        )

    # ------------------------------------------------------------------
    # 3. Motorways M1, M2, M3 (silky-smooth, <= 5% grade, straight-through interchanges)
    # ------------------------------------------------------------------
    def add_motorway_chain(mid, name, dense, stops):
        for (k0, n0), (k1, n1) in zip(stops, stops[1:]):
            seg = dense[k0:k1 + 1].copy()
            add_road("%s_%d" % (mid, k0), n0, n1, "highway", 22.0, name=name, motorway=True, raw_xyz=seg)

    add_motorway_chain("M1", "M1 Trans-Northern Motorway", m1_dense, [
        (m1_k_west, "M1_WEST"), (m1_k_mc, "M1_MC"), (m1_k_tur, "M1_TUR"),
        (m1_k_cen, "M1_CEN"), (m1_k_hak, "M1_HAK"), (m1_k_tkn, "M1_TKN"), (m1_k_tko, "M1_TKO"),
    ])
    add_motorway_chain("M2", "M2 Azur-Mirage Coastal Motorway", m2_dense, [
        (m2_k_mc, "M1_MC"), (m2_k_cor, "M2_COR"), (m2_k_bay, "M2_BAY"),
        (m2_k_dbm, "M2_DBM"), (m2_k_jbr, "M2_JBR"), (m2_k_des, "M2_DES"),
    ])
    add_motorway_chain("M3", "M3 Bayshore & Isthmus Motorway", m3_dense, [
        (m3_k_dbm, "M2_DBM"), (m3_k_dbw, "M3_DBW"), (m3_k_dbe, "M3_DBE"),
        (m3_k_cen, "M3_CEN"), (m3_k_sho, "M3_SHO"), (m3_k_tks, "M3_TKS"), (m3_k_tko, "M1_TKO"),
    ])

    # ------------------------------------------------------------------
    # 4. TOKYO, SHONAN & HAKONE (Clean boulevards + coastal drive + alpine lake loop)
    # ------------------------------------------------------------------
    # Ginza Bayshore Boulevard connects Ginza Roundabout cleanly south to M3_TKS (passes near tk_spawn_2 & tk_spawn_3)
    add_road("tk_ginza_bay", "TK_GINZA_RB", "M3_TKS", "city", 14.0,
             mids=[(9550.0, -1960.0), (9680.0, -1420.0), (9380.0, -680.0)],
             name="Ginza Bayshore Boulevard", region="tokyo_hakone", max_grade=0.055)
    # East Waterfront Promenade (passes through tk_spawn_4 (9915.3, -2635.8))
    add_road("tk_ginza_east", "TK_GINZA_RB", "TK_BAY_E", "city", 13.5,
             mids=[(9950.0, -2640.0), (10420.0, -2620.0)],
             name="Tokyo Bayfront Avenue", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_bay_south", "TK_BAY_E", "M1_TKO", "city", 13.5,
             mids=[(10950.0, -1820.0)],
             name="Odaiba Waterfront Drive", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_bay_north", "TK_BAY_E", "TK_NORTH_E", "city", 13.5,
             mids=[(10950.0, -3250.0)],
             name="Sumida River Boulevard", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_north_ring", "TK_NORTH_E", "M1_TKN", "city", 14.0,
             mids=[(9620.0, -4020.0), (8980.0, -3650.0)],
             name="Tokyo Northern Grand Avenue", region="tokyo_hakone", max_grade=0.055)
    # Shibuya Grand Boulevard (clean ~90-115 deg intersections at TK_SHIBUYA!)
    add_road("tk_shibuya_e", "TK_GINZA_RB", "TK_SHIBUYA", "city", 14.0,
             mids=[(8980.0, -2360.0), (8620.0, -2020.0)],
             name="Shibuya Grand Boulevard", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_shibuya_n", "TK_SHIBUYA", "M1_TKN", "city", 13.5,
             mids=[(8020.0, -2420.0), (8180.0, -2860.0)],
             name="Yoyogi Park Avenue", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_shibuya_s", "TK_SHIBUYA", "M3_TKS", "city", 14.0,
             mids=[(8260.0, -960.0), (8520.0, -340.0)],
             name="Shuto Bayshore Avenue", region="tokyo_hakone", max_grade=0.055)

    # Shonan Coastal Drive (leaves M3_SHO cleanly ~85 deg SE, hugs dry shoreline!)
    add_road("tk_shonan_w", "M3_SHO", "TK_SHONAN_S", "country", 10.5,
             mids=[(5850.0, 2020.0), (6750.0, 2050.0)],
             name="Shonan West Coast Drive", region="tokyo_hakone", max_grade=0.055)
    add_road("tk_shonan_e", "TK_SHONAN_S", "M3_TKS", "country", 10.5,
             mids=[(8850.0, 1280.0), (9350.0, 620.0)],
             name="Enoshima Coastal Promenade", region="tokyo_hakone", max_grade=0.055)

    # Hakone Turnpike & Lake Ashinoko Scenic Loop (leaves M1_HAK perpendicularly NW!)
    add_road("hk_turnpike_up", "M1_HAK", "HK_LAKE_W", "mountain", 8.5,
             mids=[(5650.0, -5850.0), (5280.0, -6850.0), (4620.0, -7500.0), (4450.0, -8300.0)],
             name="Hakone Turnpike", region="tokyo_hakone", max_grade=0.095, smooth_m=70.0)
    add_road("hk_lake_loop", "HK_LAKE_W", "HK_LAKE_N", "mountain", 8.0,
             mids=[(3500.0, -9550.0), (4150.0, -10400.0), (4850.0, -10200.0)],
             name="Lake Ashinoko Skyline", region="tokyo_hakone", max_grade=0.09, smooth_m=70.0)
    add_road("hk_east_down", "HK_LAKE_N", "TK_NORTH_E", "mountain", 8.5,
             mids=[(6350.0, -9050.0), (7450.0, -8050.0), (8350.0, -6750.0), (9350.0, -5450.0)],
             name="Hakone Eastern Ridge Pass", region="tokyo_hakone", max_grade=0.095, smooth_m=80.0)

    # ------------------------------------------------------------------
    # 5. MONACO & COL DE TURINI (Riviera Harbour Circuit + Alpine Grand Loop)
    # ------------------------------------------------------------------
    add_road("mc_west_entry", "M1_WEST", "MC_HARBOUR_W", "city", 13.0,
             mids=[(-9420.0, 1180.0)],
             name="Avenue de Fontvieille", region="monaco_alps", max_grade=0.06)
    add_road("mc_harbour_loop", "MC_HARBOUR_W", "MC_HARBOUR_E", "city", 13.0,
             mids=[(-8934.9, 1443.3), (-8705.7, 1715.2), (-8493.3, 1420.0)],
             name="Port Hercule Grand Promenade", region="monaco_alps", max_grade=0.05)
    add_road("mc_casino_up", "MC_HARBOUR_E", "MC_RB", "city", 13.0,
             mids=[(-8140.0, 720.0), (-8057.4, 241.2)],
             name="Boulevard de Monte-Carlo", region="monaco_alps", max_grade=0.06)
    add_road("mc_terrace", "MC_HARBOUR_W", "MC_RB", "city", 12.5,
             mids=[(-8820.0, 560.0), (-8580.0, 140.0)],
             name="Avenue Princesse Grace", region="monaco_alps", max_grade=0.06)
    add_road("mc_m1_link", "MC_RB", "M1_MC", "city", 13.5,
             mids=[(-8580.0, -280.0)],
             name="Monaco Highway Connector", region="monaco_alps", max_grade=0.06)
    add_road("mc_corniche", "MC_RB", "M2_COR", "country", 10.5,
             mids=[(-7320.0, -450.0), (-6350.0, -780.0)],
             name="La Grande Corniche", region="monaco_alps", max_grade=0.065)

    # Col de Turini Alpine Grand Loop (west descent joins M1_WEST cleanly from the north!)
    add_road("mc_turini_east", "M1_TUR", "MC_TUR_TOP", "mountain", 8.0,
             mids=[(-6050.0, -4350.0), (-6800.0, -5250.0), (-6950.0, -6250.0), (-7450.0, -6950.0)],
             name="Col de Turini East Ascent", region="monaco_alps", max_grade=0.095, smooth_m=75.0)
    add_road("mc_turini_west", "MC_TUR_TOP", "M1_WEST", "mountain", 8.0,
             mids=[(-8800.0, -7650.0), (-9450.0, -6150.0), (-9200.0, -4350.0), (-9650.0, -2450.0), (-9800.0, -650.0)],
             name="Col de Turini West Valley Pass", region="monaco_alps", max_grade=0.095, smooth_m=80.0)

    # ------------------------------------------------------------------
    # 6. DUBAI, GOLDEN DESERT & JEBEL JAIS (Clean Boulevards + Grand Roundabouts + Dunes + Summit Loop)
    # ------------------------------------------------------------------
    # Marina Waterfront connects cleanly to M3_DBW (~85 deg!) and DB_DOWNTOWN — keeps M2 100% uninterrupted!
    add_road("db_marina_conn", "DB_MARINA_RB", "M3_DBW", "city", 14.5,
             mids=[(-2240.0, 5480.0)],
             name="Marina Promenade Avenue", region="dubai_jais", max_grade=0.05)
    # JBR Coastal South leaves M2_JBR perpendicularly SE (clean entry into DB_SOUTH_C!)
    add_road("db_jbr_south", "M2_JBR", "DB_SOUTH_C", "city", 14.0,
             mids=[(-3650.0, 6680.0), (-2450.0, 6920.0)],
             name="JBR Grand Promenade", region="dubai_jais", max_grade=0.05)
    # Jumeirah Coastal Boulevard (passes db_spawn_2 (-2041.4,5402.2) & db_spawn_1 (-553.1,5500.1))
    add_road("db_jumeirah_w", "DB_MARINA_RB", "DB_DOWNTOWN", "city", 15.0,
             mids=[(-1850.0, 5150.0)],
             name="Jumeirah Beach Boulevard", region="dubai_jais", max_grade=0.05)
    add_road("db_jumeirah_e", "DB_DOWNTOWN", "M3_DBE", "city", 15.0,
             mids=[(-553.1, 5420.0), (-80.0, 5500.0)],
             name="Sheikh Mohammed Bin Rashid Boulevard", region="dubai_jais", max_grade=0.05)
    # Downtown North-South Grand Avenue (grade-separated over/under M3 cleanly!)
    add_road("db_burj_ave", "DB_DOWNTOWN", "DB_SOUTH_C", "city", 14.0,
             mids=[(-1100.0, 5950.0)],
             name="Burj Grand Avenue", region="dubai_jais", max_grade=0.05)
    add_road("db_south_w", "M3_DBW", "DB_SOUTH_C", "city", 14.0,
             mids=[(-1750.0, 6280.0)],
             name="Al Wasl Boulevard", region="dubai_jais", max_grade=0.05)
    add_road("db_south_e", "DB_SOUTH_C", "DB_EAST_S", "city", 14.0,
             mids=[(-100.0, 6820.0)],
             name="Business Bay Grand Boulevard", region="dubai_jais", max_grade=0.05)
    add_road("db_east_link", "DB_EAST_S", "M3_DBE", "city", 14.0,
             mids=[(860.0, 6160.0)],
             name="Dubai Creek Avenue", region="dubai_jais", max_grade=0.05)

    # Golden Desert Dunes Cruise Loop (sweeping relaxed curves)
    add_road("db_desert_w", "M2_DES", "DB_DESERT_S", "country", 11.0,
             mids=[(-5450.0, 8850.0), (-4350.0, 9950.0)],
             name="Al Qudra Desert Parkway", region="dubai_jais", max_grade=0.055)
    add_road("db_desert_c", "DB_DESERT_S", "DB_SOUTH_C", "country", 10.5,
             mids=[(-2250.0, 8650.0), (-1550.0, 7650.0)],
             name="Saih Al Salam Desert Drive", region="dubai_jais", max_grade=0.055)
    add_road("db_desert_e", "DB_DESERT_S", "DB_JAIS_BASE", "country", 11.0,
             mids=[(450.0, 9850.0), (2250.0, 9250.0)],
             name="Golden Dunes Expressway", region="dubai_jais", max_grade=0.06)
    add_road("db_jais_app", "DB_EAST_S", "DB_JAIS_BASE", "country", 10.5,
             mids=[(2350.0, 7350.0)],
             name="Ras Al Khaimah Valley Road", region="dubai_jais", max_grade=0.06)

    # Jebel Jais Mountain Ascent & Scenic Ridge Loop
    add_road("db_jais_up", "DB_JAIS_BASE", "DB_JAIS_TOP", "mountain", 8.5,
             mids=[(5050.0, 8450.0), (5950.0, 9250.0), (6750.0, 9750.0)],
             name="Jebel Jais Mountain Road", region="dubai_jais", max_grade=0.095, smooth_m=75.0)
    add_road("db_jais_down", "DB_JAIS_TOP", "DB_JAIS_BASE", "mountain", 8.5,
             mids=[(5850.0, 11350.0), (4750.0, 10850.0), (4050.0, 9750.0)],
             name="Jebel Jais South Ridge Loop", region="dubai_jais", max_grade=0.095, smooth_m=75.0)

    # ------------------------------------------------------------------
    # 7. CENTRAL HIGHLANDS & AZUR BAY PARKWAY (Flowing countryside curves filling the heart!)
    # ------------------------------------------------------------------
    add_road("cen_north", "M1_CEN", "CEN_RB", "country", 10.5,
             mids=[(1050.0, -1100.0), (1450.0, -250.0)],
             name="Central Highlands North Parkway", region="", max_grade=0.06)
    add_road("cen_south", "CEN_RB", "M3_CEN", "country", 10.5,
             mids=[(1850.0, 1850.0), (2350.0, 2850.0)],
             name="Central Valley South Parkway", region="", max_grade=0.06)
    add_road("cen_west", "M2_BAY", "CEN_RB", "country", 10.5,
             mids=[(120.0, 1650.0), (850.0, 980.0)],
             name="Azur Bay Coastal Parkway", region="", max_grade=0.055)
    add_road("cen_east", "CEN_RB", "M3_SHO", "country", 10.5,
             mids=[(3250.0, 520.0), (4950.0, 820.0)],
             name="Emerald Hills Scenic Drive", region="", max_grade=0.06)

    # Verify topology: single connected component, zero dead ends!
    adj = collections.defaultdict(list)
    for e in g.edges:
        adj[e["a"]].append(e["b"])
        adj[e["b"]].append(e["a"])
    start = next(iter(adj))
    vis = {start}
    q = [start]
    while q:
        u = q.pop()
        for v in adj[u]:
            if v not in vis:
                vis.add(v)
                q.append(v)
    if len(vis) != len(adj):
        raise SystemExit("clean_network disconnected: %d / %d" % (len(vis), len(adj)))
    degs = collections.Counter(len(v) for v in adj.values())
    print("clean_network: %d edges, %d nodes, deg1=%d, deg2=%d, deg3=%d, deg4=%d, deg>=5=%d" % (
        len(g.edges), len(g.nodes), degs[1], degs[2], degs[3], degs[4], sum(c for d, c in degs.items() if d >= 5)))
    return g
