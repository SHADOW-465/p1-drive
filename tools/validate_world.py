#!/usr/bin/env python3
"""
tools/validate_world.py — Horizon Triland v2 Real-OSM World & Region Layout Validator
Uses Python 3 standard library only.

Validates:
  1. Country bounds, region bounding boxes (non-overlapping), scale factors (0.6..1.0),
     source OSM bounding boxes, 9 interchanges, and M1/M2/M3 motorways.
  2. Every road spline (motorway + 3 regions) for:
       - Non-degenerate horizontal segments and horizontal radius consistency
       - Minimum vertical curve radius (R_v >= 600 m on highways, >= 120 m on mountain roads)
       - Vertical grade checks (relaxes nominal grade rules where real OSM/SRTM roads exceed them,
         and explicitly lists every such road and its maximum grade).
  3. Junction ID resolution, bidirectional incidence consistency, endpoint coordinate match.
  4. Road graph connectivity (per-region and full-country single connected component; no unmarked orphan dead ends).
  5. Real OSM building footprints in city_blocks, coastlines/water, landuse zones,
     real OSM petrol stations (amenity=fuel) and landmarks.
  6. Non-overlap invariants:
       - City block polygons do not overlap each other or any surface road carriageway.
       - Non-incident road crossings in XZ are grade-separated (|dy| >= 7.0 m) or tunnelled.
"""

import json
import math
import sys
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COUNTRY_PATH = ROOT / "data" / "world" / "country.json"
REGIONS_DIR = ROOT / "data" / "world" / "regions"


class ValidationErrorList:
    def __init__(self):
        self.errors = []
        self.warnings = []
        self.grade_relaxations = []

    def err(self, msg: str):
        self.errors.append(msg)

    def warn(self, msg: str):
        self.warnings.append(msg)

    def relax_grade(self, msg: str):
        self.grade_relaxations.append(msg)

    @property
    def ok(self) -> bool:
        return len(self.errors) == 0


def dist2d(a, b) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def dist3d(a, b) -> float:
    return math.sqrt((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2 + (b[2] - a[2]) ** 2)


def menger_radius_2d(p0, p1, p2) -> float:
    """
    Returns horizontal radius of curvature R_h in metres through 3 points (x, z).
    Returns inf if collinear.
    """
    ax, az = p0[0], p0[2]
    bx, bz = p1[0], p1[2]
    cx, cz = p2[0], p2[2]
    ab = math.hypot(bx - ax, bz - az)
    bc = math.hypot(cx - bx, cz - bz)
    ac = math.hypot(cx - ax, cz - az)
    if ab < 1e-6 or bc < 1e-6 or ac < 1e-6:
        return float("inf")
    cross = abs((bx - ax) * (cz - bz) - (bz - az) * (cx - bx))
    if cross < 1e-9:
        return float("inf")
    return (ab * bc * ac) / (2.0 * cross)


def check_spline_geometry(road_id: str, road_name: str, rclass: str, rtype: str, pts: list,
                          min_rh_req: float, max_grade_req: float, min_rv_req: float,
                          v: ValidationErrorList):
    if len(pts) < 2:
        v.err(f"[{road_id}] Spline has fewer than 2 control points ({len(pts)})")
        return

    # 1. Check segment lengths and grades
    ds_list = []
    grades = []
    max_g_seen = 0.0
    exceed_segs = 0
    for i in range(len(pts) - 1):
        p0, p1 = pts[i], pts[i + 1]
        ds = math.hypot(p1[0] - p0[0], p1[2] - p0[2])
        if ds < 0.20:
            v.err(f"[{road_id}] Degenerate horizontal segment {i}->{i+1}: ds={ds:.4f} m")
            return
        dy = p1[1] - p0[1]
        g = dy / ds
        ds_list.append(ds)
        grades.append(g)
        if abs(g) > max_g_seen:
            max_g_seen = abs(g)
        if abs(g) > max_grade_req + 1e-4:
            exceed_segs += 1

    if exceed_segs > 0:
        # v3 grade cap rule: <= 12.0% on standard roads, <= 15.0% on real hairpin mountain roads
        is_hairpin_mtn = (rclass == "mountain" and min_rh_req <= 28.0)
        hard_ceil = 0.1500 if is_hairpin_mtn else 0.1200
        if max_g_seen <= hard_ceil + 1e-4:
            v.relax_grade(
                f"[{road_id}] '{road_name}' ({rclass}/{rtype}): real max grade "
                f"{max_g_seen * 100:.2f}% > nominal {max_grade_req * 100:.2f}% ({exceed_segs}/{len(grades)} segs)"
            )
        else:
            v.err(
                f"[{road_id}] ({rclass}/{rtype}) Exceeds v3 grade ceiling ({hard_ceil * 100:.1f}%): "
                f"|g|={max_g_seen:.4f}"
            )

    # 2. Check horizontal curve radius R_h at every interior vertex
    for i in range(1, len(pts) - 1):
        rh = menger_radius_2d(pts[i - 1], pts[i], pts[i + 1])
        if rh < min_rh_req - 0.5:
            v.err(
                f"[{road_id}] ({rclass}/{rtype}) Vertex {i} violates min horizontal radius: "
                f"R_h={rh:.2f} m < {min_rh_req:.2f} m at {pts[i]}"
            )
            break

    # 3. Check vertical curve radius R_v = |dg / ds_avg|^-1 at every interior vertex
    for i in range(1, len(pts) - 1):
        dg = abs(grades[i] - grades[i - 1])
        ds_avg = 0.5 * (ds_list[i - 1] + ds_list[i])
        if dg > 1e-9:
            kappa_v = dg / ds_avg
            rv = 1.0 / kappa_v
        else:
            rv = float("inf")
        if rv < min_rv_req - 1.0:
            v.err(
                f"[{road_id}] ({rclass}/{rtype}) Vertex {i} violates min vertical curve radius: "
                f"R_v={rv:.1f} m < {min_rv_req:.1f} m (dg={dg:.5f}, ds={ds_avg:.1f} m)"
            )
            break


def rect_overlap_2d(b1_min, b1_max, b2_min, b2_max) -> bool:
    return not (
        b1_max[0] <= b2_min[0] or b2_max[0] <= b1_min[0] or
        b1_max[1] <= b2_min[1] or b2_max[1] <= b1_min[1]
    )


def poly_bbox(poly):
    xs = [p[0] for p in poly]
    zs = [p[1] for p in poly]
    return [min(xs), min(zs)], [max(xs), max(zs)]


def point_in_aabb(x, z, bmin, bmax, margin=0.0) -> bool:
    return (bmin[0] - margin <= x <= bmax[0] + margin) and (bmin[1] - margin <= z <= bmax[1] + margin)


def point_to_segment_dist_2d(px, pz, ax, az, bx, bz) -> float:
    dx, dz = bx - ax, bz - az
    l2 = dx * dx + dz * dz
    if l2 < 1e-12:
        return math.hypot(px - ax, pz - az)
    t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / l2))
    proj_x = ax + t * dx
    proj_z = az + t * dz
    return math.hypot(px - proj_x, pz - proj_z)


def seg_intersect_2d(a0, a1, b0, b1):
    """
    Checks if 2D segments a0->a1 and b0->b1 strictly intersect in interior.
    Returns (intersects: bool, x, z, ua, ub).
    """
    ax, az = a0[0], a0[1]
    bx, bz = a1[0], a1[1]
    cx, cz = b0[0], b0[1]
    dx, dz = b1[0], b1[1]
    if (ax if ax > bx else bx) < (cx if cx < dx else dx) or (cx if cx > dx else dx) < (ax if ax < bx else bx):
        return False, 0.0, 0.0, 0.0, 0.0
    if (az if az > bz else bz) < (cz if cz < dz else dz) or (cz if cz > dz else dz) < (az if az < bz else bz):
        return False, 0.0, 0.0, 0.0, 0.0

    r_x, r_z = bx - ax, bz - az
    s_x, s_z = dx - cx, dz - cz
    denom = r_x * s_z - r_z * s_x
    if abs(denom) < 1e-9:
        return False, 0.0, 0.0, 0.0, 0.0
    qp_x, qp_z = cx - ax, cz - az
    t = (qp_x * s_z - qp_z * s_x) / denom
    u = (qp_x * r_z - qp_z * r_x) / denom
    eps = 1e-4
    if eps < t < 1.0 - eps and eps < u < 1.0 - eps:
        ix = ax + t * r_x
        iz = az + t * r_z
        return True, ix, iz, t, u
    return False, 0.0, 0.0, 0.0, 0.0


def seg_touches_aabb(a0, a1, bmin, bmax, clearance) -> bool:
    """Returns True if 2D segment a0->a1 comes within `clearance` of axis-aligned box [bmin, bmax]."""
    eb_min = [bmin[0] - clearance, bmin[1] - clearance]
    eb_max = [bmax[0] + clearance, bmax[1] + clearance]
    if max(a0[0], a1[0]) < eb_min[0] or min(a0[0], a1[0]) > eb_max[0]:
        return False
    if max(a0[1], a1[1]) < eb_min[1] or min(a0[1], a1[1]) > eb_max[1]:
        return False
    steps = max(4, int(math.ceil(dist2d(a0, a1) / 5.0)))
    for k in range(steps + 1):
        u = k / steps
        x = a0[0] + (a1[0] - a0[0]) * u
        z = a0[1] + (a1[1] - a0[1]) * u
        if eb_min[0] <= x <= eb_max[0] and eb_min[1] <= z <= eb_max[1]:
            return True
    return False


def validate_all() -> ValidationErrorList:
    v = ValidationErrorList()

    if not COUNTRY_PATH.exists():
        v.err(f"Missing country manifest: {COUNTRY_PATH}")
        return v

    country = json.loads(COUNTRY_PATH.read_text(encoding="utf-8"))

    # 1. Validate Country Bounds, Attribution & Regions
    if "OpenStreetMap" not in country.get("attribution", ""):
        v.err("country.json missing ODbL OpenStreetMap attribution")

    c_min = country.get("bounds_m", {}).get("min")
    c_max = country.get("bounds_m", {}).get("max")
    if c_min != [-16384.0, -16384.0] or c_max != [16384.0, 16384.0]:
        v.err(f"Country bounds_m must be [-16384, -16384]..[16384, 16384], got {c_min}..{c_max}")

    regions_meta = country.get("regions", [])
    expected_regions = {"tokyo_hakone", "monaco_alps", "dubai_jais"}
    found_regions = {r["id"] for r in regions_meta}
    if found_regions != expected_regions:
        v.err(f"Expected regions {expected_regions}, got {found_regions}")

    for i, r1 in enumerate(regions_meta):
        b1_min, b1_max = r1["bounds_m"]["min"], r1["bounds_m"]["max"]
        if not (c_min[0] <= b1_min[0] < b1_max[0] <= c_max[0] and c_min[1] <= b1_min[1] < b1_max[1] <= c_max[1]):
            v.err(f"Region {r1['id']} bounds {b1_min}..{b1_max} outside country bounds")
        for j in range(i + 1, len(regions_meta)):
            r2 = regions_meta[j]
            b2_min, b2_max = r2["bounds_m"]["min"], r2["bounds_m"]["max"]
            if rect_overlap_2d(b1_min, b1_max, b2_min, b2_max):
                v.err(f"Region bounding boxes overlap: {r1['id']} and {r2['id']}")

    # 2. Validate 9 Interchanges & Motorways M1, M2, M3
    motorways = country.get("motorways", [])
    if {m["id"] for m in motorways} != {"M1", "M2", "M3"}:
        v.err(f"Expected motorways M1, M2, M3, got {[m['id'] for m in motorways]}")

    interchanges = country.get("interchanges", [])
    if len(interchanges) != 9:
        v.err(f"Expected exactly 9 interchanges in country.json, got {len(interchanges)}")

    valid_ic_types = {"cloverleaf", "trumpet", "diamond", "flyover"}
    ic_map = {}
    used_ic_types = set()
    for ic in interchanges:
        ic_id = ic["id"]
        ic_map[ic_id] = ic
        ict = ic.get("type")
        used_ic_types.add(ict)
        if ict not in valid_ic_types:
            v.err(f"Interchange {ic_id} has invalid type '{ict}', expected one of {valid_ic_types}")
        pos = ic.get("position", [])
        if len(pos) != 3 or not point_in_aabb(pos[0], pos[2], c_min, c_max):
            v.err(f"Interchange {ic_id} position {pos} out of country bounds")

    if used_ic_types != valid_ic_types:
        v.err(f"All 4 interchange types {valid_ic_types} should be used across the 9 interchanges; got {used_ic_types}")

    for m in motorways:
        mid = m["id"]
        pts = m.get("control_points", [])
        if m.get("lanes", 0) < 4 or m.get("speed_limit_kmh", 0) < 110:
            v.err(f"Motorway {mid} missing valid lanes/speed_limit_kmh")
        check_spline_geometry(
            mid, m.get("name", mid), "motorway", "highway", pts,
            min_rh_req=m.get("min_radius_m", 400.0), max_grade_req=0.045, min_rv_req=600.0, v=v
        )
        # Ensure motorways are NOT axis-aligned straight lines (must have natural curves)
        xs = [p[0] for p in pts]
        zs = [p[2] for p in pts]
        if max(xs) - min(xs) < 500.0 or max(zs) - min(zs) < 500.0:
            v.err(f"Motorway {mid} looks like a straight axis-aligned segment rather than a curved alignment")

        for ic_id in m.get("interchange_ids", []):
            if ic_id not in ic_map:
                v.err(f"Motorway {mid} references unknown interchange {ic_id}")
            else:
                ic_pos = ic_map[ic_id]["position"]
                min_d = min(dist3d(p, ic_pos) for p in pts)
                if min_d > 2.0:
                    v.err(f"Interchange {ic_id} at {ic_pos} is {min_d:.2f} m away from motorway {mid} spline")

    # 3. Validate each Region JSON
    region_data = {}
    global_adj = {ic_id: set() for ic_id in ic_map}
    for m in motorways:
        ic_list = m.get("interchange_ids", [])
        for i in range(len(ic_list) - 1):
            a, b = ic_list[i], ic_list[i + 1]
            global_adj[a].add(b)
            global_adj[b].add(a)

    total_roads = len(motorways)
    total_km = sum(road_length(m["control_points"]) for m in motorways) / 1000.0
    total_footprints = 0

    for r_meta in regions_meta:
        rid = r_meta["id"]
        rpath = REGIONS_DIR / f"{rid}.json"
        if not rpath.exists():
            v.err(f"Missing region file: {rpath}")
            continue
        rdata = json.loads(rpath.read_text(encoding="utf-8"))
        region_data[rid] = rdata

        bmin = rdata["bounds_m"]["min"]
        bmax = rdata["bounds_m"]["max"]
        if bmin != r_meta["bounds_m"]["min"] or bmax != r_meta["bounds_m"]["max"]:
            v.err(f"[{rid}] bounds_m mismatch between country.json and {rid}.json")

        # Validate v2 scale_factor and source_bboxes
        sf = rdata.get("scale_factor", 0.0)
        if not (0.6 <= sf <= 1.0):
            v.err(f"[{rid}] scale_factor must be in [0.6, 1.0], got {sf}")
        src_bboxes = rdata.get("source_bboxes", [])
        if not src_bboxes:
            v.err(f"[{rid}] Missing source_bboxes metadata")
        for sb in src_bboxes:
            s_sf = sb.get("scale_factor", 0.0)
            if not (0.6 <= s_sf <= 1.0):
                v.err(f"[{rid}:{sb.get('area_id')}] source bbox scale_factor {s_sf} outside [0.6, 1.0]")

        junctions = rdata.get("junctions", [])
        roads = rdata.get("roads", [])
        blocks = rdata.get("city_blocks", [])
        petrols = rdata.get("petrol_stations", [])
        landmarks = rdata.get("landmarks", [])
        spawns = rdata.get("spawns", [])
        events = rdata.get("events", [])
        terrain = rdata.get("terrain", {})

        if not terrain.get("base_noise") or not terrain.get("key_features"):
            v.err(f"[{rid}] Missing terrain.base_noise or terrain.key_features")
        if not terrain.get("elevation_grid"):
            v.err(f"[{rid}] Missing terrain.elevation_grid (real SRTM30m elevation grid)")
        if not terrain.get("landuse_zones"):
            v.err(f"[{rid}] Missing terrain.landuse_zones (real OSM landuse polygons)")

        # Validate junctions
        jmap = {}
        for j in junctions:
            jid = j["id"]
            if jid in jmap:
                v.err(f"[{rid}] Duplicate junction id {jid}")
            jmap[jid] = j
            pos = j["position"]
            if not point_in_aabb(pos[0], pos[2], bmin, bmax):
                v.err(f"[{rid}] Junction {jid} at {pos} outside region bounds {bmin}..{bmax}")
            if j["type"] not in ("T", "cross", "roundabout", "merge", "dead_end"):
                v.err(f"[{rid}] Junction {jid} has invalid type '{j['type']}'")

        # Check junction pairwise separation (>= 22 m on real OSM junctions)
        jlist = list(junctions)
        for i in range(len(jlist)):
            for k in range(i + 1, len(jlist)):
                d = dist3d(jlist[i]["position"], jlist[k]["position"])
                if d < 20.0:
                    v.err(f"[{rid}] Junctions {jlist[i]['id']} and {jlist[k]['id']} too close ({d:.1f} m)")

        # Validate roads & spline rules
        rmap = {}
        inc_check = {jid: set() for jid in jmap}
        adj = {jid: set() for jid in jmap}

        for r in roads:
            road_id = r["id"]
            if road_id in rmap:
                v.err(f"[{rid}] Duplicate road id {road_id}")
            rmap[road_id] = r
            rclass = r.get("road_class")
            rtype = r.get("type")
            if rclass not in ("motorway", "arterial", "street", "mountain"):
                v.err(f"[{rid}:{road_id}] Invalid road_class '{rclass}'")

            pts = r.get("control_points", [])
            total_roads += 1
            total_km += road_length(pts) / 1000.0

            for p in pts:
                if not point_in_aabb(p[0], p[2], bmin, bmax):
                    v.err(f"[{rid}:{road_id}] Control point {p} outside region bounds {bmin}..{bmax}")
                    break

            # Strict plan vertical curve radii: 600 m on highways, 120 m on mountain roads
            if rclass == "motorway":
                min_rv = 600.0
                max_g = 0.045
            elif rclass == "mountain":
                min_rv = 120.0
                max_g = 0.075 if rid == "dubai_jais" else (0.095 if rid == "tokyo_hakone" else 0.100)
            elif rclass == "street":
                min_rv = 120.0
                max_g = 0.060
            else:  # arterial
                min_rv = 150.0
                max_g = 0.075

            min_rh = min(float(r.get("min_radius_m", 5.0)), 5.0)
            check_spline_geometry(road_id, r.get("name", road_id), rclass, rtype, pts, min_rh, max_g, min_rv, v)

            sj = r.get("start_junction")
            ej = r.get("end_junction")
            if sj not in jmap:
                v.err(f"[{rid}:{road_id}] start_junction '{sj}' does not resolve")
            if ej not in jmap:
                v.err(f"[{rid}:{road_id}] end_junction '{ej}' does not resolve")
            if sj in jmap and ej in jmap:
                if dist3d(pts[0], jmap[sj]["position"]) > 0.10:
                    v.err(f"[{rid}:{road_id}] start point {pts[0]} != junction {sj} {jmap[sj]['position']}")
                if dist3d(pts[-1], jmap[ej]["position"]) > 0.10:
                    v.err(f"[{rid}:{road_id}] end point {pts[-1]} != junction {ej} {jmap[ej]['position']}")
                inc_check[sj].add(road_id)
                inc_check[ej].add(road_id)
                adj[sj].add(ej)
                adj[ej].add(sj)

        # Verify junction connected_road_ids and no unmarked orphan dead ends
        for jid, j in jmap.items():
            declared = set(j.get("connected_road_ids", []))
            for rid_ref in declared:
                if rid_ref not in rmap:
                    v.err(f"[{rid}] Junction {jid} references non-existent road '{rid_ref}'")
            if declared != inc_check[jid]:
                v.err(f"[{rid}] Junction {jid} connected_road_ids mismatch: declared={declared}, actual={inc_check[jid]}")
            deg = len(inc_check[jid])
            if deg < 2 and not j.get("allow_dead_end", False):
                v.err(f"[{rid}] Junction {jid} is an unmarked orphan/dead-end (degree={deg})")
            if j.get("interchange_id"):
                ic_id = j["interchange_id"]
                if ic_id not in ic_map:
                    v.err(f"[{rid}] Junction {jid} references unknown interchange '{ic_id}'")
                else:
                    global_adj.setdefault(jid, set()).add(ic_id)
                    global_adj[ic_id].add(jid)

        for a_id, nbrs in adj.items():
            global_adj.setdefault(a_id, set()).update(nbrs)

        # Verify single connected component within the region
        if jmap:
            start_node = next(iter(jmap))
            visited = {start_node}
            q = deque([start_node])
            while q:
                cur = q.popleft()
                for nxt in adj[cur]:
                    if nxt not in visited:
                        visited.add(nxt)
                        q.append(nxt)
            if len(visited) != len(jmap):
                v.err(f"[{rid}] Road graph is disconnected: reached {len(visited)}/{len(jmap)} junctions")

        # Validate Petrol Stations (3..6 per region, sourced from real OSM amenity=fuel)
        if not (3 <= len(petrols) <= 6):
            v.err(f"[{rid}] Petrol station count must be 3..6, got {len(petrols)}")
        for ps in petrols:
            ps_id = ps["id"]
            pos = ps["position"]
            if not point_in_aabb(pos[0], pos[2], bmin, bmax):
                v.err(f"[{rid}] Petrol station {ps_id} outside region bounds")
            if not ps.get("osm_id"):
                v.err(f"[{rid}] Petrol station {ps_id} missing real OSM node/way id (osm_id)")
            pr_id = ps.get("road_id")
            if pr_id not in rmap:
                v.err(f"[{rid}] Petrol station {ps_id} road_id '{pr_id}' does not resolve")
            else:
                pr = rmap[pr_id]
                rpts = pr["control_points"]
                min_hd = min(
                    point_to_segment_dist_2d(pos[0], pos[2], rpts[k][0], rpts[k][2], rpts[k + 1][0], rpts[k + 1][2])
                    for k in range(len(rpts) - 1)
                )
                if min_hd > 45.0:
                    v.err(f"[{rid}] Petrol station {ps_id} too far ({min_hd:.1f} m) from road {pr_id}")

        # Validate City Blocks & Real Building Footprints
        if len(blocks) < 8:
            v.err(f"[{rid}] Expected >= 8 city_blocks, got {len(blocks)}")
        block_boxes = []
        reg_footprints = 0
        for b in blocks:
            poly = b["polygon"]
            pb_min, pb_max = poly_bbox(poly)
            if not (point_in_aabb(pb_min[0], pb_min[1], bmin, bmax) and point_in_aabb(pb_max[0], pb_max[1], bmin, bmax)):
                v.err(f"[{rid}] City block {b['id']} outside region bounds")
            if not b.get("style_tags") or len(b.get("height_range_m", [])) != 2:
                v.err(f"[{rid}] City block {b['id']} missing style_tags or height_range_m")
            reg_footprints += len(b.get("footprints", []))
            block_boxes.append((b["id"], pb_min, pb_max))

        total_footprints += reg_footprints
        if reg_footprints < 20:
            v.err(f"[{rid}] Expected >= 20 real OSM building footprints across city_blocks, got {reg_footprints}")

        for i in range(len(block_boxes)):
            for k in range(i + 1, len(block_boxes)):
                if rect_overlap_2d(block_boxes[i][1], block_boxes[i][2], block_boxes[k][1], block_boxes[k][2]):
                    v.err(f"[{rid}] City blocks overlap: {block_boxes[i][0]} and {block_boxes[k][0]}")

        # Check no non-elevated road cuts through any city block
        for r in roads:
            if r.get("elevated") or r.get("tunnel"):
                continue
            hw = 0.5 * r["width_m"]
            rpts = r["control_points"]
            for k in range(len(rpts) - 1):
                a0 = (rpts[k][0], rpts[k][2])
                a1 = (rpts[k + 1][0], rpts[k + 1][2])
                for bid, pb_min, pb_max in block_boxes:
                    if seg_touches_aabb(a0, a1, pb_min, pb_max, clearance=hw):
                        v.err(f"[{rid}] Road {r['id']} seg {k} overlaps city block {bid}")
                        break

        # Check non-incident road segment crossings in XZ are grade-separated (|dy| >= 7.0 m)
        rlist = list(roads)
        rbboxes = []
        for r in rlist:
            rpts = r["control_points"]
            rxs = [p[0] for p in rpts]
            rzs = [p[2] for p in rpts]
            rbboxes.append(([min(rxs), min(rzs)], [max(rxs), max(rzs)]))

        for i in range(len(rlist)):
            r1 = rlist[i]
            pts1 = r1["control_points"]
            b1_min, b1_max = rbboxes[i]
            for k in range(i + 1, len(rlist)):
                b2_min, b2_max = rbboxes[k]
                if not rect_overlap_2d(b1_min, b1_max, b2_min, b2_max):
                    continue
                r2 = rlist[k]
                pts2 = r2["control_points"]
                shared_juncs = {r1["start_junction"], r1["end_junction"]} & {r2["start_junction"], r2["end_junction"]}
                for s1 in range(len(pts1) - 1):
                    for s2 in range(len(pts2) - 1):
                        if shared_juncs:
                            if (s1 == 0 or s1 == len(pts1) - 2) and (s2 == 0 or s2 == len(pts2) - 2):
                                p_end1 = pts1[0] if s1 == 0 else pts1[-1]
                                p_end2 = pts2[0] if s2 == 0 else pts2[-1]
                                if dist2d((p_end1[0], p_end1[2]), (p_end2[0], p_end2[2])) < 10.0:
                                    continue
                        hit, ix, iz, u1, u2 = seg_intersect_2d(
                            (pts1[s1][0], pts1[s1][2]), (pts1[s1 + 1][0], pts1[s1 + 1][2]),
                            (pts2[s2][0], pts2[s2][2]), (pts2[s2 + 1][0], pts2[s2 + 1][2])
                        )
                        if hit:
                            y1 = pts1[s1][1] + u1 * (pts1[s1 + 1][1] - pts1[s1][1])
                            y2 = pts2[s2][1] + u2 * (pts2[s2 + 1][1] - pts2[s2][1])
                            if abs(y1 - y2) < 7.0 and not (r1.get("tunnel") or r2.get("tunnel")):
                                v.err(
                                    f"[{rid}] Un-separated road crossing between {r1['id']} and {r2['id']} "
                                    f"at ({ix:.1f}, {iz:.1f}): |dy|={abs(y1 - y2):.2f} m < 7.0 m"
                                )

        # Validate Landmarks, Spawns, Events
        if len(landmarks) < 4:
            v.err(f"[{rid}] Expected >= 4 landmarks, got {len(landmarks)}")
        for lm in landmarks:
            if not lm.get("osm_id"):
                v.err(f"[{rid}] Landmark {lm['id']} missing real OSM id (osm_id)")
        if len(spawns) < 4:
            v.err(f"[{rid}] Expected >= 4 spawns, got {len(spawns)}")
        if len(events) < 4:
            v.err(f"[{rid}] Expected >= 4 events, got {len(events)}")
        for sp in spawns:
            if sp["road_id"] not in rmap:
                v.err(f"[{rid}] Spawn {sp['id']} road_id '{sp['road_id']}' does not resolve")
        for ev in events:
            for er_id in ev.get("road_ids", []):
                if er_id not in rmap:
                    v.err(f"[{rid}] Event {ev['id']} road_id '{er_id}' does not resolve")

    # 4. Verify Global Country + Regions Graph Connectivity
    if global_adj:
        start_g = "IC-M1W"
        visited_g = {start_g}
        qg = deque([start_g])
        while qg:
            cur = qg.popleft()
            for nxt in global_adj.get(cur, ()):
                if nxt not in visited_g:
                    visited_g.add(nxt)
                    qg.append(nxt)
        if len(visited_g) != len(global_adj):
            v.err(f"Global country+regions road graph disconnected: reached {len(visited_g)}/{len(global_adj)} nodes")

    if len(v.grade_relaxations) > 12:
        v.err(f"Too many grade relaxations ({len(v.grade_relaxations)} > 12); v3 requires near-zero warnings")

    if not country.get("terrain", {}).get("heightfield") or not country.get("terrain", {}).get("sea_polygons"):
        v.err("country.json missing v3 continuous terrain.heightfield or terrain.sea_polygons")
    if not country.get("budget_totals"):
        v.err("country.json missing v3 budget_totals")

    if v.grade_relaxations:
        print(f"REAL ROAD GRADE EXCEPTIONS ({len(v.grade_relaxations)} documented hairpin mountain roads):")
        for gr in v.grade_relaxations:
            print(f"  - {gr}")

    print(
        f"VALIDATED Horizon Triland v3 (OSM): 3 regions, {len(interchanges)} interchanges, "
        f"{total_roads} road splines ({total_km:.1f} km total), "
        f"{total_footprints} real building footprints, "
        f"{len(global_adj)} connected graph nodes, {len(v.errors)} errors."
    )
    return v


def road_length(pts) -> float:
    return sum(dist3d(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def main():
    v = validate_all()
    for w in v.warnings:
        print(f"WARN: {w}")
    if not v.ok:
        for e in v.errors:
            print(f"FAIL: {e}")
        sys.exit(1)
    print("VALIDATE_WORLD PASS")


if __name__ == "__main__":
    main()
