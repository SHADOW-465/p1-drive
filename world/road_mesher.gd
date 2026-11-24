class_name RoadMesher
extends RefCounted
## Worker-side road builders (PLAN 2.5 / RD3): banked terrain conform stamping,
## banked road strips, continuous motorway gore merges, roundabouts, filleted junctions,
## props, and collider faces. Reads only RoadGraph & TerrainFn.

const OFF: float = 0.35  # terrain sits this far below the road surface
const VERGE_W: float = 2.5
const VERGE_DROP: float = 0.6
const SIDEWALK: float = 2.5
const KERB: float = 0.15
const KERB_W: float = 0.25
const SHOULDER_W: PackedFloat32Array = [0.75, 0.55, 0.50, 0.0, 0.60, 0.35]
const SHOULDER_DROP: float = 0.025
const MID_LIFT: float = 1.0  # MID ribbons float above the coarse terrain
const TILE: float = 1024.0
const DIRT: Color = Color(0.13, 0.11, 0.06)  # linear; verge/cut tint on the terrain

static var _profiles: Dictionary[int, PackedFloat32Array] = {}  # per (type, width): strips of [x0, y0, x1, y1, class]
static var _max_clear: float = 0.0  # widest clear_hw of any edge (corridor_edge search reach)
static var _median: PackedByteArray = []  # 1: undivided highway, its centre barrier strip is not part of the clear corridor
static var _clear_hw: PackedFloat32Array = []
static var _has_cap: PackedByteArray = []
static var _corridor_grid: Dictionary[Vector2i, PackedInt32Array] = {}
const CORRIDOR_CELL: float = 16.0
const MEDIAN_HW: float = 0.8
const CLEAR_H: float = 4.2  # minimum vertical clearance over a carriageway
const KERB_TOL: float = 0.15  # a bridge piece may reach this far over a road surface (deck fascia, slab edge)
const RAIL_OUT: float = 0.35  # guardrail line outside the shoulder edge (clear of it on the inside of tight bends too)


static func _pkey(type: int, width: float) -> int:
	return type * 10000 + roundi(width * 10.0)


static func _static_init() -> void:
	var n_edges: int = RoadGraph.e_type.size()
	_clear_hw.resize(n_edges)
	_has_cap.resize(n_edges)
	for e: int in n_edges:
		var key: int = _pkey(RoadGraph.e_type[e], RoadGraph.e_width[e])
		if not _profiles.has(key):
			_profiles[key] = _build_profile(RoadGraph.e_type[e], RoadGraph.e_width[e] * 0.5)
		var chw: float = clear_hw(e)
		_clear_hw[e] = chw
		_max_clear = maxf(_max_clear, chw)
		_median.append(1 if RoadGraph.e_type[e] == RoadGraph.HIGHWAY and not RoadGraph.divided(e) else 0)
		var hc: int = 0
		if e < RoadGraph.e_cap.size():
			var hw_e: float = RoadGraph.e_width[e] * 0.5
			for c: float in RoadGraph.e_cap[e]:
				if c < hw_e:
					hc = 1
					break
		_has_cap[e] = hc
		if OsmWorld.enabled:
			var r_e: float = chw + (SIDEWALK if RoadGraph.e_type[e] == RoadGraph.CITY else 0.0)
			var pts: PackedVector3Array = RoadGraph.e_pts[e]
			for i: int in pts.size() - 1:
				var a: Vector3 = pts[i]
				var b: Vector3 = pts[i + 1]
				var x0: int = floori((minf(a.x, b.x) - r_e) / CORRIDOR_CELL)
				var x1: int = floori((maxf(a.x, b.x) + r_e) / CORRIDOR_CELL)
				var z0: int = floori((minf(a.z, b.z) - r_e) / CORRIDOR_CELL)
				var z1: int = floori((maxf(a.z, b.z) + r_e) / CORRIDOR_CELL)
				var code: int = (e << 16) | i
				for cz: int in range(z0, z1 + 1):
					for cx: int in range(x0, x1 + 1):
						var kc := Vector2i(cx, cz)
						if not _corridor_grid.has(kc):
							_corridor_grid[kc] = PackedInt32Array()
						_corridor_grid[kc].append(code)


static func _build_profile(type: int, hw: float) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	if type == RoadGraph.CITY:
		var o: float = hw + SIDEWALK
		p.append_array([-o - VERGE_W, KERB - VERGE_DROP, -o, KERB, 1.0, -o, KERB, -hw - KERB_W, KERB, 0.55])
		p.append_array([-hw - KERB_W, KERB, -hw, KERB, 0.30, -hw, KERB, -hw, 0.0, 0.30])
		p.append_array([-hw, 0.0, hw, 0.0, 0.0])
		p.append_array([hw, 0.0, hw, KERB, 0.30, hw, KERB, hw + KERB_W, KERB, 0.30])
		p.append_array([hw + KERB_W, KERB, o, KERB, 0.55, o, KERB, o + VERGE_W, KERB - VERGE_DROP, 1.0])
	else:
		var sw: float = SHOULDER_W[type]
		var s_out: float = hw + sw
		p.append_array([
			-s_out - VERGE_W, -SHOULDER_DROP - VERGE_DROP, -s_out, -SHOULDER_DROP, 1.0,
			-s_out, -SHOULDER_DROP, -hw, 0.0, 0.30,
			-hw, 0.0, hw, 0.0, 0.0,
			hw, 0.0, s_out, -SHOULDER_DROP, 0.30,
			s_out, -SHOULDER_DROP, s_out + VERGE_W, -SHOULDER_DROP - VERGE_DROP, 1.0,
		])
	return p


## Half width of everything the terrain must stay under (paved + sidewalks) for edge e.
static func half_width(e: int) -> float:
	return RoadGraph.e_width[e] * 0.5 + (SIDEWALK if RoadGraph.e_type[e] == RoadGraph.CITY else 0.0)


## Half width of the clear corridor: carriageway + shoulder (city: + kerb). Nothing but the road itself stands in it.
static func clear_hw(e: int) -> float:
	var t: int = RoadGraph.e_type[e]
	return RoadGraph.e_width[e] * 0.5 + (KERB_W if t == RoadGraph.CITY else SHOULDER_W[t])


## Edge whose clear corridor (clear_hw + margin, + the city sidewalk when `walk`) contains (wx, wz) at a height band
## overlapping [y_lo, y_hi], or -1. The corridor reaches from 1 m under the road surface to CLEAR_H over it (vehicle
## clearance, CLEAR_H), so things under a bridge deck or on a deck overhead do not count. OSM world only (fine index).
static func corridor_edge(wx: float, wz: float, y_lo: float, y_hi: float, margin: float, walk: bool = false, skip: int = -1) -> int:
	return int(_scan(wx, wz, y_lo, y_hi, margin, walk, skip, false, 1.0).x)


## Highest road surface (y) whose corridor contains (wx, wz) in the [y_lo, y_hi] band, or -1e9.
static func corridor_top(wx: float, wz: float, y_lo: float, y_hi: float, margin: float, skip: int = -1) -> float:
	return _scan(wx, wz, y_lo, y_hi, margin, false, skip, true, 1.0).y


## Segment hit test for (wx, wz, y_lo..y_hi). Returns surface y when inside the corridor, or -1e9.
static func _seg_hit(e: int, i: int, wx: float, wz: float, y_lo: float, y_hi: float, margin: float, walk: bool, floor_off: float) -> float:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	if i + 1 >= pts.size():
		return -1e9
	var a: Vector3 = pts[i]
	var b: Vector3 = pts[i + 1]
	if y_hi <= minf(a.y, b.y) - floor_off or y_lo >= maxf(a.y, b.y) + CLEAR_H:
		return -1e9
	var r: float = _clear_hw[e] + margin + (SIDEWALK if walk and RoadGraph.e_type[e] == RoadGraph.CITY else 0.0)
	if wx < minf(a.x, b.x) - r or wx > maxf(a.x, b.x) + r or wz < minf(a.z, b.z) - r or wz > maxf(a.z, b.z) + r:
		return -1e9
	var abx: float = b.x - a.x
	var abz: float = b.z - a.z
	var ab2: float = abx * abx + abz * abz
	var t: float = clampf(((wx - a.x) * abx + (wz - a.z) * abz) / maxf(ab2, 1e-6), 0.0, 1.0)
	var ddx: float = wx - a.x - abx * t
	var ddz: float = wz - a.z - abz * t
	var d2: float = ddx * ddx + ddz * ddz
	if d2 >= r * r:
		return -1e9
	# a parallel carriageway narrows the paved slab on the side facing it (RoadGraph.side_hw): so does the corridor
	if _has_cap[e] == 1:
		var cap: float = RoadGraph.slab_cap(e, i)
		var hw: float = RoadGraph.e_width[e] * 0.5
		if cap < hw:
			var side: float = signf((wz - a.z) * abx - (wx - a.x) * abz)
			var rc: float = r - (hw - RoadGraph.side_hw(e, i, side, hw))
			if d2 >= rc * rc:
				return -1e9
	# the median strip of an undivided highway, for things standing on that road (its barrier, its lamps)
	if _median[e] == 1:
		if (t <= 0.0 and i > 0) or (t >= 1.0 and i + 2 < pts.size()):
			return -1e9  # past this segment's end: the neighbouring segment decides (median or not)
		var cr: float = (wx - a.x) * abz - (wz - a.z) * abx  # distance to the centreline itself, not to a sample
		if cr * cr < MEDIAN_HW * MEDIAN_HW * maxf(ab2, 1e-6) and y_lo <= lerpf(a.y, b.y, t) + 1.6:
			return -1e9
	var ry: float = lerpf(a.y, b.y, t)
	return ry if (y_hi > ry - floor_off and y_lo < ry + CLEAR_H) else -1e9


## (edge, surface y) of the first corridor hit, or with `top` of the highest one; (-1, -1e9) when none.
static func _scan(wx: float, wz: float, y_lo: float, y_hi: float, margin: float, walk: bool, skip: int, top: bool, floor_off: float) -> Vector2:
	var hit := Vector2(-1.0, -1e9)
	var m: float = maxf(margin, 0.0)
	var x0: int = floori((wx - m) / CORRIDOR_CELL)
	var x1: int = floori((wx + m) / CORRIDOR_CELL)
	var z0: int = floori((wz - m) / CORRIDOR_CELL)
	var z1: int = floori((wz + m) / CORRIDOR_CELL)
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var codes: Variant = _corridor_grid.get(Vector2i(cx, cz))
			if codes == null:
				continue
			for code: int in codes as PackedInt32Array:
				var e: int = code >> 16
				if e == skip:
					continue
				var ry: float = _seg_hit(e, code & 0xFFFF, wx, wz, y_lo, y_hi, margin, walk, floor_off)
				if ry > -1e8:
					if not top:
						return Vector2(e, ry)
					if ry > hit.y:
						hit = Vector2(e, ry)
	return hit


## True when an object at tile-local c (radius r, spanning [y_lo, y_hi] world) stands in no road's clear corridor.
static func _clear(c: Vector3, origin: Vector3, r: float, y_lo: float, y_hi: float) -> bool:
	return not OsmWorld.enabled or corridor_edge(c.x + origin.x, c.z + origin.z, y_lo, y_hi, r) < 0


## Bridge piece check: none of the top corners (tile-local) rises more than kerb height over a road surface it stands in
## (its own deck included), unless it sits CLEAR_H or more above that road.
static func _struct_ok(tops: PackedVector3Array, lo: float, origin: Vector3) -> bool:
	if not OsmWorld.enabled:
		return true
	for t: Vector3 in tops:
		if _scan(t.x + origin.x, t.z + origin.z, lo, t.y, 0.0, false, -1, false, -KERB_TOL).x >= 0.0:
			return false
	return true


static func _box_ok(c: Vector3, fwd: Vector3, rt: Vector3, sz: Vector3, origin: Vector3) -> bool:
	var top: Vector3 = c + Vector3(0.0, sz.y * 0.5, 0.0)
	var tops := PackedVector3Array()
	for a: float in [-0.5, 0.0, 0.5]:  # corners, edge midpoints and centre of the top face
		for b: float in [-0.5, 0.0, 0.5]:
			tops.append(top + rt * (a * sz.x) + fwd * (b * sz.z))
	return _struct_ok(tops, c.y - sz.y * 0.5, origin)


static func _seg_ok(c0: Vector3, rt0: Vector3, c1: Vector3, rt1: Vector3, hw: float, y0: float, y1: float, origin: Vector3) -> bool:
	var up := Vector3(0.0, y1, 0.0)
	return _struct_ok(PackedVector3Array([c0 - rt0 * hw + up, c0 + rt0 * hw + up, c1 - rt1 * hw + up, c1 + rt1 * hw + up, (c0 + c1) * 0.5 + up]), minf(c0.y, c1.y) + y0, origin)


## True when a quad (world corners) intrudes a road's clear envelope (see quad_hit).
static func quad_blocked(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> bool:
	return not quad_hit(p0, p1, p2, p3).is_empty()


## First probe of a quad (world corners) inside a road's clear envelope: [edge, probe point], or []. Probes: the centre and
## edge midpoints at their own height, and the corners; a vertical edge (a pole, a wall end) probes its whole height span,
## so something standing on a road counts from its foot (an undivided highway's own median barrier and lamps are free).
static func quad_hit(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Array:
	var lo: float = minf(minf(p0.y, p1.y), minf(p2.y, p3.y))
	var hi: float = maxf(maxf(p0.y, p1.y), maxf(p2.y, p3.y))
	var mid: Vector3 = (p0 + p1 + p2 + p3) * 0.25
	var rad2: float = maxf(
		maxf((p0.x - mid.x) * (p0.x - mid.x) + (p0.z - mid.z) * (p0.z - mid.z), (p1.x - mid.x) * (p1.x - mid.x) + (p1.z - mid.z) * (p1.z - mid.z)),
		maxf((p2.x - mid.x) * (p2.x - mid.x) + (p2.z - mid.z) * (p2.z - mid.z), (p3.x - mid.x) * (p3.x - mid.x) + (p3.z - mid.z) * (p3.z - mid.z))
	)
	var rad: float = sqrt(rad2)
	var x0: int = floori((mid.x - rad) / CORRIDOR_CELL)
	var x1: int = floori((mid.x + rad) / CORRIDOR_CELL)
	var z0: int = floori((mid.z - rad) / CORRIDOR_CELL)
	var z1: int = floori((mid.z + rad) / CORRIDOR_CELL)
	var multi_cell: bool = (x0 != x1 or z0 != z1)
	var cands := PackedInt32Array()
	for cz: int in range(z0, z1 + 1):
		for cx: int in range(x0, x1 + 1):
			var codes: Variant = _corridor_grid.get(Vector2i(cx, cz))
			if codes == null:
				continue
			for code: int in codes as PackedInt32Array:
				if multi_cell and cands.has(code):
					continue
				if _seg_hit(code >> 16, code & 0xFFFF, mid.x, mid.z, lo, hi, rad, false, -KERB_TOL) > -1e8:
					cands.append(code)
	if cands.is_empty():
		return []
	for code: int in cands:
		var e: int = code >> 16
		var si: int = code & 0xFFFF
		if _seg_hit(e, si, mid.x, mid.z, mid.y, mid.y, -0.02, false, -KERB_TOL) > -1e8:
			return [e, mid]
	var u: Vector3 = p0
	var v: Vector3 = p1
	for k: int in 4:
		if k == 1:
			u = p1; v = p2
		elif k == 2:
			u = p2; v = p3
		elif k == 3:
			u = p3; v = p0
		var vert: bool = (u.x - v.x) * (u.x - v.x) + (u.z - v.z) * (u.z - v.z) < 0.0025
		var y_lo: float = minf(u.y, v.y) if vert else u.y
		var y_hi: float = maxf(u.y, v.y) if vert else u.y
		for code: int in cands:
			var e: int = code >> 16
			if _seg_hit(e, code & 0xFFFF, u.x, u.z, y_lo, y_hi, -0.02, false, -KERB_TOL) > -1e8:
				return [e, Vector3(u.x, y_hi, u.z)]
		if not vert:
			var m: Vector3 = (u + v) * 0.5
			for code: int in cands:
				var e: int = code >> 16
				if _seg_hit(e, code & 0xFFFF, m.x, m.z, m.y, m.y, -0.02, false, -KERB_TOL) > -1e8:
					return [e, m]
	return []


## Removes the quads appended since (v0, i0) that intrude a road's clear envelope (bridge pieces where ways merge).
## Every quad is 4 vertices + 6 indices (_quad_uv).
static func _drop_blocking_quads(v0: int, i0: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	if not OsmWorld.enabled:
		return
	var w: int = v0
	var wi: int = i0
	for q: int in range(v0, verts.size() - 3, 4):
		if quad_blocked(verts[q] + origin, verts[q + 1] + origin, verts[q + 2] + origin, verts[q + 3] + origin):
			continue
		if w != q:
			for k: int in 4:
				verts[w + k] = verts[q + k]
				norms[w + k] = norms[q + k]
				uvs[w + k] = uvs[q + k]
				cols[w + k] = cols[q + k]
		for k: int in [0, 1, 2, 0, 2, 3]:
			idx[wi] = w + k
			wi += 1
		w += 4
	verts.resize(w)
	norms.resize(w)
	uvs.resize(w)
	cols.resize(w)
	idx.resize(wi)


## Rolls back an entire multi-quad prop (e.g., streetlight + glow quad) if any quad intrudes a road's clear envelope.
static func _rollback_if_blocked(v0: int, i0: int, gv0: int, gi0: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, g_verts: PackedVector3Array, g_norms: PackedVector3Array, g_uvs: PackedVector2Array, g_cols: PackedColorArray, g_idx: PackedInt32Array) -> void:
	if not OsmWorld.enabled:
		return
	for q: int in range(v0, verts.size() - 3, 4):
		if quad_blocked(verts[q] + origin, verts[q + 1] + origin, verts[q + 2] + origin, verts[q + 3] + origin):
			verts.resize(v0)
			norms.resize(v0)
			uvs.resize(v0)
			cols.resize(v0)
			idx.resize(i0)
			g_verts.resize(gv0)
			g_norms.resize(gv0)
			g_uvs.resize(gv0)
			g_cols.resize(gv0)
			g_idx.resize(gi0)
			return


## Same rule for the collider triangles appended since f0 (a dropped wall must not stay behind as an invisible one).
static func _drop_blocking_faces(f0: int, origin: Vector3, faces: PackedVector3Array) -> void:
	if not OsmWorld.enabled:
		return
	var w: int = f0
	for t: int in range(f0, faces.size() - 2, 3):
		var a: Vector3 = faces[t] + origin
		var b: Vector3 = faces[t + 1] + origin
		var c: Vector3 = faces[t + 2] + origin
		var m: Vector3 = (a + b + c) / 3.0
		if _scan(m.x, m.z, minf(a.y, minf(b.y, c.y)), maxf(a.y, maxf(b.y, c.y)), -0.25, false, -1, false, -KERB_TOL).x >= 0.0:
			continue
		faces[w] = faces[t]
		faces[w + 1] = faces[t + 1]
		faces[w + 2] = faces[t + 2]
		w += 3
	faces.resize(w)


## _clear for something `half` wide along rt (a sign panel, a cap beam): its centre and both ends stay off every corridor.
static func _clear_span(c: Vector3, rt: Vector3, half: float, origin: Vector3, y_lo: float, y_hi: float) -> bool:
	for f: float in [-1.0, 0.0, 1.0]:
		if not _clear(c + rt * (f * half), origin, 0.1, y_lo, y_hi):
			return false
	return true


## Spawn pose near world point w: the nearest sample of a real road stretch (not a junction pad, not a stub under 40 m;
## w.y picks the deck of stacked roads), in the right-hand lane for travel along `dir` (+1 edge order, -1 against).
## {pos, fwd, edge, i}, or {} when no road lies within max_dist.
static func spawn_pose(w: Vector3, dir: float = 1.0, max_dist: float = 800.0) -> Dictionary:
	var runs: Array = []
	var t := Vector2i(floori(w.x / TILE), floori(w.z / TILE))
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			runs.append_array(RoadGraph.runs_in_tile(t.x + dx, t.y + dz))
	if runs.is_empty() or max_dist > TILE:
		for e: int in RoadGraph.e_pts.size():
			runs.append(Vector3i(e, 0, RoadGraph.e_pts[e].size() - 1))
	var best: float = max_dist * max_dist
	var be: int = -1
	var bi: int = 0
	for r: Vector3i in runs:
		if RoadGraph.edge_length(r.x) < 40.0:
			continue
		var rng: Vector2i = edge_range(r.x)
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		for i: int in range(maxi(r.y, rng.x + 3), mini(r.z, rng.y - 3) + 1):
			var dd: float = pts[i].distance_squared_to(w)
			if dd < best:
				var pose: Dictionary = _lane_pose(r.x, i, dir)
				var lp: Vector3 = pose["pos"]
				# the lane must not lie on another road's corridor or sidewalk (parallel streets, overlapping ways)
				if OsmWorld.enabled and corridor_edge(lp.x, lp.z, lp.y, lp.y + 1.2, 0.0, true, r.x) >= 0:
					continue
				best = dd
				be = r.x
				bi = i
	if be < 0:
		return {}
	return _lane_pose(be, bi, dir)


static func _lane_pose(e: int, i: int, dir: float) -> Dictionary:
	var fwd: Vector3 = RoadGraph.tangent(e, i) * (-1.0 if dir < 0.0 else 1.0)
	var flat := Vector3(fwd.x, 0.0, fwd.z).normalized()
	var pos: Vector3 = RoadGraph.e_pts[e][i] + flat.cross(Vector3.UP) * RoadGraph.lane_offset(e, i, -1 if dir < 0.0 else 1)
	return {"pos": pos, "fwd": fwd, "edge": e, "i": i}


## Identifies the pair of through-highway edges at a NODE_MERGE node.
static func _merge_through_pair(node: int) -> Vector2i:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	var hwys: PackedInt32Array = []
	for e: int in ids:
		if RoadGraph.e_type[e] == RoadGraph.HIGHWAY:
			hwys.append(e)
	if hwys.size() < 2:
		return Vector2i(-1, -1)
	if hwys.size() == 2:
		return Vector2i(hwys[0], hwys[1])
	var best_pair := Vector2i(hwys[0], hwys[1])
	var best_dot: float = 2.0
	for a: int in hwys.size():
		var da: Vector3 = _out_dir_xz(hwys[a], node)
		for b: int in range(a + 1, hwys.size()):
			var db: Vector3 = _out_dir_xz(hwys[b], node)
			var d: float = da.dot(db)
			if d < best_dot:
				best_dot = d
				best_pair = Vector2i(hwys[a], hwys[b])
	return best_pair


static func _out_dir_xz(e: int, node: int) -> Vector3:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var d: Vector3
	if RoadGraph.e_a[e] == node:
		d = pts[mini(3, pts.size() - 1)] - pts[0]
	else:
		d = pts[maxi(pts.size() - 4, 0)] - pts[pts.size() - 1]
	d.y = 0.0
	return d.normalized() if d.length_squared() > 1e-4 else Vector3.FORWARD


static func _is_continuation_node(node: int) -> bool:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	if ids.size() != 2:
		return false
	var nk: int = RoadGraph.node_kind[node]
	if nk == RoadGraph.NODE_ROUNDABOUT or nk == RoadGraph.NODE_MERGE:
		return false
	if RoadGraph.e_type[ids[0]] != RoadGraph.e_type[ids[1]]:
		return false
	return _out_dir_xz(ids[0], node).dot(_out_dir_xz(ids[1], node)) < -0.92


## Returns [fwd, rt, up] miter-averaged across collinear continuation nodes so adjacent edges meet without wedge gaps.
static func _section_frame(edge: int, i: int) -> Array[Vector3]:
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var n: int = pts.size()
	var fwd: Vector3 = RoadGraph.tangent(edge, i)
	var b_ang: float = RoadGraph.bank(edge, i)
	if (i == 0 or i == n - 1) and n >= 2:
		var node: int = RoadGraph.e_a[edge] if i == 0 else RoadGraph.e_b[edge]
		if _is_continuation_node(node):
			var ids: PackedInt32Array = RoadGraph.node_edges[node]
			var oe: int = ids[1] if ids[0] == edge else ids[0]
			var o_last: int = RoadGraph.e_pts[oe].size() - 1
			var o_at_a: bool = (RoadGraph.e_a[oe] == node)
			var o_idx: int = 0 if o_at_a else o_last
			var o_fwd: Vector3 = RoadGraph.tangent(oe, o_idx)
			if (i == 0 and o_at_a) or (i == n - 1 and not o_at_a):
				o_fwd = -o_fwd
			var avg: Vector3 = fwd + o_fwd
			if avg.length_squared() > 1e-4:
				fwd = avg.normalized()
			var ob: float = RoadGraph.bank(oe, o_idx)
			if (i == 0 and o_at_a) or (i == n - 1 and not o_at_a):
				ob = -ob
			b_ang = 0.5 * (b_ang + ob)
	var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
	if absf(b_ang) > 1e-5:
		rt = (rt * cos(b_ang) + Vector3.UP * sin(b_ang)).normalized()
	var up_v: Vector3 = rt.cross(fwd).normalized()
	if up_v.y <= 0.1:
		up_v = Vector3.UP
	return [fwd, rt, up_v]


## Returns [p0, p1] interior mountain portal indices along a KIND_TUNNEL edge where ground cover exceeds roof height.
static func _tunnel_portals(e: int) -> Vector2i:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var n: int = pts.size()
	var p0: int = mini(6, n / 4)
	for k: int in range(1, mini(n / 2, 24)):
		if TerrainFn.base_height(pts[k].x, pts[k].z) - pts[k].y >= 6.8:
			p0 = k
			break
	var p1: int = maxi(n - 7, (n * 3) / 4)
	for k: int in range(n - 2, maxi(n / 2, n - 25), -1):
		if TerrainFn.base_height(pts[k].x, pts[k].z) - pts[k].y >= 6.8:
			p1 = k
			break
	return Vector2i(p0, p1)


## Returns world-space portal mouth hole boxes [pos, fwd, rt] for FULL terrain masking around KIND_TUNNEL edges in a tile.
static func tunnel_mouths_in_tile(tx: int, tz: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if OsmWorld.enabled:
		return out  # OSM tunnels are cut open (stamp): a portal hole would only open the hillside beside the cutting
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	for r: Vector3i in runs:
		if RoadGraph.e_kind[r.x] != RoadGraph.KIND_TUNNEL:
			continue
		var e: int = r.x
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var portals: Vector2i = _tunnel_portals(e)
		var hw: float = RoadGraph.e_width[e] * 0.5
		for m: int in 2:
			var pk: int = portals.x if m == 0 else portals.y
			var fwd: Vector3 = RoadGraph.tangent(e, pk) * (1.0 if m == 0 else -1.0)
			var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
			var c_pt: Vector3 = pts[clampi(pk - (1 if m == 0 else -1), 0, pts.size() - 1)]
			out.append({
				"center": Vector2(c_pt.x, c_pt.z),
				"fwd": Vector2(fwd.x, fwd.z).normalized(),
				"rt": Vector2(rt.x, rt.z).normalized(),
				"half_lat": hw + 2.4,
				"min_along": -10.0,
				"max_along": 16.0,
			})
	return out


## Distance (m) an edge stops short of `node` (0 on dead ends, collinear continuations, and continuous merge mainlines).
static func endpoint_cut(e: int, node: int) -> float:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	if ids.size() < 2 or _is_continuation_node(node):
		return 0.0
	var nk: int = RoadGraph.node_kind[node]
	if nk == RoadGraph.NODE_MERGE:
		var thru: Vector2i = _merge_through_pair(node)
		if e == thru.x or e == thru.y:
			return 0.0
		return 62.0 if RoadGraph.e_type[e] == RoadGraph.HIGHWAY else 46.0
	if nk == RoadGraph.NODE_ROUNDABOUT:
		return RoadGraph.node_radius[node] + 8.0

	var max_hw: float = 0.0
	var dirs: Array[Vector3] = []
	for ie: int in ids:
		max_hw = maxf(max_hw, RoadGraph.e_width[ie] * 0.5)
		dirs.append(_out_dir_xz(ie, node))
	var min_ang: float = PI
	for i: int in dirs.size():
		for j: int in range(i + 1, dirs.size()):
			min_ang = minf(min_ang, acos(clampf(dirs[i].dot(dirs[j]), -1.0, 1.0)))
	var cut: float = maxf(1.6 * max_hw + 3.0, (max_hw + 2.5) / maxf(tan(min_ang * 0.5), 0.40))
	return minf(cut, RoadGraph.edge_length(e) * 0.35)


## Sample range where edge e may carry rails: clear of each branch leaving the same node in a similar direction
## (a Y-split at 10 deg stays overlapped for ~70 m; a rail inside that would stand in the other branch's lanes).
static func _rail_range(e: int) -> Vector2i:
	var n: int = RoadGraph.e_pts[e].size()
	var step_d: float = maxf(RoadGraph.e_step[e], 1.0)
	var out := Vector2i(0, n - 1)
	if not OsmWorld.enabled:
		return out
	var hw_e: float = RoadGraph.e_width[e] * 0.5 + 1.5
	for end_i: int in 2:
		var node: int = RoadGraph.e_a[e] if end_i == 0 else RoadGraph.e_b[e]
		var de: Vector3 = _out_dir_xz(e, node)
		var clear: float = 0.0
		for o: int in RoadGraph.node_edges[node]:
			if o == e:
				continue
			var dd: float = de.dot(_out_dir_xz(o, node))
			if dd < -0.5:
				continue  # the road carrying on the other way
			var sin_t: float = sqrt(maxf(1.0 - dd * dd, 0.0))
			# Plus room for the car's turning arc through the corner when the branch really turns off.
			var arc: float = 25.0 if sin_t > 0.3 else 0.0
			clear = maxf(clear, (hw_e + RoadGraph.e_width[o] * 0.5 + 1.5) / maxf(sin_t, 0.08) + arc)
		var k: int = ceili(minf(clear, minf(160.0, (n - 1) * step_d * 0.45)) / step_d)
		if end_i == 0:
			out.x = k
		else:
			out.y = n - 1 - k
	return out


## First and last cross-section index of an edge's road strip.
static func edge_range(e: int) -> Vector2i:
	var n: int = RoadGraph.e_pts[e].size()
	var step_d: float = RoadGraph.e_step[e]
	var ca: float = endpoint_cut(e, RoadGraph.e_a[e])
	var cb: float = endpoint_cut(e, RoadGraph.e_b[e])
	var a: int = ceili(ca / step_d) if ca > 0.01 else 0
	var b: int = n - 1 - (ceili(cb / step_d) if cb > 0.01 else 0)
	if a >= b:
		a = (n - 1) / 2
		b = a
	return Vector2i(a, b)


## Conforms the (n+2)^2 margin grid to the banked roads: bench under the road, smooth blend back.
static func stamp(tx: int, tz: int, n: int, lod: int, h: PackedFloat32Array, cols: PackedColorArray) -> PackedFloat32Array:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return PackedFloat32Array()
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var ox: float = tx * TILE - cell
	var oz: float = tz * TILE - cell
	var full: bool = lod == TileGen.FULL
	# Cells [0, m*m) take the ground roads; [m*m, 2*m*m) the elevated ones (OSM only), which may only lower the
	# terrain: an "elevated" OSM way that runs into a hillside at an interchange must not end in a terrain wall.
	var mm: int = m * m
	var best := PackedFloat32Array()
	best.resize(mm * 2)
	best.fill(1e9)
	var bw := PackedFloat32Array()
	bw.resize(mm * 2)
	var ry := PackedFloat32Array()
	ry.resize(mm * 2)
	# Corridor clamp: a vertex within one grid cell of any road's clear corridor ends under that road's surface, whichever
	# road the blend followed (a street beside a lower motorway, a ramp under a hillside lane): no terrain triangle can
	# rise into a carriageway or its shoulders.
	var cap := PackedFloat32Array()
	cap.resize(mm)
	cap.fill(1e9)
	for r: Vector3i in runs:
		var base: int = 0
		if RoadGraph.e_elev[r.x] == 1:
			if not OsmWorld.enabled:
				continue
			base = mm
		var ekind: int = RoadGraph.e_kind[r.x]
		var is_tunnel: bool = ekind == RoadGraph.KIND_TUNNEL
		var portals: Vector2i = _tunnel_portals(r.x) if is_tunnel else Vector2i(-1, -1)
		var type: int = RoadGraph.e_type[r.x]
		var stride: int = (1 if (type == RoadGraph.MOUNTAIN or is_tunnel) else 2) if full else 8
		# OSM: wider bench than the 16 m heightmap cell so a downsampled chord cannot rise through the lane.
		# OSM tunnels are cut open (below), so they take the open-road bench: a cutting tens of metres deep must not
		# put its wall within one 16 m collider cell of the lane.
		var bore: bool = is_tunnel and not OsmWorld.enabled
		var bench: float = half_width(r.x) + ((2.4 if bore else (20.0 if OsmWorld.enabled else 12.0)) if full else 45.0)
		var blend: float = ((10.0 if bore else (14.0 if type == RoadGraph.MOUNTAIN else 30.0))) if full else 45.0
		var reach: float = bench + blend
		var c_hw: float = clear_hw(r.x)
		var c_r: float = c_hw + cell * 1.5  # the far vertex of a cell diagonal too
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		var i: int = (r.y / stride) * stride
		while i < r.z:
			var i2: int = mini(i + stride, pts.size() - 1)
			# OSM tunnels are cut open (cut-and-cover): their junctions and portals sit next to open ramps whose cuttings
			# would otherwise leave a terrain slope through the bore.
			if is_tunnel and i >= portals.x - 1 and i2 <= portals.y + 1 and not OsmWorld.enabled:
				i = i2
				continue
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i2]
			var ba: float = RoadGraph.bank(r.x, i)
			var bb: float = RoadGraph.bank(r.x, i2)
			var rta: Vector3 = RoadGraph.tangent(r.x, i).cross(Vector3.UP).normalized()
			var rtb: Vector3 = RoadGraph.tangent(r.x, i2).cross(Vector3.UP).normalized()
			i = i2
			var abx: float = b.x - a.x
			var abz: float = b.z - a.z
			var ab2: float = maxf(abx * abx + abz * abz, 1e-6)
			var x0: int = maxi(floori((minf(a.x, b.x) - reach - ox) / cell), 0)
			var x1: int = mini(ceili((maxf(a.x, b.x) + reach - ox) / cell), m - 1)
			var z0: int = maxi(floori((minf(a.z, b.z) - reach - oz) / cell), 0)
			var z1: int = mini(ceili((maxf(a.z, b.z) + reach - oz) / cell), m - 1)
			for gz: int in range(z0, z1 + 1):
				var pz: float = oz + gz * cell - a.z
				for gx: int in range(x0, x1 + 1):
					var px: float = ox + gx * cell - a.x
					var t: float = clampf((px * abx + pz * abz) / ab2, 0.0, 1.0)
					var dx: float = px - abx * t
					var dz: float = pz - abz * t
					var dist: float = sqrt(dx * dx + dz * dz)
					var dd: float = dist - bench
					var q: int = gz * m + gx + base
					if dist < c_r:
						var c_lat: float = clampf(dx * lerpf(rta.x, rtb.x, t) + dz * lerpf(rta.z, rtb.z, t), -c_hw, c_hw)
						var c_y: float = a.y + (b.y - a.y) * t + c_lat * sin(lerpf(ba, bb, t)) - OFF
						if c_y < cap[q - base]:
							cap[q - base] = c_y
					if dd < best[q] and dd < blend:
						best[q] = dd
						bw[q] = 1.0 - smoothstep(0.0, blend, dd)
						var rtx: float = lerpf(rta.x, rtb.x, t)
						var rtz: float = lerpf(rta.z, rtb.z, t)
						var lat: float = clampf(dx * rtx + dz * rtz, -bench, bench)
						var b_ang: float = lerpf(ba, bb, t)
						ry[q] = a.y + (b.y - a.y) * t + lat * sin(b_ang)
	for q: int in mm:
		var w: float = bw[q]
		if w > 0.0:
			h[q] = lerpf(h[q], ry[q] - OFF, w)
			var c: Color = cols[q]
			var k: float = w * 0.22 * (1.0 - c.a)
			cols[q] = Color(lerpf(c.r, DIRT.r, k), lerpf(c.g, DIRT.g, k), lerpf(c.b, DIRT.b, k), c.a)
		var we: float = bw[q + mm]
		if we > 0.0:
			h[q] = minf(h[q], lerpf(h[q], ry[q + mm] - OFF, we))
		h[q] = minf(h[q], cap[q])
	return bw.slice(0, mm)


## Road mesh arrays into d["road"] (tile-local) and, for FULL, collider faces into d["road_faces"].
static func mesh(d: Dictionary, tx: int, tz: int, lod: int) -> void:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return
	var origin := Vector3(tx * TILE, 0.0, tz * TILE)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for r: Vector3i in runs:
		var e: int = r.x
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		if lod != TileGen.FULL:
			_ribbon(e, r, origin, verts, norms, uvs, cols, idx)
			continue
		var rng: Vector2i = edge_range(e)
		var i: int = maxi(r.y, rng.x)
		var end: int = mini(r.z, rng.y - 1)
		while i <= end:
			if not _in_tile(pts[i], tx, tz):
				i += 1
				continue
			var s: int = i
			while i <= end and _in_tile(pts[i], tx, tz):
				i += 1
			_strip(e, s, i, origin, verts, norms, uvs, cols, idx)
	if lod == TileGen.FULL:
		for node: int in RoadGraph.nodes.size():
			if _in_tile(RoadGraph.nodes[node], tx, tz) and RoadGraph.node_edges[node].size() >= 2:
				var nk: int = RoadGraph.node_kind[node]
				if nk == RoadGraph.NODE_MERGE:
					_merge_aprons(node, origin, verts, norms, uvs, cols, idx)
				elif nk == RoadGraph.NODE_ROUNDABOUT:
					_roundabout_mesh(node, origin, verts, norms, uvs, cols, idx)
				elif not _is_continuation_node(node):
					_pad_fillet(node, origin, verts, norms, uvs, cols, idx)
	# Drive slab is the collision floor. On the OSM world it is one layer at the visual
	# surface (no second sheet, no copied kerb triangles, no tile-border extrapolation).
	var splits := PackedInt32Array()
	var faces: PackedVector3Array = _drive_slab_faces(tx, tz, lod, splits)
	if lod == TileGen.FULL and not OsmWorld.enabled:
		for k: int in range(0, idx.size(), 3):
			var i0: int = idx[k]
			var i1: int = idx[k + 1]
			var i2: int = idx[k + 2]
			if cols[i0].b < 0.75 or cols[i1].b < 0.75 or cols[i2].b < 0.75 or (cols[i0].a > 0.25 and cols[i0].a < 0.65):
				faces.append(verts[i0])
				faces.append(verts[i1])
				faces.append(verts[i2])
	if not faces.is_empty():
		d["road_faces"] = faces
		if OsmWorld.enabled:
			d["road_splits"] = splits
	if verts.is_empty():
		return
	d["road"] = {"verts": verts, "norms": norms, "uvs": uvs, "cols": cols, "idx": idx}


static func _in_tile(p: Vector3, tx: int, tz: int) -> bool:
	return floori(p.x / TILE) == tx and floori(p.z / TILE) == tz


## Continuous paved-width ribbon for every LOD. Owns each segment whose start point lies
## in the tile. OSM uses stride 1 and a single layer so neighbouring tiles share the exact
## border cross-section (the old ±0.4 m overlap crossed itself on a grade change).
## At a junction the through pair keeps its slab; every other arm stops at that pair's edge
## so two colliders never stack on the lane the car is driving.
## `splits` receives the face count after each run, so the collider can be chunked without a seam inside a slab.
static func _drive_slab_faces(tx: int, tz: int, lod: int, splits: PackedInt32Array = PackedInt32Array()) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var origin := Vector3(tx * TILE, 0.0, tz * TILE)
	var stride: int = 1 if OsmWorld.enabled else (2 if lod == TileGen.FULL else (4 if lod == TileGen.FAR else 3))
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	for r: Vector3i in runs:
		var edge: int = r.x
		var pts: PackedVector3Array = RoadGraph.e_pts[edge]
		if pts.size() < 2:
			continue
		var hw: float = RoadGraph.e_width[edge] * 0.5 + 1.15
		var i: int = maxi(r.y, 0)
		var last: int = mini(r.z, pts.size() - 1)
		while i <= last:
			if not _in_tile(pts[i], tx, tz):
				i += 1
				continue
			var s0: int = i
			while i <= last and _in_tile(pts[i], tx, tz):
				i += 1
			var b: int = mini(i, pts.size() - 1)
			if OsmWorld.enabled:
				var cut_a: int = _slab_inset(edge, RoadGraph.e_a[edge]) if s0 == 0 else 0
				var cut_b: int = _slab_inset(edge, RoadGraph.e_b[edge]) if b == pts.size() - 1 else 0
				if s0 + cut_a < b - cut_b:
					s0 += cut_a
					b -= cut_b
			_emit_slab(edge, s0, b, stride, hw, origin, lod, faces)
			splits.append(faces.size())
	return faces


## Samples to drop so a side road's slab ends inside the through-road slab. 0 for dead ends, the through pair itself,
## and arms meeting the through line at under ~60 deg: there the trimmed end would leave a hole, so the slabs overlap.
## Rounded down: a short overlap at the node, never a gap.
static func _slab_inset(edge: int, node: int) -> int:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	if ids.size() < 3:
		return 0
	var thru: Vector2i = _through_pair(node)
	if thru.x < 0 or edge == thru.x or edge == thru.y:
		return 0
	var line: Vector3 = _out_dir_xz(thru.x, node) - _out_dir_xz(thru.y, node)
	if line.length_squared() < 1e-4:
		return 0
	line = line.normalized()
	var arm: Vector3 = _out_dir_xz(edge, node)
	var sin_t: float = absf(arm.x * line.z - arm.z * line.x)
	if sin_t < 0.85:
		return 0
	var cos_t: float = sqrt(maxf(1.0 - sin_t * sin_t, 0.0))
	var h_thru: float = minf(RoadGraph.e_width[thru.x], RoadGraph.e_width[thru.y]) * 0.5 + 1.15
	var h_arm: float = RoadGraph.e_width[edge] * 0.5 + 1.15
	var d: float = (h_thru - h_arm * cos_t) / sin_t - 0.5
	return maxi(floori(d / maxf(RoadGraph.e_step[edge], 1.0)), 0)


static func _through_pair(node: int) -> Vector2i:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	var rank: PackedInt32Array = PackedInt32Array([3, 1, 1, 1, 2, 1])
	var best := Vector2i(-1, -1)
	var best_score: float = 1e9
	for a: int in ids.size():
		var da: Vector3 = _out_dir_xz(ids[a], node)
		var ra: int = rank[clampi(RoadGraph.e_type[ids[a]], 0, rank.size() - 1)]
		for b: int in range(a + 1, ids.size()):
			var db: Vector3 = _out_dir_xz(ids[b], node)
			var rb: int = rank[clampi(RoadGraph.e_type[ids[b]], 0, rank.size() - 1)]
			var score: float = da.dot(db) - float(ra + rb) * 0.05
			if score < best_score:
				best_score = score
				best = Vector2i(ids[a], ids[b])
	return best


static func _emit_slab(edge: int, a: int, b: int, stride: int, hw: float, origin: Vector3, lod: int, faces: PackedVector3Array) -> void:
	if b <= a:
		return
	var ids := PackedInt32Array()
	var k: int = a
	while k < b:
		ids.append(k)
		k += stride
	if ids.is_empty() or ids[ids.size() - 1] != b:
		ids.append(b)
	if ids.size() < 2:
		return
	var seam: bool = OsmWorld.enabled
	var drop_top: float = 0.0 if seam else (0.08 if lod == TileGen.FULL else 0.02)
	var drops := PackedFloat32Array([drop_top] if seam else [drop_top, drop_top + 0.7])
	for drop: float in drops:
		var prev_l := Vector3.ZERO
		var prev_r := Vector3.ZERO
		var have: bool = false
		for n: int in ids.size():
			var hw_l: float = RoadGraph.side_hw(edge, ids[n], -1.0, hw) if seam else hw
			var hw_r: float = RoadGraph.side_hw(edge, ids[n], 1.0, hw) if seam else hw
			var left: Vector3 = _slab_corner(edge, ids[n], origin, hw_l, drop, -1.0)
			var right: Vector3 = _slab_corner(edge, ids[n], origin, hw_r, drop, 1.0)
			if not seam and n == 0:
				var back: Vector3 = _along(edge, ids[0], ids[1], -0.4)
				left += back
				right += back
			elif not seam and n == ids.size() - 1:
				var fwd: Vector3 = _along(edge, ids[n - 1], ids[n], 0.4)
				left += fwd
				right += fwd
			if have:
				faces.append(prev_l)
				faces.append(left)
				faces.append(prev_r)
				faces.append(prev_r)
				faces.append(left)
				faces.append(right)
			prev_l = left
			prev_r = right
			have = true


static func _slab_corner(edge: int, i: int, origin: Vector3, hw: float, drop: float, side: float) -> Vector3:
	var frame: Array[Vector3] = _section_frame(edge, i)
	return RoadGraph.e_pts[edge][i] - origin + frame[1] * (hw * side) - frame[2] * drop


static func _along(edge: int, i0: int, i1: int, dist: float) -> Vector3:
	var d: Vector3 = RoadGraph.e_pts[edge][i1] - RoadGraph.e_pts[edge][i0]
	var len: float = d.length()
	if len < 1e-3:
		return Vector3.ZERO
	return d * (dist / len)


static func _vcol(type: int, cls: float, markings: float = 1.0, width: float = -1.0) -> Color:
	return Color(type / 6.0, (RoadGraph.WIDTH[type] if width < 0.0 else width) / 32.0, cls, markings)


## Cross-sections s..e (inclusive) of edge `edge`, banked and one quad strip per profile strip.
static func _strip(edge: int, s: int, e: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var type: int = RoadGraph.e_type[edge]
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var step: float = RoadGraph.e_step[edge]
	var prof: PackedFloat32Array = _profiles[_pkey(type, RoadGraph.e_width[edge])]
	var hw: float = RoadGraph.e_width[edge] * 0.5
	var merge_clips: Array[Vector3] = _merge_side_clips(edge)  # [start_i, end_i, side]
	var rights := PackedVector3Array()
	var ups := PackedVector3Array()
	for i: int in range(s, e + 1):
		var f: Array[Vector3] = _section_frame(edge, i)
		rights.append(f[1])
		ups.append(f[2])
	for k: int in range(0, prof.size(), 5):
		var c: Color = _vcol(type, prof[k + 4], 1.0, RoadGraph.e_width[edge])
		var dx: float = prof[k + 2] - prof[k]
		var dy: float = prof[k + 3] - prof[k + 1]
		var u0: float = prof[k]
		var u1: float = prof[k + 2]
		if is_equal_approx(u0, u1):
			u1 = u0 + absf(dy)
		var strip_side: float = 0.0
		if prof[k + 4] > 0.20:
			strip_side = 1.0 if (prof[k] + prof[k + 2]) * 0.5 > hw * 0.5 else -1.0
		var run_open: bool = false
		var base: int = 0
		var run_s: int = s
		for i: int in range(s, e + 1):
			var skip_seg: bool = false
			if strip_side != 0.0 and not merge_clips.is_empty():
				for mc: Vector3 in merge_clips:
					if mc.z == strip_side and float(i) >= mc.x and float(i) <= mc.y:
						skip_seg = true
						break
			if skip_seg:
				run_open = false
				continue
			var p: Vector3 = pts[i] - origin
			var rt: Vector3 = rights[i - s]
			var up_v: Vector3 = ups[i - s]
			var nrm: Vector3 = (up_v * dx - rt * dy).normalized()
			if nrm.length_squared() < 1e-4:
				nrm = Vector3.UP
			if not run_open:
				base = verts.size()
				run_s = i
				run_open = true
			# A parallel carriageway caps the paved half-width (same cap as the slab): the drawn road is the driven one.
			var x0: float = prof[k]
			var x1: float = prof[k + 2]
			var uu0: float = u0
			var uu1: float = u1
			var ci: Color = c
			var cap: float = RoadGraph.slab_cap(edge, i)
			if cap < hw:
				# Only the side facing the twin moves in. UV.x and the width are re-centred on the paved
				# span [-hw, cap] (or [-cap, hw]) so the markings sit on the carriageway that is drawn.
				var ns: float = RoadGraph.neighbor_side(edge, i)
				if ns != 0.0:
					if signf(x0) == ns:
						x0 = _cap_x(x0, hw, cap)
					if signf(x1) == ns:
						x1 = _cap_x(x1, hw, cap)
					var mid: float = ns * (cap - hw) * 0.5
					uu0 = x0 - mid
					uu1 = x1 - mid if not is_equal_approx(prof[k], prof[k + 2]) else uu0 + absf(dy)
					ci = _vcol(type, prof[k + 4], 1.0, hw + cap)
			verts.append(p + rt * x0 + up_v * prof[k + 1])
			verts.append(p + rt * x1 + up_v * prof[k + 3])
			norms.append(nrm)
			norms.append(nrm)
			uvs.append(Vector2(uu0, i * step))
			uvs.append(Vector2(uu1, i * step))
			cols.append(ci)
			cols.append(ci)
			if i > run_s:
				var b: int = base + (i - run_s) * 2
				idx.append_array([b - 2, b, b - 1, b - 1, b, b + 1])


## Profile x with the paved half-width hw narrowed to cap: paved points scale in, kerb, shoulder and verge keep their width outside it.
static func _cap_x(x: float, hw: float, cap: float) -> float:
	return x * cap / hw if absf(x) <= hw else x - signf(x) * (hw - cap)


static func _merge_side_clips(edge: int) -> Array[Vector3]:
	var clips: Array[Vector3] = []
	if RoadGraph.e_type[edge] != RoadGraph.HIGHWAY:
		return clips
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var step_d: float = RoadGraph.e_step[edge]
	var n_pts: int = pts.size()
	for end_is_a: bool in [true, false]:
		var nid: int = RoadGraph.e_a[edge] if end_is_a else RoadGraph.e_b[edge]
		if RoadGraph.node_kind[nid] != RoadGraph.NODE_MERGE:
			continue
		var thru: Vector2i = _merge_through_pair(nid)
		if edge != thru.x and edge != thru.y:
			continue
		var m_dir: Vector3 = _out_dir_xz(edge, nid)
		var m_rt: Vector3 = m_dir.cross(Vector3.UP).normalized()
		var h_pos: Vector3 = RoadGraph.nodes[nid]
		for oe: int in RoadGraph.node_edges[nid]:
			if oe == thru.x or oe == thru.y:
				continue
			var rng: Vector2i = edge_range(oe)
			var o_at_a: bool = (RoadGraph.e_a[oe] == nid)
			var p_cut: Vector3 = RoadGraph.e_pts[oe][rng.x if o_at_a else rng.y]
			if (p_cut - h_pos).dot(m_dir) < 0.0:
				continue
			var cut_dist: float = maxf((p_cut - h_pos).dot(m_dir), 16.0)
			var apex_dist: float = minf(cut_dist + 36.0, RoadGraph.edge_length(edge) * 0.85)
			var side_sign: float = 1.0 if (p_cut - h_pos).dot(m_rt) >= 0.0 else -1.0
			# If edge starts at nid (end_is_a), rt matches m_rt; if edge ends at nid, rt is -m_rt.
			var local_side: float = side_sign if end_is_a else -side_sign
			var pad_pts: int = ceili(apex_dist / maxf(step_d, 0.5)) - 1
			if end_is_a:
				clips.append(Vector3(0.0, float(mini(pad_pts, n_pts - 2)), local_side))
			else:
				clips.append(Vector3(float(maxi(n_pts - 1 - pad_pts, 1)), float(n_pts - 1), local_side))
	return clips


## MID LOD: flat paved ribbon, one quad per 8 points, owned by the tile of its first point.
static func _ribbon(edge: int, r: Vector3i, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var type: int = RoadGraph.e_type[edge]
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var hw: float = RoadGraph.e_width[edge] * 0.5
	var c: Color = _vcol(type, 0.0, 1.0, RoadGraph.e_width[edge])
	var tx: int = roundi(origin.x / TILE)
	var tz: int = roundi(origin.z / TILE)
	var lift := Vector3(0.0, 0.0 if RoadGraph.e_elev[edge] == 1 else MID_LIFT, 0.0)
	var i: int = ((r.y + 7) / 8) * 8
	while i <= r.z and i < pts.size() - 1:
		var i2: int = mini(i + 8, pts.size() - 1)
		if _in_tile(pts[i], tx, tz):
			var b: int = verts.size()
			for j: int in [i, i2]:
				var rt: Vector3 = RoadGraph.tangent(edge, j).cross(Vector3.UP).normalized()
				verts.append(pts[j] - origin - rt * hw + lift)
				verts.append(pts[j] - origin + rt * hw + lift)
				norms.append(Vector3.UP)
				norms.append(Vector3.UP)
				uvs.append(Vector2(-hw, j * RoadGraph.e_step[edge]))
				uvs.append(Vector2(hw, j * RoadGraph.e_step[edge]))
				cols.append(c)
				cols.append(c)
			idx.append_array([b, b + 2, b + 1, b + 1, b + 2, b + 3])
		i = i2


## Tapered acceleration/deceleration gore aprons where ramps/branches merge onto an unbroken motorway.
static func _merge_aprons(node: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var thru: Vector2i = _merge_through_pair(node)
	if thru.x < 0:
		_pad_fillet(node, origin, verts, norms, uvs, cols, idx)
		return
	var h_edge: int = thru.x
	var h_pts: PackedVector3Array = RoadGraph.e_pts[h_edge]
	var h_at_a: bool = (RoadGraph.e_a[h_edge] == node)
	var h_i: int = 0 if h_at_a else (h_pts.size() - 1)
	var h_pos: Vector3 = RoadGraph.nodes[node]
	var h_fwd: Vector3 = RoadGraph.tangent(h_edge, h_i) * (1.0 if h_at_a else -1.0)
	h_fwd.y = 0.0
	h_fwd = h_fwd.normalized()
	var h_rt: Vector3 = h_fwd.cross(Vector3.UP).normalized()
	var hw_main: float = RoadGraph.e_width[thru.x] * 0.5

	for e: int in RoadGraph.node_edges[node]:
		if e == thru.x or e == thru.y:
			continue
		var rng: Vector2i = edge_range(e)
		var at_a: bool = (RoadGraph.e_a[e] == node)
		var i_cut: int = rng.x if at_a else rng.y
		var p_cut: Vector3 = RoadGraph.e_pts[e][i_cut]
		var out_dir: Vector3 = RoadGraph.tangent(e, i_cut) * (1.0 if at_a else -1.0)
		out_dir.y = 0.0
		out_dir = out_dir.normalized()
		var rt_br: Vector3 = out_dir.cross(Vector3.UP).normalized()
		var hw_br: float = RoadGraph.e_width[e] * 0.5
		var br_l: Vector3 = p_cut - rt_br * hw_br
		var br_r: Vector3 = p_cut + rt_br * hw_br
		var d_l: float = absf((br_l - h_pos).dot(h_rt))
		var d_r: float = absf((br_r - h_pos).dot(h_rt))
		var p_in: Vector3 = br_l if d_l < d_r else br_r
		var p_out: Vector3 = br_r if d_l < d_r else br_l

		# Walk along the highway mainline (picking whichever of thru.x / thru.y points along (p_cut - h_pos))
		var fwd_sign: float = 1.0 if (p_cut - h_pos).dot(h_fwd) >= 0.0 else -1.0
		var m_edge: int = thru.x if fwd_sign > 0.0 else thru.y
		var m_pts: PackedVector3Array = RoadGraph.e_pts[m_edge]
		var m_at_a: bool = (RoadGraph.e_a[m_edge] == node)
		var m_dir: Vector3 = _out_dir_xz(m_edge, node)
		var m_rt: Vector3 = m_dir.cross(Vector3.UP).normalized()
		var m_side: float = 1.0 if (p_cut - h_pos).dot(m_rt) >= 0.0 else -1.0
		var cut_dist: float = maxf((p_cut - h_pos).dot(m_dir), 16.0)
		var apex_dist: float = minf(cut_dist + 36.0, RoadGraph.edge_length(m_edge) * 0.85)
		var steps: int = 8
		var asphalt: Color = _vcol(RoadGraph.e_type[e], 0.0, 0.0)
		var sh_col: Color = _vcol(RoadGraph.e_type[e], 0.30, 0.0)
		var vg_col: Color = _vcol(RoadGraph.e_type[e], 1.0, 0.0)
		var sw: float = SHOULDER_W[RoadGraph.e_type[e]]

		var base_a: int = verts.size()
		for k: int in steps + 1:
			var t: float = float(k) / float(steps)
			var s_m: float = lerpf(0.0, apex_dist, t)
			var m_idx: int = clampi(roundi(s_m / RoadGraph.e_step[m_edge]), 0, m_pts.size() - 1)
			if not m_at_a:
				m_idx = m_pts.size() - 1 - m_idx
			var mp: Vector3 = m_pts[m_idx]
			var mrt: Vector3 = RoadGraph.right(m_edge, m_idx)
			var inner_w: Vector3 = mp + mrt * (m_side * hw_main)
			var outer_w: Vector3
			if s_m <= cut_dist:
				var u_br: float = clampf(s_m / maxf(cut_dist, 1.0), 0.0, 1.0)
				var s_ease: float = u_br * u_br * (3.0 - 2.0 * u_br)
				var edge_p: Vector3 = p_in.lerp(p_out, s_ease)
				# Flare smoothly from highway shoulder out to branch outer corner.
				var flare_w: float = lerpf(hw_main + 0.5, absf((edge_p - mp).dot(mrt)) + 0.5, s_ease)
				outer_w = mp + mrt * (m_side * flare_w)
				outer_w.y = lerpf(inner_w.y, edge_p.y, s_ease)
			else:
				var u_tap: float = clampf((s_m - cut_dist) / maxf(apex_dist - cut_dist, 1.0), 0.0, 1.0)
				var w_out_cut: float = absf((p_out - h_pos).dot(mrt))
				var cur_w: float = lerpf(w_out_cut, hw_main + 0.2, smoothstep(0.0, 1.0, u_tap))
				outer_w = mp + mrt * (m_side * cur_w)
				outer_w.y = lerpf(p_out.y, inner_w.y, u_tap)
			# Ensure outer shoulder & verge drop attach cleanly to the outside edge of the taper.
			var sh_w: Vector3 = outer_w + mrt * (m_side * sw) - Vector3(0.0, SHOULDER_DROP, 0.0)
			var vg_w: Vector3 = sh_w + mrt * (m_side * VERGE_W) - Vector3(0.0, VERGE_DROP, 0.0)
			var p_in_loc: Vector3 = inner_w - origin
			var p_out_loc: Vector3 = outer_w - origin
			var p_sh_loc: Vector3 = sh_w - origin
			var p_vg_loc: Vector3 = vg_w - origin
			# Order vertices left-to-right relative to m_dir so triangle winding faces upward.
			if m_side > 0.0:
				verts.append_array([p_in_loc, p_out_loc, p_sh_loc, p_vg_loc])
			else:
				verts.append_array([p_vg_loc, p_sh_loc, p_out_loc, p_in_loc])
			norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
			var uv_y: float = s_m
			if m_side > 0.0:
				uvs.append_array([Vector2(0.0, uv_y), Vector2(hw_br, uv_y), Vector2(hw_br + sw, uv_y), Vector2(hw_br + sw + VERGE_W, uv_y)])
				cols.append_array([asphalt, asphalt, sh_col, vg_col])
			else:
				uvs.append_array([Vector2(-hw_br - sw - VERGE_W, uv_y), Vector2(-hw_br - sw, uv_y), Vector2(-hw_br, uv_y), Vector2(0.0, uv_y)])
				cols.append_array([vg_col, sh_col, asphalt, asphalt])
			if k > 0:
				var prev: int = base_a + (k - 1) * 4
				var cur: int = base_a + k * 4
				for s_i: int in 3:
					idx.append_array([prev + s_i, cur + s_i, prev + s_i + 1, prev + s_i + 1, cur + s_i, cur + s_i + 1])


## Circular paved roundabout with raised curbed grass central island and flared entry aprons.
static func _roundabout_mesh(node: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var c_w: Vector3 = RoadGraph.nodes[node]
	var c: Vector3 = c_w - origin
	var r_outer: float = maxf(RoadGraph.node_radius[node], 18.0)
	var r_inner: float = maxf(r_outer - 8.8, 9.5)
	var r_kerb: float = r_inner - 0.35
	var segs: int = 36
	var asphalt: Color = _vcol(RoadGraph.COUNTRY, 0.0, 0.0)
	var kerb_col: Color = _vcol(RoadGraph.CITY, 0.30, 0.0)
	var island_col: Color = _vcol(RoadGraph.COUNTRY, 1.0, 0.4)

	# 1. Central island mound + raised granite kerb + circular carriageway ring
	var c_top_i: int = verts.size()
	verts.append(c + Vector3(0.0, 0.55, 0.0))
	norms.append(Vector3.UP)
	uvs.append(Vector2.ZERO)
	cols.append(island_col)

	var ring_base: int = verts.size()
	for i: int in segs + 1:
		var ang: float = float(i) / float(segs) * TAU
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var p_grass: Vector3 = c + dir * r_kerb + Vector3(0.0, 0.16, 0.0)
		var p_kerb_top: Vector3 = c + dir * r_inner + Vector3(0.0, 0.16, 0.0)
		var p_in: Vector3 = c + dir * r_inner
		var p_out: Vector3 = c + dir * r_outer
		var uv_y: float = ang * ((r_inner + r_outer) * 0.5)
		verts.append_array([p_grass, p_kerb_top, p_in, p_out])
		norms.append_array([Vector3.UP, dir, Vector3.UP, Vector3.UP])
		uvs.append_array([Vector2(dir.x * r_kerb, dir.z * r_kerb), Vector2(0.0, uv_y), Vector2(-4.4, uv_y), Vector2(4.4, uv_y)])
		cols.append_array([island_col, kerb_col, asphalt, asphalt])
		if i > 0:
			var prev: int = ring_base + (i - 1) * 4
			var cur: int = ring_base + i * 4
			idx.append_array([c_top_i, prev, cur])
			idx.append_array([prev, prev + 1, cur, prev + 1, cur + 1, cur])
			idx.append_array([prev + 1, prev + 2, cur + 1, prev + 2, cur + 2, cur + 1])
			idx.append_array([prev + 2, prev + 3, cur + 2, prev + 3, cur + 3, cur + 2])

	# 2. Flared entry aprons (pure asphalt across road mouths) + clipped perimeter shoulder & verge arcs
	var arms: Array[Dictionary] = []
	for e: int in RoadGraph.node_edges[node]:
		var rng: Vector2i = edge_range(e)
		var at_a: bool = (RoadGraph.e_a[e] == node)
		var i_cut: int = rng.x if at_a else rng.y
		var p_w: Vector3 = RoadGraph.e_pts[e][i_cut]
		var out_d: Vector3 = _out_dir_xz(e, node)
		var rt: Vector3 = out_d.cross(Vector3.UP).normalized()
		var et: int = RoadGraph.e_type[e]
		var hw: float = RoadGraph.e_width[e] * 0.5
		var sw: float = SHOULDER_W[et]
		var ang: float = fposmod(atan2(p_w.z - c_w.z, p_w.x - c_w.x), TAU)
		var flare_ang: float = clampf((hw + 3.5) / r_outer, 0.14, 0.48)
		arms.append({
			"e": e, "type": et, "p_w": p_w, "out_d": out_d, "rt": rt,
			"hw": hw, "sw": sw, "ang": ang, "flare": flare_ang,
		})
	arms.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ang"]) < float(b["ang"]))

	var na: int = arms.size()
	for k: int in na:
		var prev_a: Dictionary = arms[(k - 1 + na) % na]
		var next_a: Dictionary = arms[(k + 1) % na]
		var ang_k: float = float(arms[k]["ang"])
		var gap_prev: float = fposmod(ang_k - float(prev_a["ang"]), TAU) if na > 1 else TAU
		var gap_next: float = fposmod(float(next_a["ang"]) - ang_k, TAU) if na > 1 else TAU
		var f_l: float = minf(float(arms[k]["flare"]), gap_prev * 0.42)
		var f_r: float = minf(float(arms[k]["flare"]), gap_next * 0.42)
		arms[k]["a_left"] = ang_k - f_l
		arms[k]["a_right"] = ang_k + f_r

		var p_w: Vector3 = arms[k]["p_w"]
		var rt: Vector3 = arms[k]["rt"]
		var hw: float = arms[k]["hw"]
		var sw: float = arms[k]["sw"]
		var et: int = int(arms[k]["type"])
		var p_l: Vector3 = (p_w - rt * hw) - origin
		var p_r: Vector3 = (p_w + rt * hw) - origin
		var p_sl: Vector3 = (p_w - rt * (hw + sw)) - origin - Vector3(0.0, SHOULDER_DROP, 0.0)
		var p_sr: Vector3 = (p_w + rt * (hw + sw)) - origin - Vector3(0.0, SHOULDER_DROP, 0.0)
		var p_vl: Vector3 = p_sl - rt * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
		var p_vr: Vector3 = p_sr + rt * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
		arms[k]["p_l"] = p_l
		arms[k]["p_r"] = p_r
		arms[k]["p_sl"] = p_sl
		arms[k]["p_sr"] = p_sr
		arms[k]["p_vl"] = p_vl
		arms[k]["p_vr"] = p_vr

		var abase: int = verts.size()
		for s: int in 5:
			var f: float = float(s) / 4.0
			var a_ring: float = lerpf(ang_k - f_l, ang_k + f_r, f)
			var r_dir := Vector3(cos(a_ring), 0.0, sin(a_ring))
			var rp_in: Vector3 = c + r_dir * (r_outer - 0.5)
			var rp_out: Vector3 = p_l.lerp(p_r, f)
			verts.append_array([rp_in, rp_out])
			norms.append_array([Vector3.UP, Vector3.UP])
			uvs.append_array([Vector2(rp_in.x - c.x, rp_in.z - c.z), Vector2(rp_out.x - c.x, rp_out.z - c.z)])
			cols.append_array([asphalt, _vcol(et, 0.0, 0.0)])
			if s > 0:
				var pb: int = abase + (s - 1) * 2
				var cb: int = abase + s * 2
				idx.append_array([pb, pb + 1, cb, pb + 1, cb + 1, cb])

	# 3. Outer shoulder & verge ring ONLY on non-road perimeter arcs between adjacent road mouths.
	for k: int in na:
		var a_cur: Dictionary = arms[k]
		var a_nxt: Dictionary = arms[(k + 1) % na]
		var ang_0: float = float(a_cur["a_right"])
		var ang_1: float = float(a_nxt["a_left"])
		var span: float = fposmod(ang_1 - ang_0, TAU)
		var dir0 := Vector3(cos(ang_0), 0.0, sin(ang_0))
		var dir1 := Vector3(cos(ang_1), 0.0, sin(ang_1))
		var ring_e0: Vector3 = c + dir0 * r_outer
		var ring_s0: Vector3 = c + dir0 * (r_outer + 0.6) - Vector3(0.0, SHOULDER_DROP, 0.0)
		var ring_v0: Vector3 = c + dir0 * (r_outer + 0.6 + VERGE_W) - Vector3(0.0, SHOULDER_DROP + VERGE_DROP, 0.0)
		var ring_e1: Vector3 = c + dir1 * r_outer
		var ring_s1: Vector3 = c + dir1 * (r_outer + 0.6) - Vector3(0.0, SHOULDER_DROP, 0.0)
		var ring_v1: Vector3 = c + dir1 * (r_outer + 0.6 + VERGE_W) - Vector3(0.0, SHOULDER_DROP + VERGE_DROP, 0.0)

		var arc_pts: Array[Array] = []  # [p_edge, p_sh, p_vg, u_y, type]
		arc_pts.append([a_cur["p_r"], a_cur["p_sr"], a_cur["p_vr"], 0.0, int(a_cur["type"])])
		arc_pts.append([ring_e0, ring_s0, ring_v0, 4.0, RoadGraph.COUNTRY])
		var steps: int = maxi(ceili(span / TAU * segs), 2)
		for si: int in range(1, steps):
			var aa: float = ang_0 + span * (float(si) / float(steps))
			var d_a := Vector3(cos(aa), 0.0, sin(aa))
			arc_pts.append([
				c + d_a * r_outer,
				c + d_a * (r_outer + 0.6) - Vector3(0.0, SHOULDER_DROP, 0.0),
				c + d_a * (r_outer + 0.6 + VERGE_W) - Vector3(0.0, SHOULDER_DROP + VERGE_DROP, 0.0),
				4.0 + (aa - ang_0) * r_outer,
				RoadGraph.COUNTRY,
			])
		arc_pts.append([ring_e1, ring_s1, ring_v1, 4.0 + span * r_outer, RoadGraph.COUNTRY])
		arc_pts.append([a_nxt["p_l"], a_nxt["p_sl"], a_nxt["p_vl"], 8.0 + span * r_outer, int(a_nxt["type"])])

		var obase: int = verts.size()
		for pi: int in arc_pts.size():
			var ap: Array = arc_pts[pi]
			var uv_y: float = float(ap[3])
			var pt_t: int = int(ap[4])
			verts.append_array([ap[0] as Vector3, ap[1] as Vector3, ap[2] as Vector3])
			norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP])
			uvs.append_array([Vector2(0.0, uv_y), Vector2(0.6, uv_y), Vector2(0.6 + VERGE_W, uv_y)])
			cols.append_array([_vcol(pt_t, 0.30, 0.0), _vcol(pt_t, 0.30, 0.0), _vcol(pt_t, 1.0, 0.0)])
			if pi > 0:
				var pb: int = obase + (pi - 1) * 3
				var cb: int = obase + pi * 3
				idx.append_array([pb, pb + 1, cb, pb + 1, cb + 1, cb])
				idx.append_array([pb + 1, pb + 2, cb + 1, pb + 2, cb + 2, cb + 1])


## Smooth filleted intersection pad with continuous kerb/shoulder/sidewalk corner arcs.
static func _pad_fillet(node: int, origin: Vector3, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var centre: Vector3 = RoadGraph.nodes[node]
	var is_city: bool = true
	var any_type: int = RoadGraph.COUNTRY
	var arms: Array[Dictionary] = []
	for e: int in RoadGraph.node_edges[node]:
		var et: int = RoadGraph.e_type[e]
		if et != RoadGraph.CITY:
			is_city = false
		any_type = et
		var rng: Vector2i = edge_range(e)
		var at_a: bool = (RoadGraph.e_a[e] == node)
		var i_cut: int = rng.x if at_a else rng.y
		var p: Vector3 = RoadGraph.e_pts[e][i_cut]
		var out_d: Vector3 = _out_dir_xz(e, node)
		# Match the road strip's banked cross-section & carriageway cap at i_cut so junction pads never step vertically.
		var frame: Array[Vector3] = _section_frame(e, i_cut)
		var rt_s: Vector3 = frame[1] if at_a else -frame[1]
		var hw: float = RoadGraph.e_width[e] * 0.5
		var hw_l: float = RoadGraph.side_hw(e, i_cut, -1.0 if at_a else 1.0, hw) if OsmWorld.enabled else hw
		var hw_r: float = RoadGraph.side_hw(e, i_cut, 1.0 if at_a else -1.0, hw) if OsmWorld.enabled else hw
		var rt_flat: Vector3 = out_d.cross(Vector3.UP).normalized()
		var ang: float = atan2(p.z - centre.z, p.x - centre.x)
		arms.append({
			"e": e, "type": et, "p": p, "out_d": out_d, "rt": rt_flat, "hw": hw, "ang": ang,
			"l": p - rt_s * hw_l, "r": p + rt_s * hw_r,
		})
	arms.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ang"]) < float(b["ang"]))

	var asphalt: Color = _vcol(RoadGraph.CITY if is_city else any_type, 0.0, 0.0)
	var c_idx: int = verts.size()
	verts.append(centre - origin)
	norms.append(Vector3.UP)
	uvs.append(Vector2.ZERO)
	cols.append(asphalt)

	# Build perimeter ring of points around the junction (road ends + curved 4-step corner fillets)
	var rim_pts := PackedVector3Array()
	var rim_out_dirs := PackedVector3Array()
	var rim_types: PackedInt32Array = []
	var rim_is_road := PackedByteArray()

	var na: int = arms.size()
	for k: int in na:
		var a0: Dictionary = arms[k]
		var a1: Dictionary = arms[(k + 1) % na]
		var p_r: Vector3 = a0["r"]  # right edge of arm k (facing outward = clockwise in XZ? Check!)
		# Note: atan2(z, x) increases clockwise when +X east, +Z south!
		# Outward along arm k is out_d; right vector out_d x UP points clockwise (+angle)!
		var p_l: Vector3 = a0["l"]
		var p_next_l: Vector3 = a1["l"]
		rim_pts.append_array([p_l, p_r])
		rim_out_dirs.append_array([-(a0["rt"] as Vector3), a0["rt"] as Vector3])
		rim_types.append_array([int(a0["type"]), int(a0["type"])])
		rim_is_road.append_array([1, 0])

		# Smooth tangent-aligned corner arc from p_r (arm k right edge) to p_next_l (arm k+1 left edge)
		var d0_xz := Vector2(-float((a0["out_d"] as Vector3).x), -float((a0["out_d"] as Vector3).z)).normalized()
		var d1_xz := Vector2(-float((a1["out_d"] as Vector3).x), -float((a1["out_d"] as Vector3).z)).normalized()
		var corner_ctrl: Vector3 = (p_r + p_next_l) * 0.5
		if d0_xz.dot(d1_xz) > -0.94:
			var det: float = d0_xz.x * (-d1_xz.y) - d0_xz.y * (-d1_xz.x)
			if absf(det) > 0.05:
				var rhs := Vector2(p_next_l.x - p_r.x, p_next_l.z - p_r.z)
				var t_ix: float = (rhs.x * (-d1_xz.y) - rhs.y * (-d1_xz.x)) / det
				var u_ix: float = (d0_xz.x * rhs.y - d0_xz.y * rhs.x) / det
				if t_ix > 0.0 and u_ix > 0.0 and t_ix < 28.0 and u_ix < 28.0:
					corner_ctrl = Vector3(p_r.x + d0_xz.x * t_ix, 0.5 * (p_r.y + p_next_l.y), p_r.z + d0_xz.y * t_ix)
		var corner_type: int = RoadGraph.CITY if (int(a0["type"]) == RoadGraph.CITY or int(a1["type"]) == RoadGraph.CITY) else int(a0["type"])
		for s: int in range(1, 5):
			var t: float = float(s) / 5.0
			var omt: float = 1.0 - t
			var q: Vector3 = p_r * (omt * omt) + corner_ctrl * (2.0 * omt * t) + p_next_l * (t * t)
			q.y = lerpf(p_r.y, p_next_l.y, t)
			var tan_c: Vector3 = (corner_ctrl - p_r) * (2.0 * omt) + (p_next_l - corner_ctrl) * (2.0 * t)
			tan_c.y = 0.0
			var out_n: Vector3 = (-tan_c.cross(Vector3.UP)).normalized() if tan_c.length_squared() > 1e-4 else (q - centre).normalized()
			if out_n.dot((q - centre) * Vector3(1.0, 0.0, 1.0)) < 0.0:
				out_n = -out_n
			rim_pts.append(q)
			rim_out_dirs.append(out_n)
			rim_types.append(corner_type)
			rim_is_road.append(0)

	# Fan asphalt interior + continuous shoulder/kerb/sidewalk/verge skirt around non-road perimeter arcs!
	var rn: int = rim_pts.size()
	var fan_base: int = verts.size()
	for i: int in rn:
		var p: Vector3 = rim_pts[i]
		verts.append(p - origin)
		norms.append(Vector3.UP)
		uvs.append(Vector2(p.x - centre.x, p.z - centre.z))
		cols.append(asphalt)
	for i: int in rn:
		idx.append_array([c_idx, fan_base + i, fan_base + ((i + 1) % rn)])

	# Walk consecutive non-road perimeter spans and extrude matching shoulder/kerb/verge profile!
	for i: int in rn:
		if rim_is_road[i] == 1:
			continue
		var j: int = (i + 1) % rn
		var p0: Vector3 = rim_pts[i] - origin
		var p1: Vector3 = rim_pts[j] - origin
		var n0: Vector3 = rim_out_dirs[i]
		var n1: Vector3 = rim_out_dirs[j]
		var t_p: int = rim_types[i]
		var sw: float = KERB_W if t_p == RoadGraph.CITY else SHOULDER_W[t_p]
		var sh_y: float = KERB if t_p == RoadGraph.CITY else -SHOULDER_DROP
		var sh_col: Color = _vcol(t_p, 0.30, 0.0)
		var vg_col: Color = _vcol(t_p, 1.0, 0.0)
		var b: int = verts.size()
		if t_p == RoadGraph.CITY:
			var sw_col: Color = _vcol(t_p, 0.55, 0.0)
			var k0: Vector3 = p0 + n0 * KERB_W + Vector3(0.0, KERB, 0.0)
			var k1: Vector3 = p1 + n1 * KERB_W + Vector3(0.0, KERB, 0.0)
			var s0: Vector3 = p0 + n0 * (KERB_W + SIDEWALK) + Vector3(0.0, KERB, 0.0)
			var s1: Vector3 = p1 + n1 * (KERB_W + SIDEWALK) + Vector3(0.0, KERB, 0.0)
			var v0: Vector3 = s0 + n0 * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
			var v1: Vector3 = s1 + n1 * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
			verts.append_array([p0, p0 + Vector3(0.0, KERB, 0.0), k0, s0, v0, p1, p1 + Vector3(0.0, KERB, 0.0), k1, s1, v1])
			norms.append_array([n0, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP, n1, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
			uvs.append_array([
				Vector2(0.0, 0.0), Vector2(0.15, 0.0), Vector2(0.4, 0.0), Vector2(2.9, 0.0), Vector2(5.4, 0.0),
				Vector2(0.0, 2.0), Vector2(0.15, 2.0), Vector2(0.4, 2.0), Vector2(2.9, 2.0), Vector2(5.4, 2.0),
			])
			cols.append_array([sh_col, sh_col, sh_col, sw_col, vg_col, sh_col, sh_col, sh_col, sw_col, vg_col])
			for strip_i: int in 4:
				idx.append_array([b + strip_i, b + strip_i + 1, b + 5 + strip_i, b + strip_i + 1, b + 5 + strip_i + 1, b + 5 + strip_i])
		else:
			var s0: Vector3 = p0 + n0 * sw + Vector3(0.0, sh_y, 0.0)
			var s1: Vector3 = p1 + n1 * sw + Vector3(0.0, sh_y, 0.0)
			var v0: Vector3 = s0 + n0 * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
			var v1: Vector3 = s1 + n1 * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0)
			verts.append_array([p0, s0, v0, p1, s1, v1])
			norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
			uvs.append_array([
				Vector2(0.0, 0.0), Vector2(sw, 0.0), Vector2(sw + VERGE_W, 0.0),
				Vector2(0.0, 2.0), Vector2(sw, 2.0), Vector2(sw + VERGE_W, 2.0),
			])
			cols.append_array([sh_col, sh_col, vg_col, sh_col, sh_col, vg_col])
			for strip_i: int in 2:
				idx.append_array([b + strip_i, b + strip_i + 1, b + 3 + strip_i, b + strip_i + 1, b + 3 + strip_i + 1, b + 3 + strip_i])


## Road props for FULL tiles (T18 / R3 / RD3): guardrails (+ merge gap clearing), streetlights, signs.
static func props(d: Dictionary, tx: int, tz: int) -> void:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return
	var origin := Vector3(tx * TILE, 0.0, tz * TILE)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var g_verts := PackedVector3Array()
	var g_norms := PackedVector3Array()
	var g_uvs := PackedVector2Array()
	var g_cols := PackedColorArray()
	var g_idx := PackedInt32Array()
	var faces := PackedVector3Array()
	var rail_col := Color(0.64, 0.67, 0.71).srgb_to_linear()
	rail_col.a = 0.05
	var post_col := Color(0.50, 0.53, 0.57).srgb_to_linear()
	post_col.a = 0.25
	var median_col := Color(0.73, 0.75, 0.76).srgb_to_linear()
	median_col.a = 0.45
	var pole_col := Color(0.58, 0.61, 0.65).srgb_to_linear()
	pole_col.a = 0.25
	var sign_col := Color(1.0, 1.0, 1.0, 0.65)
	var lamp_col := Color.html("#ffd29d").srgb_to_linear()
	lamp_col.a = 0.84
	var tunnel_lamp_col := Color(1.0, 0.88, 0.62, 0.95)
	var conc_col := Color(0.73, 0.75, 0.76).srgb_to_linear()
	conc_col.a = 0.45
	var rock_col := Color(0.36, 0.34, 0.31).srgb_to_linear()
	rock_col.a = 0.45
	var glow_col := Color.html("#ffd29d").srgb_to_linear()
	glow_col.a = 1.0
	for r: Vector3i in runs:
		var e: int = r.x
		var type: int = RoadGraph.e_type[e]
		var ekind: int = RoadGraph.e_kind[e]
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var rng: Vector2i = edge_range(e)
		var i: int = maxi(r.y, rng.x)
		var end: int = mini(r.z, rng.y - 1)
		var hw: float = RoadGraph.e_width[e] * 0.5
		while i <= end:
			if not _in_tile(pts[i], tx, tz):
				i += 1
				continue
			var s: int = i
			while i <= end and _in_tile(pts[i], tx, tz):
				i += 1
			# Rails (colliders) only where this edge has left every branch it shares a node with.
			var rr: Vector2i = _rail_range(e)
			var r_s: int = maxi(s, rr.x)
			var r_e: int = mini(i, rr.y)
			if ekind == RoadGraph.KIND_BRIDGE or ekind == RoadGraph.KIND_OVERPASS:
				var bq0: int = verts.size()
				var bi0: int = idx.size()
				var bf0: int = faces.size()
				_bridge_structure(e, s, i, rng, origin, type, ekind, hw, conc_col, rail_col, post_col, verts, norms, uvs, cols, idx, faces)
				_drop_blocking_quads(bq0, bi0, origin, verts, norms, uvs, cols, idx)
				_drop_blocking_faces(bf0, origin, faces)
				if type == RoadGraph.HIGHWAY and not RoadGraph.divided(e) and r_e - r_s >= 2:
					var mq0: int = verts.size()
					var mi0: int = idx.size()
					var mf0: int = faces.size()
					_rail_strip(e, r_s, r_e, origin, 0.0, 0.28, 0.0, 0.82, median_col, median_col, false, verts, norms, uvs, cols, idx, faces)
					_drop_blocking_quads(mq0, mi0, origin, verts, norms, uvs, cols, idx)
					_drop_blocking_faces(mf0, origin, faces)
			elif ekind == RoadGraph.KIND_TUNNEL:
				_tunnel_structure(e, s, i, rng, origin, hw, conc_col, rock_col, tunnel_lamp_col, verts, norms, uvs, cols, idx, faces)
			elif r_e - r_s < 2:
				pass
			elif type == RoadGraph.HIGHWAY:
				_highway_rails(e, r_s, r_e, origin, hw, rail_col, post_col, median_col, verts, norms, uvs, cols, idx, faces)
			elif type == RoadGraph.RAMP:
				var rs_s: int = maxi(r_s, rng.x + 2)
				var rs_e: int = mini(r_e, rng.y - 2)
				if rs_e - rs_s >= 2:
					var lat_r: float = hw + SHOULDER_W[type] + RAIL_OUT
					_rail_strip(e, rs_s, rs_e, origin, -lat_r, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)
					_rail_strip(e, rs_s, rs_e, origin, lat_r, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)
			elif type == RoadGraph.COUNTRY or type == RoadGraph.MOUNTAIN or type == RoadGraph.RURAL:
				_conditional_rails(e, r_s, r_e, origin, type, hw, rail_col, post_col, verts, norms, uvs, cols, idx, faces)

			if type == RoadGraph.CITY:
				for k: int in range(s, i):
					if k > 0 and k < pts.size() - 1 and k % 7 == 0:
						var side: float = -1.0 if ((k / 7) % 2 == 0) else 1.0
						var p: Vector3 = pts[k] - origin
						var fwd: Vector3 = RoadGraph.tangent(e, k)
						var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
						var lb: Vector3 = p + rt * (side * (hw + 0.6))
						if not (_clear(lb, origin, 0.1, p.y, p.y + 8.0) and _clear(lb - rt * (side * 1.8), origin, 0.3, p.y + 7.7, p.y + 8.0)):
							continue  # pole, and the arm tip 8 m up over the lane, off every road's envelope
						var lq0: int = verts.size()
						var li0: int = idx.size()
						var lgq0: int = g_verts.size()
						var lgi0: int = g_idx.size()
						_add_lamp(p + rt * (side * (hw + 0.6)), fwd, rt * (-side), 8.0, 1.8, pole_col, lamp_col, glow_col, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx, RoadGraph.right(e, k) * (-side))
						_rollback_if_blocked(lq0, li0, lgq0, lgi0, origin, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx)
			elif type == RoadGraph.HIGHWAY:
				var na: Vector3 = RoadGraph.nodes[RoadGraph.e_a[e]]
				var nb: Vector3 = RoadGraph.nodes[RoadGraph.e_b[e]]
				for k: int in range(s, i):
					if k > 0 and k < pts.size() - 1 and k % 12 == 0:
						var pw: Vector3 = pts[k]
						var near_node: bool = pw.distance_squared_to(na) < 22500.0 or pw.distance_squared_to(nb) < 22500.0
						var near_city: bool = TerrainFn.biome_weights(pw.x, pw.z)[TerrainFn.CITY] > 0.15
						if near_node or near_city or ekind != RoadGraph.KIND_ROAD:
							var p: Vector3 = pw - origin
							var fwd: Vector3 = RoadGraph.tangent(e, k)
							var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
							if not RoadGraph.divided(e):
								var arm_l: Vector3 = pw - rt * 1.6
								var arm_r: Vector3 = pw + rt * 1.6
								if not OsmWorld.enabled or (corridor_edge(pw.x, pw.z, pw.y, pw.y + 7.2, 0.1, false, e) < 0 and corridor_edge(arm_l.x, arm_l.z, pw.y + 6.9, pw.y + 7.2, 0.3, false, e) < 0 and corridor_edge(arm_r.x, arm_r.z, pw.y + 6.9, pw.y + 7.2, 0.3, false, e) < 0):  # its own median is free
									var lq0: int = verts.size()
									var li0: int = idx.size()
									var lgq0: int = g_verts.size()
									var lgi0: int = g_idx.size()
									_add_twin_lamp(p, fwd, rt, 7.2, 1.6, pole_col, lamp_col, glow_col, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx, RoadGraph.right(e, k))
									_rollback_if_blocked(lq0, li0, lgq0, lgi0, origin, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx)
							else:
								var out: float = -RoadGraph.neighbor_side(e, k)
								if out == 0.0:
									out = 1.0
								var lb: Vector3 = p + rt * (out * (hw + SHOULDER_W[type] + 1.0))
								if _clear(lb, origin, 0.12, p.y, p.y + 7.2) and _clear(lb - rt * (out * 2.2), origin, 0.3, p.y + 6.9, p.y + 7.2):
									var lq0: int = verts.size()
									var li0: int = idx.size()
									var lgq0: int = g_verts.size()
									var lgi0: int = g_idx.size()
									_add_lamp(lb, fwd, rt * (-out), 7.2, 2.2, pole_col, lamp_col, glow_col, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx, RoadGraph.right(e, k) * (-out))
									_rollback_if_blocked(lq0, li0, lgq0, lgi0, origin, verts, norms, uvs, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx)
			if ekind != RoadGraph.KIND_TUNNEL:
				_road_signs(e, s, i, rng, origin, type, hw, pole_col, sign_col, verts, norms, uvs, cols, idx)
	if not verts.is_empty():
		var props_d: Dictionary = {"verts": verts, "norms": norms, "uvs": uvs, "cols": cols, "idx": idx}
		if not g_verts.is_empty():
			props_d["glow"] = {"verts": g_verts, "norms": g_norms, "uvs": g_uvs, "cols": g_cols, "idx": g_idx}
		d["props"] = props_d
	if not faces.is_empty():
		d["prop_faces"] = faces


## Places highway median barrier continuously and omits outer guardrails only on the merge side near ramp gores.
static func _highway_rails(e: int, s: int, end_i: int, origin: Vector3, hw: float, rail_col: Color, post_col: Color, median_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	# A parallel carriageway already forms the median. A wall on this centreline stands in that lane.
	if not RoadGraph.divided(e):
		var mq0: int = verts.size()
		var mi0: int = idx.size()
		var mf0: int = faces.size()
		_rail_strip(e, s, end_i, origin, 0.0, 0.28, 0.0, 0.82, median_col, median_col, false, verts, norms, uvs, cols, idx, faces)
		_drop_blocking_quads(mq0, mi0, origin, verts, norms, uvs, cols, idx)  # a median deck over a road that rises close under it
		_drop_blocking_faces(mf0, origin, faces)
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var step_d: float = RoadGraph.e_step[e]
	var gaps: Array[Vector2] = []  # [dist_from_a, side]
	for end_is_a: bool in [true, false]:
		var nid: int = RoadGraph.e_a[e] if end_is_a else RoadGraph.e_b[e]
		if RoadGraph.node_kind[nid] != RoadGraph.NODE_MERGE:
			continue
		var thru: Vector2i = _merge_through_pair(nid)
		if e != thru.x and e != thru.y:
			continue
		var h_i: int = 0 if end_is_a else (pts.size() - 1)
		var h_rt: Vector3 = RoadGraph.tangent(e, h_i).cross(Vector3.UP).normalized()
		for oe: int in RoadGraph.node_edges[nid]:
			if oe == thru.x or oe == thru.y:
				continue
			var b_dir: Vector3 = _out_dir_xz(oe, nid)
			var side_s: float = 1.0 if b_dir.dot(h_rt) >= 0.0 else -1.0
			gaps.append(Vector2(0.0 if end_is_a else (pts.size() - 1) * step_d, side_s))

	var near: float = 0.0
	for k: int in range(s, end_i + 1):
		near += RoadGraph.neighbor_side(e, k)
	for side: float in [-1.0, 1.0]:
		if absf(near) > 2.0 and signf(near) == side:
			continue  # this side faces the other carriageway; its rail would stand in that lane
		var run_start: int = -1
		for k: int in range(s, end_i + 1):
			var blocked: bool = false
			var dk: float = k * step_d
			for g: Vector2 in gaps:
				if g.y == side and absf(dk - g.x) < 62.0:
					blocked = true
					break
			if not blocked:
				if run_start < 0:
					run_start = k
			elif run_start >= 0:
				if k - run_start >= 2:
					_rail_strip(e, run_start, k - 1, origin, side * (hw + SHOULDER_W[RoadGraph.HIGHWAY] + RAIL_OUT), 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces, hw)
				run_start = -1
		if run_start >= 0 and end_i - run_start >= 2:
			_rail_strip(e, run_start, end_i, origin, side * (hw + SHOULDER_W[RoadGraph.HIGHWAY] + RAIL_OUT), 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces, hw)


static func _road_signs(e: int, s: int, end_i: int, rng: Vector2i, origin: Vector3, type: int, hw: float, pole_col: Color, sign_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var lat_r: float = hw + SHOULDER_W[type] + (1.25 if type == RoadGraph.HIGHWAY else (0.85 if type != RoadGraph.CITY else 0.55))
	var last_r: int = -100
	var last_l: int = -100
	var last_chev_k: int = -100
	for k: int in range(s, end_i):
		if k - rng.x < 3 or rng.y - k < 3:
			continue
		var fwd: Vector3 = RoadGraph.tangent(e, k)
		var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
		var base_r: Vector3 = pts[k] - origin + rt * lat_r
		var base_l: Vector3 = pts[k] - origin - rt * lat_r

		if k == rng.y - 5 and (type == RoadGraph.COUNTRY or type == RoadGraph.CITY or type == RoadGraph.RURAL):
			if _clear_span(base_r, rt, 0.85 * 0.5, origin, base_r.y, base_r.y + 3.5):
				_add_sign(base_r, fwd, rt, 3, 0.85, 0.85, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_r = k
			continue
		if k == rng.x + 5 and (type == RoadGraph.COUNTRY or type == RoadGraph.CITY or type == RoadGraph.RURAL):
			if _clear_span(base_l, -rt, 0.85 * 0.5, origin, base_l.y, base_l.y + 3.5):
				_add_sign(base_l, -fwd, -rt, 3, 0.85, 0.85, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_l = k
			continue
		if k == rng.y - 14 and type == RoadGraph.HIGHWAY:
			if _clear_span(base_r, rt, 1.9 * 0.5, origin, base_r.y, base_r.y + 3.5):
				_add_sign(base_r, fwd, rt, 7, 1.9, 1.3, 3.0, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_r = k
			continue
		if k == rng.x + 14 and type == RoadGraph.HIGHWAY:
			if _clear_span(base_l, -rt, 1.9 * 0.5, origin, base_l.y, base_l.y + 3.5):
				_add_sign(base_l, -fwd, -rt, 7, 1.9, 1.3, 3.0, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_l = k
			continue

		var speed_slot: int = 0 if type == RoadGraph.HIGHWAY else (1 if type == RoadGraph.COUNTRY else 2)
		if k % 80 == 22 and k - last_r >= 20:
			if _clear_span(base_r, rt, 0.95 * 0.5, origin, base_r.y, base_r.y + 3.5):
				_add_sign(base_r, fwd, rt, speed_slot, 0.95, 0.95, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_r = k
		if k % 80 == 62 and k - last_l >= 20:
			if _clear_span(base_l, -rt, 0.95 * 0.5, origin, base_l.y, base_l.y + 3.5):
				_add_sign(base_l, -fwd, -rt, speed_slot, 0.95, 0.95, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
			last_l = k

		if (type == RoadGraph.MOUNTAIN or type == RoadGraph.COUNTRY or type == RoadGraph.RURAL) and k >= 6 and k + 6 < pts.size():
			var t0: Vector3 = RoadGraph.tangent(e, k - 4)
			var t1: Vector3 = RoadGraph.tangent(e, k + 4)
			var turn: float = t0.cross(t1).y
			var abs_turn: float = absf(turn)
			if abs_turn > 0.24 and k - last_chev_k >= 7:
				var out_side: float = 1.0 if turn > 0.0 else -1.0
				var chev_pos: Vector3 = pts[k] - origin + rt * (out_side * (hw + SHOULDER_W[type] + 0.75))
				if _clear_span(chev_pos, rt * out_side, 1.05 * 0.5, origin, chev_pos.y, chev_pos.y + 3.5):
					_add_sign(chev_pos, fwd * out_side, rt * out_side, 6, 1.05, 0.75, 1.85, pole_col, sign_col, verts, norms, uvs, cols, idx)
				last_chev_k = k
			elif abs_turn > 0.16 and k - last_r >= 26 and k - last_l >= 26:
				var slot_f: int = 5 if turn > 0.0 else 4
				var slot_b: int = 4 if turn > 0.0 else 5
				if _clear_span(base_r, rt, 0.9 * 0.5, origin, base_r.y, base_r.y + 3.5):
					_add_sign(base_r, fwd, rt, slot_f, 0.9, 0.9, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
				if _clear_span(base_l, -rt, 0.9 * 0.5, origin, base_l.y, base_l.y + 3.5):
					_add_sign(base_l, -fwd, -rt, slot_b, 0.9, 0.9, 2.5, pole_col, sign_col, verts, norms, uvs, cols, idx)
				last_r = k
				last_l = k


static func _add_sign(base: Vector3, fwd: Vector3, rt: Vector3, slot: int, w: float, h: float, pole_h: float, pole_col: Color, sign_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var post_h: float = pole_h + h * 0.35
	_add_box(base + Vector3(0.0, post_h * 0.5, 0.0), fwd, rt, Vector3(0.08, post_h, 0.08), pole_col, verts, norms, uvs, cols, idx)
	var face_c: Vector3 = base + Vector3(0.0, pole_h, 0.0) - fwd * 0.065
	_add_box(base + Vector3(0.0, pole_h, 0.0) - fwd * 0.025, fwd, rt, Vector3(w * 0.96, h * 0.96, 0.03), pole_col, verts, norms, uvs, cols, idx)
	var rx: Vector3 = rt * (w * 0.5)
	var ry: Vector3 = Vector3.UP * (h * 0.5)
	var col_i: int = slot % 4
	var row_i: int = slot / 4
	var u0: float = col_i * 0.25 + 0.006
	var u1: float = (col_i + 1) * 0.25 - 0.006
	var v0: float = row_i * 0.5 + 0.006
	var v1: float = (row_i + 1) * 0.5 - 0.006
	var b: int = verts.size()
	verts.append_array([face_c - rx - ry, face_c - rx + ry, face_c + rx + ry, face_c + rx - ry])
	var n: Vector3 = -fwd
	norms.append_array([n, n, n, n])
	uvs.append_array([Vector2(u0, v1), Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1)])
	cols.append_array([sign_col, sign_col, sign_col, sign_col])
	idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])


static func _conditional_rails(e: int, s: int, end_i: int, origin: Vector3, type: int, hw: float, rail_col: Color, post_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var run_l: int = -1
	var run_r: int = -1
	var is_cr: bool = (type == RoadGraph.COUNTRY or type == RoadGraph.RURAL)
	var lat_off: float = hw + SHOULDER_W[type] + RAIL_OUT
	for k: int in range(s, end_i + 1, 2):
		var ki: int = mini(k, end_i)
		var p: Vector3 = pts[ki]
		var rt: Vector3 = RoadGraph.tangent(e, ki).cross(Vector3.UP).normalized()
		var sp_l: Vector3 = p - rt * (hw + 6.0)
		var sp_r: Vector3 = p + rt * (hw + 6.0)
		var hl: float = TerrainFn.base_height(sp_l.x, sp_l.z)
		var hr: float = TerrainFn.base_height(sp_r.x, sp_r.z)
		var need_l: bool = (p.y - hl) > 3.2 if is_cr else ((hl < hr - 0.5) and (p.y - hl > 1.2))
		var need_r: bool = (p.y - hr) > 3.2 if is_cr else ((hr < hl - 0.5) and (p.y - hr > 1.2))
		if need_l:
			if run_l < 0:
				run_l = ki
		elif run_l >= 0:
			if ki - run_l >= 2:
				_rail_strip(e, run_l, ki, origin, -lat_off, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)
			run_l = -1
		if need_r:
			if run_r < 0:
				run_r = ki
		elif run_r >= 0:
			if ki - run_r >= 2:
				_rail_strip(e, run_r, ki, origin, lat_off, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)
			run_r = -1
	if run_l >= 0 and end_i - run_l >= 2:
		_rail_strip(e, run_l, end_i, origin, -lat_off, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)
	if run_r >= 0 and end_i - run_r >= 2:
		_rail_strip(e, run_r, end_i, origin, lat_off, 0.08, 0.40, 0.78, rail_col, post_col, true, verts, norms, uvs, cols, idx, faces)


static func _rail_strip(e: int, s: int, end_i: int, origin: Vector3, lat: float, half_w: float, y0: float, y1: float, col: Color, post_col: Color, with_posts: bool, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array, pave_hw: float = -1.0) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var step_len: float = RoadGraph.e_step[e]
	var steps: PackedInt32Array = []
	var k: int = s
	while k < end_i:
		steps.append(k)
		k += 1  # every sample: an 8 m chord cuts ~0.3 m into the shoulder on a 25 m bend
	steps.append(end_i)
	var prev_c := Vector3.ZERO
	var prev_rt := Vector3.ZERO
	var prev_u: float = 0.0
	var has_prev: bool = false
	for si: int in steps.size():
		var ki: int = steps[si]
		var fwd: Vector3 = RoadGraph.tangent(e, ki)
		var rt: Vector3 = RoadGraph.right(e, ki)
		var lat_i: float = lat
		if pave_hw >= 0.0:
			var cap_i: float = RoadGraph.slab_cap(e, ki)
			if cap_i < 1.0e5 and RoadGraph.neighbor_side(e, ki) * lat > 0.0:
				lat_i = signf(lat) * (minf(pave_hw, cap_i) + absf(lat) - pave_hw)
		var c: Vector3 = pts[ki] - origin + rt * lat_i
		var cur_u: float = ki * step_len * 0.5
		# Off another road's lanes (junction, gore, a ramp running alongside) and, for side rails, off its own: on a bend
		# tighter than the road is wide the inner offset line folds back over the carriageway.
		var blocked: bool = false
		if OsmWorld.enabled:
			for f: float in [-1.0, 0.0, 1.0]:  # both faces and the centre (a median's faces may leave a neighbour's median strip)
				var q: Vector3 = c + origin + rt * (f * half_w)
				# (0.5 m of slack below: the road under a deck rises between samples)
				if corridor_edge(q.x, q.z, pts[ki].y - 0.5, pts[ki].y + y1, 0.1, false, e if lat == 0.0 else -1) >= 0:
					blocked = true
		if blocked:
			has_prev = false
			continue
		var mid_ok: bool = true
		if OsmWorld.enabled and has_prev:
			var mq: Vector3 = (prev_c + c) * 0.5 + origin
			mid_ok = corridor_edge(mq.x, mq.z, pts[ki].y - 0.5, pts[ki].y + y1, half_w + 0.1, false, e if lat == 0.0 else -1) < 0
		if has_prev and mid_ok:
			if not with_posts and lat == 0.0:
				_add_jersey_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, col, verts, norms, uvs, cols, idx)
			elif with_posts:
				_add_wbeam_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, half_w, y0, y1, col, verts, norms, uvs, cols, idx)
			else:
				_add_prism_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, half_w, y0, y1, col, verts, norms, uvs, cols, idx)
			var a0: Vector3 = prev_c
			var a1: Vector3 = prev_c + Vector3(0.0, 0.95, 0.0)
			var b0: Vector3 = c
			var b1: Vector3 = c + Vector3(0.0, 0.95, 0.0)
			faces.append_array([a0, b0, a1, a1, b0, b1])
		if not with_posts and lat == 0.0 and si % 6 == 0:
			# Retroreflective amber delineator marker on top of the Jersey concrete median
			var refl_col := Color(1.0, 0.68, 0.14, 0.94)
			_add_box(c + Vector3(0.0, 0.90, 0.0), fwd, rt, Vector3(0.06, 0.09, 0.14), refl_col, verts, norms, uvs, cols, idx)
		if with_posts and si % 4 == 0:
			# Offset steel I-beam post + blockout spacer behind the W-beam
			var out_s: float = signf(lat) if lat != 0.0 else 1.0
			var post_c: Vector3 = c + rt * (out_s * 0.10)
			_add_box(post_c + Vector3(0.0, y1 * 0.52, 0.0), fwd, rt, Vector3(0.09, y1 * 1.04, 0.10), post_col, verts, norms, uvs, cols, idx)
			_add_box(c + rt * (out_s * 0.04) + Vector3(0.0, (y0 + y1) * 0.5, 0.0), fwd, rt, Vector3(0.08, (y1 - y0) * 0.85, 0.08), post_col, verts, norms, uvs, cols, idx)
			if si % 8 == 0:
				var del_col := Color(0.98, 0.96, 0.88, 0.94)
				_add_box(c + Vector3(0.0, y1 + 0.04, 0.0), fwd, rt, Vector3(0.05, 0.07, 0.08), del_col, verts, norms, uvs, cols, idx)
		prev_c = c
		prev_rt = rt
		prev_u = cur_u
		has_prev = true


## Sculpted New Jersey concrete highway barrier profile (wide 0.60 m base, sloped lower deflector, tapered upper wall, cap).
static func _add_jersey_seg(c0: Vector3, rt0: Vector3, u0: float, c1: Vector3, rt1: Vector3, u1: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	# Profile points (half-width, height) from base up to top cap
	var w0: float = 0.30; var h0: float = 0.0
	var w1: float = 0.28; var h1: float = 0.10
	var w2: float = 0.15; var h2: float = 0.34
	var w3: float = 0.10; var h3: float = 0.86
	var prof_w := PackedFloat32Array([w0, w1, w2, w3])
	var prof_h := PackedFloat32Array([h0, h1, h2, h3])
	var rt_m: Vector3 = (rt0 + rt1).normalized()
	for s_i: int in 3:
		var wa: float = prof_w[s_i]; var ha: float = prof_h[s_i]
		var wb: float = prof_w[s_i + 1]; var hb: float = prof_h[s_i + 1]
		var dw: float = wa - wb
		var dh: float = hb - ha
		var nl: Vector3 = (-rt_m * dh + Vector3.UP * dw).normalized()
		var nr: Vector3 = (rt_m * dh + Vector3.UP * dw).normalized()
		# Left face
		_quad_uv(
			c1 - rt1 * wa + Vector3(0.0, ha, 0.0), c1 - rt1 * wb + Vector3(0.0, hb, 0.0),
			c0 - rt0 * wb + Vector3(0.0, hb, 0.0), c0 - rt0 * wa + Vector3(0.0, ha, 0.0),
			nl, Vector2(ha, u1), Vector2(hb, u1), Vector2(hb, u0), Vector2(ha, u0), col, verts, norms, uvs, cols, idx)
		# Right face
		_quad_uv(
			c0 + rt0 * wa + Vector3(0.0, ha, 0.0), c0 + rt0 * wb + Vector3(0.0, hb, 0.0),
			c1 + rt1 * wb + Vector3(0.0, hb, 0.0), c1 + rt1 * wa + Vector3(0.0, ha, 0.0),
			nr, Vector2(ha, u0), Vector2(hb, u0), Vector2(hb, u1), Vector2(ha, u1), col, verts, norms, uvs, cols, idx)
	# Top cap
	_quad_uv(
		c1 - rt1 * w3 + Vector3(0.0, h3, 0.0), c1 + rt1 * w3 + Vector3(0.0, h3, 0.0),
		c0 + rt0 * w3 + Vector3(0.0, h3, 0.0), c0 - rt0 * w3 + Vector3(0.0, h3, 0.0),
		Vector3.UP, Vector2(0.0, u1), Vector2(w3 * 2.0, u1), Vector2(w3 * 2.0, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)


## Corrugated W-beam steel guardrail profile (upper & lower beveled flanges + recessed central valley for crisp metallic catch-lights).
static func _add_wbeam_seg(c0: Vector3, rt0: Vector3, u0: float, c1: Vector3, rt1: Vector3, u1: float, hw: float, y0: float, y1: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var ym: float = (y0 + y1) * 0.5
	var y_lo: float = lerpf(y0, ym, 0.5)
	var y_hi: float = lerpf(ym, y1, 0.5)
	var w_out: float = hw * 1.15
	var w_in: float = hw * 0.55
	var rt_m: Vector3 = (rt0 + rt1).normalized()
	var ws := PackedFloat32Array([w_in, w_out, w_in, w_out, w_in])
	var hs := PackedFloat32Array([y0, y_lo, ym, y_hi, y1])
	for s_i: int in 4:
		var wa: float = ws[s_i]; var ha: float = hs[s_i]
		var wb: float = ws[s_i + 1]; var hb: float = hs[s_i + 1]
		var dw: float = wa - wb
		var dh: float = hb - ha
		var nl: Vector3 = (-rt_m * dh + Vector3.UP * dw).normalized()
		var nr: Vector3 = (rt_m * dh + Vector3.UP * dw).normalized()
		_quad_uv(
			c1 - rt1 * wa + Vector3(0.0, ha, 0.0), c1 - rt1 * wb + Vector3(0.0, hb, 0.0),
			c0 - rt0 * wb + Vector3(0.0, hb, 0.0), c0 - rt0 * wa + Vector3(0.0, ha, 0.0),
			nl, Vector2(ha - y0, u1), Vector2(hb - y0, u1), Vector2(hb - y0, u0), Vector2(ha - y0, u0), col, verts, norms, uvs, cols, idx)
		_quad_uv(
			c0 + rt0 * wa + Vector3(0.0, ha, 0.0), c0 + rt0 * wb + Vector3(0.0, hb, 0.0),
			c1 + rt1 * wb + Vector3(0.0, hb, 0.0), c1 + rt1 * wa + Vector3(0.0, ha, 0.0),
			nr, Vector2(ha - y0, u0), Vector2(hb - y0, u0), Vector2(hb - y0, u1), Vector2(ha - y0, u1), col, verts, norms, uvs, cols, idx)
	_quad_uv(
		c1 - rt1 * w_in + Vector3(0.0, y1, 0.0), c1 + rt1 * w_in + Vector3(0.0, y1, 0.0),
		c0 + rt0 * w_in + Vector3(0.0, y1, 0.0), c0 - rt0 * w_in + Vector3(0.0, y1, 0.0),
		Vector3.UP, Vector2(0.0, u1), Vector2(w_in * 2.0, u1), Vector2(w_in * 2.0, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)


static func _add_prism_seg(c0: Vector3, rt0: Vector3, u0: float, c1: Vector3, rt1: Vector3, u1: float, hw: float, y0: float, y1: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var l0b: Vector3 = c0 - rt0 * hw + Vector3(0.0, y0, 0.0)
	var l0t: Vector3 = c0 - rt0 * hw + Vector3(0.0, y1, 0.0)
	var r0t: Vector3 = c0 + rt0 * hw + Vector3(0.0, y1, 0.0)
	var r0b: Vector3 = c0 + rt0 * hw + Vector3(0.0, y0, 0.0)
	var l1b: Vector3 = c1 - rt1 * hw + Vector3(0.0, y0, 0.0)
	var l1t: Vector3 = c1 - rt1 * hw + Vector3(0.0, y1, 0.0)
	var r1t: Vector3 = c1 + rt1 * hw + Vector3(0.0, y1, 0.0)
	var r1b: Vector3 = c1 + rt1 * hw + Vector3(0.0, y0, 0.0)
	var nl: Vector3 = -0.5 * (rt0 + rt1)
	var nr: Vector3 = 0.5 * (rt0 + rt1)
	var vh: float = (y1 - y0) * 1.1
	_quad_uv(l1b, l1t, l0t, l0b, nl, Vector2(0.0, u1), Vector2(vh, u1), Vector2(vh, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)
	_quad_uv(l1t, r1t, r0t, l0t, Vector3.UP, Vector2(0.0, u1), Vector2(hw * 2.0, u1), Vector2(hw * 2.0, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)
	_quad_uv(r0b, r0t, r1t, r1b, nr, Vector2(0.0, u0), Vector2(vh, u0), Vector2(vh, u1), Vector2(0.0, u1), col, verts, norms, uvs, cols, idx)


## Tapered galvanized street-lamp mast with concrete pedestal flange, upswept cobra-head arm, and recessed LED housing.
static func _add_taper_mast(base: Vector3, fwd: Vector3, rt: Vector3, h: float, r_bot: float, r_top: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var dirs: Array[Vector3] = [rt, fwd, -rt, -fwd]
	for k: int in 4:
		var d0: Vector3 = (dirs[k] + dirs[(k + 1) % 4]).normalized()
		var d1: Vector3 = (dirs[(k + 1) % 4] + dirs[(k + 2) % 4]).normalized()
		var n: Vector3 = dirs[(k + 1) % 4]
		var p0: Vector3 = base + d0 * r_bot
		var p1: Vector3 = base + d0 * r_top + Vector3(0.0, h, 0.0)
		var p2: Vector3 = base + d1 * r_top + Vector3(0.0, h, 0.0)
		var p3: Vector3 = base + d1 * r_bot
		_quad_uv(p0, p1, p2, p3, n, Vector2(0.0, 0.0), Vector2(0.0, h), Vector2(r_bot * 2.0, h), Vector2(r_bot * 2.0, 0.0), col, verts, norms, uvs, cols, idx)


static func _add_arm_seg(p0: Vector3, p1: Vector3, fwd: Vector3, r: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var dir: Vector3 = (p1 - p0).normalized()
	var up_a: Vector3 = fwd.cross(dir).normalized()
	if up_a.y < 0.0:
		up_a = -up_a
	var len_a: float = p0.distance_to(p1)
	var ff: Vector3 = fwd * r
	var uu: Vector3 = up_a * r
	_quad_uv(p0 + uu - ff, p1 + uu - ff, p1 + uu + ff, p0 + uu + ff, up_a, Vector2(0.0, 0.0), Vector2(len_a, 0.0), Vector2(len_a, r * 2.0), Vector2(0.0, r * 2.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(p0 - uu + ff, p1 - uu + ff, p1 - uu - ff, p0 - uu - ff, -up_a, Vector2(0.0, 0.0), Vector2(len_a, 0.0), Vector2(len_a, r * 2.0), Vector2(0.0, r * 2.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(p0 - uu - ff, p1 - uu - ff, p1 + uu - ff, p0 + uu - ff, -fwd, Vector2(0.0, 0.0), Vector2(len_a, 0.0), Vector2(len_a, r * 2.0), Vector2(0.0, r * 2.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(p0 + uu + ff, p1 + uu + ff, p1 - uu + ff, p0 - uu + ff, fwd, Vector2(0.0, 0.0), Vector2(len_a, 0.0), Vector2(len_a, r * 2.0), Vector2(0.0, r * 2.0), col, verts, norms, uvs, cols, idx)


static func _add_lamp(base: Vector3, fwd: Vector3, inward: Vector3, h: float, reach: float, pole_col: Color, lamp_col: Color, glow_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, g_verts: PackedVector3Array, g_norms: PackedVector3Array, g_uvs: PackedVector2Array, g_cols: PackedColorArray, g_idx: PackedInt32Array, road_rt: Vector3 = Vector3.ZERO) -> void:
	# Tapered galvanized pole + flanged base collar
	_add_box(base + Vector3(0.0, 0.22, 0.0), fwd, inward, Vector3(0.26, 0.44, 0.26), pole_col, verts, norms, uvs, cols, idx)
	_add_taper_mast(base + Vector3(0.0, 0.40, 0.0), fwd, inward, h - 0.65, 0.11, 0.065, pole_col, verts, norms, uvs, cols, idx)
	# Upswept 2-segment cobra-head mast arm
	var a0: Vector3 = base + Vector3(0.0, h - 0.35, 0.0)
	var a1: Vector3 = base + Vector3(0.0, h - 0.04, 0.0) + inward * (reach * 0.55)
	var a2: Vector3 = base + Vector3(0.0, h + 0.04, 0.0) + inward * (reach - 0.18)
	_add_arm_seg(a0, a1, fwd, 0.045, pole_col, verts, norms, uvs, cols, idx)
	_add_arm_seg(a1, a2, fwd, 0.038, pole_col, verts, norms, uvs, cols, idx)
	# Cobra-head aerodynamic metal hood + small warm emissive lamp head underneath
	var head_c: Vector3 = base + Vector3(0.0, h + 0.02, 0.0) + inward * reach
	_add_box(head_c + Vector3(0.0, 0.045, 0.0), fwd, inward, Vector3(0.52, 0.08, 0.26), pole_col, verts, norms, uvs, cols, idx)
	_add_box(head_c + Vector3(0.0, -0.018, 0.0), fwd, inward, Vector3(0.36, 0.055, 0.19), lamp_col, verts, norms, uvs, cols, idx)
	var g_rt: Vector3 = road_rt if road_rt.length_squared() > 1e-4 else inward
	_add_glow_quad(base + g_rt * reach + Vector3(0.0, 0.05, 0.0), fwd, g_rt, 6.8, glow_col, g_verts, g_norms, g_uvs, g_cols, g_idx)


static func _add_twin_lamp(base: Vector3, fwd: Vector3, rt: Vector3, h: float, reach: float, pole_col: Color, lamp_col: Color, glow_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, g_verts: PackedVector3Array, g_norms: PackedVector3Array, g_uvs: PackedVector2Array, g_cols: PackedColorArray, g_idx: PackedInt32Array, road_rt: Vector3 = Vector3.ZERO) -> void:
	# Tapered galvanized median mast + upswept twin cobra-head arms
	_add_taper_mast(base + Vector3(0.0, 0.80, 0.0), fwd, rt, h - 1.05, 0.11, 0.070, pole_col, verts, norms, uvs, cols, idx)
	var g_rt: Vector3 = road_rt if road_rt.length_squared() > 1e-4 else rt
	for s: float in [-1.0, 1.0]:
		var inward: Vector3 = rt * s
		var a0: Vector3 = base + Vector3(0.0, h - 0.35, 0.0)
		var a1: Vector3 = base + Vector3(0.0, h - 0.04, 0.0) + inward * (reach * 0.55)
		var a2: Vector3 = base + Vector3(0.0, h + 0.04, 0.0) + inward * (reach - 0.18)
		_add_arm_seg(a0, a1, fwd, 0.045, pole_col, verts, norms, uvs, cols, idx)
		_add_arm_seg(a1, a2, fwd, 0.038, pole_col, verts, norms, uvs, cols, idx)
		var head_c: Vector3 = base + Vector3(0.0, h + 0.02, 0.0) + inward * reach
		_add_box(head_c + Vector3(0.0, 0.045, 0.0), fwd, inward, Vector3(0.52, 0.08, 0.26), pole_col, verts, norms, uvs, cols, idx)
		_add_box(head_c + Vector3(0.0, -0.018, 0.0), fwd, inward, Vector3(0.36, 0.055, 0.19), lamp_col, verts, norms, uvs, cols, idx)
		_add_glow_quad(base + g_rt * (s * reach) + Vector3(0.0, 0.05, 0.0), fwd, g_rt, 7.4, glow_col, g_verts, g_norms, g_uvs, g_cols, g_idx)


static func _add_glow_quad(c: Vector3, fwd: Vector3, rt: Vector3, half_sz: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var b: int = verts.size()
	verts.append_array([c - rt * half_sz - fwd * half_sz, c + rt * half_sz - fwd * half_sz, c + rt * half_sz + fwd * half_sz, c - rt * half_sz + fwd * half_sz])
	norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	uvs.append_array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	cols.append_array([col, col, col, col])
	idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])


static func _add_box(c: Vector3, fwd: Vector3, rt: Vector3, sz: Vector3, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var rx: Vector3 = rt * (sz.x * 0.5)
	var ry: Vector3 = Vector3.UP * (sz.y * 0.5)
	var rz: Vector3 = fwd * (sz.z * 0.5)
	_quad_uv(c - rx - ry + rz, c - rx + ry + rz, c - rx + ry - rz, c - rx - ry - rz, -rt, Vector2(0.0, 0.0), Vector2(0.0, sz.y), Vector2(sz.z, sz.y), Vector2(sz.z, 0.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(c + rx - ry - rz, c + rx + ry - rz, c + rx + ry + rz, c + rx - ry + rz, rt, Vector2(0.0, 0.0), Vector2(0.0, sz.y), Vector2(sz.z, sz.y), Vector2(sz.z, 0.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(c + rx - ry + rz, c + rx + ry + rz, c - rx + ry + rz, c - rx - ry + rz, fwd, Vector2(0.0, 0.0), Vector2(0.0, sz.y), Vector2(sz.x, sz.y), Vector2(sz.x, 0.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(c - rx - ry - rz, c - rx + ry - rz, c + rx + ry - rz, c + rx - ry - rz, -fwd, Vector2(0.0, 0.0), Vector2(0.0, sz.y), Vector2(sz.x, sz.y), Vector2(sz.x, 0.0), col, verts, norms, uvs, cols, idx)
	_quad_uv(c - rx + ry + rz, c + rx + ry + rz, c + rx + ry - rz, c - rx + ry - rz, Vector3.UP, Vector2(0.0, 0.0), Vector2(sz.x, 0.0), Vector2(sz.x, sz.z), Vector2(0.0, sz.z), col, verts, norms, uvs, cols, idx)
	_quad_uv(c - rx - ry - rz, c + rx - ry - rz, c + rx - ry + rz, c - rx - ry + rz, Vector3.DOWN, Vector2(0.0, 0.0), Vector2(sz.x, 0.0), Vector2(sz.x, sz.z), Vector2(0.0, sz.z), col, verts, norms, uvs, cols, idx)


static func _quad_uv(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var b: int = verts.size()
	verts.append_array([p0, p1, p2, p3])
	norms.append_array([n, n, n, n])
	uvs.append_array([uv0, uv1, uv2, uv3])
	cols.append_array([col, col, col, col])
	idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])


## Builds 3D bridge/overpass concrete deck slab, box girder, crash parapets + steel rails, abutments, and piers to ground.
static func _bridge_structure(e: int, s: int, end_i: int, rng: Vector2i, origin: Vector3, type: int, ekind: int, hw: float, conc_col: Color, rail_col: Color, post_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var step_len: float = RoadGraph.e_step[e]
	var sw: float = clear_hw(e) - hw  # shoulder (city: kerb)
	var hw_deck: float = hw + sw + 0.55
	var girder_hw: float = hw * 0.58
	var girder_bot: float = -1.65 if (type == RoadGraph.HIGHWAY or hw > 6.0) else -1.15

	var steps: PackedInt32Array = []
	var k: int = s
	while k < end_i:
		steps.append(k)
		k += 1  # every sample: a road crossing under the deck between samples must still see its clearance
	steps.append(end_i)

	var prev_c := Vector3.ZERO
	var prev_rt := Vector3.ZERO
	var prev_u: float = 0.0
	var has_prev: bool = false
	var prev_hang: float = -girder_bot
	var prev_merged: bool = false
	for si: int in steps.size():
		var ki: int = steps[si]
		var pw: Vector3 = pts[ki]
		var fwd: Vector3 = RoadGraph.tangent(e, ki)
		var rt: Vector3 = RoadGraph.right(e, ki)  # banked: structure follows the deck's roll (a flat slab pokes up on the low side)
		var c: Vector3 = pw - origin
		var cur_u: float = ki * step_len * 0.4

		# Where the deck still shares its footprint with another way (a ramp splitting off, a junction) its slab would poke
		# through that road: no deck structure there. Over a lower road the girder and slab stop CLEAR_H above it.
		var merged: bool = false
		var hang: float = -girder_bot
		if OsmWorld.enabled:
			var y_m_lo: float = pw.y - 0.65
			var y_m_hi: float = pw.y + 1.1
			var y_b_lo: float = pw.y + girder_bot
			var y_b_hi: float = pw.y - 1.5
			for f: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
				var q: Vector3 = pw + rt * (f * hw_deck)
				var codes: Variant = _corridor_grid.get(Vector2i(floori(q.x / CORRIDOR_CELL), floori(q.z / CORRIDOR_CELL)))
				if codes == null:
					continue
				var below: float = -1e9
				for code: int in codes as PackedInt32Array:
					var oe: int = code >> 16
					if oe == e:
						continue
					var ry: float = _seg_hit(oe, code & 0xFFFF, q.x, q.z, y_b_lo, y_m_hi, 0.0, false, 1.0)
					if ry > -1e8:
						if y_m_hi > ry - 1.0 and y_m_lo < ry + CLEAR_H:
							merged = true
						if y_b_hi > ry - 1.0 and y_b_lo < ry + CLEAR_H and ry > below:
							below = ry
				if below > -1e8:
					hang = minf(hang, pw.y - below - CLEAR_H - 0.25)  # margin: the road below rises between samples
		var seg_hang: float = minf(hang, prev_hang)
		var seg_ok: bool = not merged and not prev_merged
		prev_hang = hang
		prev_merged = merged
		if has_prev and seg_ok and seg_hang > 0.12:
			# 1. Deck edge fascia & underside slab (y: -0.62 .. -0.04; thinner where a road passes close underneath)
			if _seg_ok(prev_c, prev_rt, c, rt, hw_deck, -minf(seg_hang, 0.62), -0.04, origin):
				_add_soffit_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, hw_deck, -minf(seg_hang, 0.62), -0.04, conc_col, verts, norms, uvs, cols, idx)
			# 2. Central box-girder spine (y: girder_bot .. -0.60), only where it clears the road below
			if seg_hang > 0.9 and _seg_ok(prev_c, prev_rt, c, rt, girder_hw, -minf(seg_hang, -girder_bot), -0.60, origin):
				_add_soffit_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, girder_hw, -minf(seg_hang, -girder_bot), -0.60, conc_col, verts, norms, uvs, cols, idx)
		if has_prev:
			# 3. Left & right concrete crash parapets + top steel railing + collision walls
			for side: float in [-1.0, 1.0]:
				var lat_p: float = side * (hw + sw + 0.35)  # inner face 0.15 m outside the shoulder
				if OsmWorld.enabled:
					var pa: Vector3 = prev_c + prev_rt * lat_p + origin
					var pb: Vector3 = c + rt * lat_p + origin
					if corridor_edge(pa.x, pa.z, pa.y - 0.04, pa.y + 1.08, 0.25, false, e) >= 0 or corridor_edge(pb.x, pb.z, pb.y - 0.04, pb.y + 1.08, 0.25, false, e) >= 0:
						continue  # the deck runs into a junction or beside another road: no wall across its lanes
				_add_prism_seg(prev_c + prev_rt * lat_p, prev_rt, prev_u, c + rt * lat_p, rt, cur_u, 0.20, -0.04, 0.86, conc_col, verts, norms, uvs, cols, idx)
				_add_prism_seg(prev_c + prev_rt * lat_p, prev_rt, prev_u, c + rt * lat_p, rt, cur_u, 0.06, 0.94, 1.08, rail_col, verts, norms, uvs, cols, idx)
				var a0: Vector3 = prev_c + prev_rt * (side * (hw + sw + 0.15))  # at the parapet's inner face
				var b0: Vector3 = c + rt * (side * (hw + sw + 0.15))
				faces.append_array([a0, b0, a0 + Vector3(0.0, 1.12, 0.0), a0 + Vector3(0.0, 1.12, 0.0), b0, b0 + Vector3(0.0, 1.12, 0.0)])
				if si % 4 == 0:
					_add_box(c + rt * lat_p + Vector3(0.0, 0.92, 0.0), fwd, rt, Vector3(0.09, 0.16, 0.09), post_col, verts, norms, uvs, cols, idx)

		# Abutments & end wing-pillars near the start/end of bridge/overpass
		if ki <= rng.x + 1 or ki >= rng.y - 1:
			var abut_ok: bool = not merged
			if OsmWorld.enabled:
				for f: float in [-1.0, 0.0, 1.0]:
					var q: Vector3 = pw + rt * (f * hw_deck)
					if corridor_edge(q.x, q.z, pw.y - 6.85, pw.y - 0.65, 1.2, false, e) >= 0:
						abut_ok = false  # a road passes beside or under the bridge end
			if abut_ok and _box_ok(c + Vector3(0.0, -3.75, 0.0), fwd, rt, Vector3(hw_deck * 2.0, 6.2, 2.2), origin):
				_add_box(c + Vector3(0.0, -3.75, 0.0), fwd, rt, Vector3(hw_deck * 2.0, 6.2, 2.2), conc_col, verts, norms, uvs, cols, idx)
			for side: float in [-1.0, 1.0]:
				if _clear(c + rt * (side * (hw + sw + 0.6)), origin, 0.7, c.y, c.y + 1.1) and _box_ok(c + rt * (side * (hw + sw + 0.6)) + Vector3(0.0, 0.46, 0.0), fwd, rt, Vector3(0.65, 1.15, 1.2), origin):
					_add_box(c + rt * (side * (hw + sw + 0.6)) + Vector3(0.0, 0.46, 0.0), fwd, rt, Vector3(0.65, 1.15, 1.2), conc_col, verts, norms, uvs, cols, idx)

		# Support piers every ~28m (never on top of another crossing road)
		if ki > rng.x + 3 and ki < rng.y - 3 and ki % 7 == 3:
			var need_twin: bool = hw > 5.0
			var pier_lats: PackedFloat32Array = PackedFloat32Array([-hw * 0.46, hw * 0.46]) if need_twin else PackedFloat32Array([0.0])
			var any_ok: bool = false
			for plat: float in pier_lats:
				var p_world: Vector3 = pw + rt * plat
				var gh: float = TerrainFn.base_height(p_world.x, p_world.z) - 3.5
				var top_y: float = pw.y + girder_bot + 0.1
				if not _near_lower_road(p_world.x, p_world.z, pw.y, e) and (not OsmWorld.enabled or corridor_edge(p_world.x, p_world.z, gh, pw.y, 0.8, false, e) < 0):
					any_ok = true
					var bot: float = minf(gh, top_y - 1.5)  # never taller than the gap: a pier must not rise through a low deck
					var col_h: float = top_y - bot
					var col_c := Vector3(p_world.x - origin.x, bot + col_h * 0.5 - origin.y, p_world.z - origin.z)
					var col_w: float = 1.45 if type == RoadGraph.HIGHWAY else 1.15
					if not _box_ok(col_c, fwd, rt, Vector3(col_w, col_h, col_w), origin):
						continue
					_add_box(col_c, fwd, rt, Vector3(col_w, col_h, col_w), conc_col, verts, norms, uvs, cols, idx)
					if ekind == RoadGraph.KIND_OVERPASS:
						# Add pier collision box for lower road safety
						_add_box_faces(col_c, fwd, rt, Vector3(col_w, col_h, col_w), faces)
			var cap_l: Vector3 = pw - rt * (hw * 0.7)
			var cap_r: Vector3 = pw + rt * (hw * 0.7)
			if any_ok and _box_ok(c + Vector3(0.0, girder_bot - 0.35, 0.0), fwd, rt, Vector3(hw * 1.4, 0.85, 1.6), origin) and (not OsmWorld.enabled or (corridor_edge(cap_l.x, cap_l.z, pw.y + girder_bot - 0.78, pw.y, 0.8, false, e) < 0 and corridor_edge(cap_r.x, cap_r.z, pw.y + girder_bot - 0.78, pw.y, 0.8, false, e) < 0)):
				_add_box(c + Vector3(0.0, girder_bot - 0.35, 0.0), fwd, rt, Vector3(hw * 1.4, 0.85, 1.6), conc_col, verts, norms, uvs, cols, idx)

		prev_c = c
		prev_rt = rt
		prev_u = cur_u
		has_prev = true


static func _add_soffit_seg(c0: Vector3, rt0: Vector3, u0: float, c1: Vector3, rt1: Vector3, u1: float, hw: float, y0: float, y1: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var l0b: Vector3 = c0 - rt0 * hw + Vector3(0.0, y0, 0.0)
	var l0t: Vector3 = c0 - rt0 * hw + Vector3(0.0, y1, 0.0)
	var r0t: Vector3 = c0 + rt0 * hw + Vector3(0.0, y1, 0.0)
	var r0b: Vector3 = c0 + rt0 * hw + Vector3(0.0, y0, 0.0)
	var l1b: Vector3 = c1 - rt1 * hw + Vector3(0.0, y0, 0.0)
	var l1t: Vector3 = c1 - rt1 * hw + Vector3(0.0, y1, 0.0)
	var r1t: Vector3 = c1 + rt1 * hw + Vector3(0.0, y1, 0.0)
	var r1b: Vector3 = c1 + rt1 * hw + Vector3(0.0, y0, 0.0)
	var nl: Vector3 = -0.5 * (rt0 + rt1)
	var nr: Vector3 = 0.5 * (rt0 + rt1)
	var vh: float = (y1 - y0) * 0.5
	_quad_uv(l1b, l1t, l0t, l0b, nl, Vector2(0.0, u1), Vector2(vh, u1), Vector2(vh, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)
	_quad_uv(r0b, r0t, r1t, r1b, nr, Vector2(0.0, u0), Vector2(vh, u0), Vector2(vh, u1), Vector2(0.0, u1), col, verts, norms, uvs, cols, idx)
	# Underside facing DOWN
	_quad_uv(r1b, l1b, l0b, r0b, Vector3.DOWN, Vector2(0.0, u1), Vector2(hw, u1), Vector2(hw, u0), Vector2(0.0, u0), col, verts, norms, uvs, cols, idx)


static func _near_lower_road(wx: float, wz: float, own_y: float, own_edge: int) -> bool:
	var runs: Array = RoadGraph.runs_in_tile(floori(wx / TILE), floori(wz / TILE))
	for r: Vector3i in runs:
		if r.x == own_edge:
			continue
		var oe: int = r.x
		var clr: float = RoadGraph.e_width[oe] * 0.5 + 3.6
		var clr2: float = clr * clr
		var pts: PackedVector3Array = RoadGraph.e_pts[oe]
		var k: int = r.y
		while k <= r.z:
			var p: Vector3 = pts[k]
			if p.y < own_y - 2.5:
				var dx: float = wx - p.x
				var dz: float = wz - p.z
				if dx * dx + dz * dz < clr2:
					return true
			k += 2
	return false


static func _add_box_faces(c: Vector3, fwd: Vector3, rt: Vector3, sz: Vector3, faces: PackedVector3Array) -> void:
	var rx: Vector3 = rt * (sz.x * 0.5)
	var ry: Vector3 = Vector3.UP * (sz.y * 0.5)
	var rz: Vector3 = fwd * (sz.z * 0.5)
	var quads: Array = [
		[c - rx - ry - rz, c - rx + ry - rz, c - rx + ry + rz, c - rx - ry + rz],
		[c + rx - ry + rz, c + rx + ry + rz, c + rx + ry - rz, c + rx - ry - rz],
		[c - rx - ry + rz, c - rx + ry + rz, c + rx + ry + rz, c + rx - ry + rz],
		[c + rx - ry - rz, c + rx + ry - rz, c - rx + ry - rz, c - rx - ry - rz],
	]
	for q: Array in quads:
		faces.append_array([q[0], q[1], q[2], q[0], q[2], q[3]])


## Builds concrete vaulted tunnel lining, portals, ceiling lights, and terrain-conforming portal wingwalls.
static func _tunnel_structure(e: int, s: int, end_i: int, _rng: Vector2i, origin: Vector3, hw: float, conc_col: Color, rock_col: Color, lamp_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var step_len: float = RoadGraph.e_step[e]
	var portals: Vector2i = _tunnel_portals(e)
	var ent_k: int = portals.x - 4
	var ex_k: int = portals.y + 4
	var t_start: int = maxi(s, ent_k)
	var t_end: int = mini(end_i, ex_k)
	if t_start >= t_end:
		return

	var steps: PackedInt32Array = []
	var k: int = t_start
	while k < t_end:
		steps.append(k)
		k += 2
	steps.append(t_end)
	if steps.size() < 2:
		return

	var wall_in: float = hw + 0.9
	var wall_out: float = hw + 1.8
	var wall_h: float = 5.4
	var roof_top: float = wall_h + 0.90

	var prev_c := Vector3.ZERO
	var prev_rt := Vector3.ZERO
	var prev_u: float = 0.0
	var has_prev: bool = false
	for si: int in steps.size():
		var ki: int = steps[si]
		var fwd: Vector3 = RoadGraph.tangent(e, ki)
		var rt: Vector3 = RoadGraph.right(e, ki)  # banked: structure follows the deck's roll (a flat slab pokes up on the low side)
		var c: Vector3 = pts[ki] - origin
		var cur_u: float = ki * step_len * 0.4
		var crossing: bool = false
		if OsmWorld.enabled and has_prev:
			for side: float in [-1.0, 1.0]:
				if crossing:
					break
				for wl: float in [wall_in, (wall_in + wall_out) * 0.5, wall_out]:
					if crossing:
						break
					for wp: Vector3 in [prev_c + prev_rt * (side * wl) + origin, c + rt * (side * wl) + origin]:
						# off every corridor, its own included (on a tight bend the inner wall folds back over the lanes)
						if corridor_edge(wp.x, wp.z, wp.y - 0.4, wp.y + wall_h, 0.1) >= 0:
							crossing = true  # the cut-and-cover box runs into a junction or beside another road: open there
							break
		if has_prev and not crossing:
			# Left and right concrete lining walls
			_add_prism_seg(prev_c - prev_rt * ((wall_in + wall_out) * 0.5), prev_rt, prev_u, c - rt * ((wall_in + wall_out) * 0.5), rt, cur_u, 0.45, -0.4, wall_h, conc_col, verts, norms, uvs, cols, idx)
			_add_prism_seg(prev_c + prev_rt * ((wall_in + wall_out) * 0.5), prev_rt, prev_u, c + rt * ((wall_in + wall_out) * 0.5), rt, cur_u, 0.45, -0.4, wall_h, conc_col, verts, norms, uvs, cols, idx)
			# Tunnel roof concrete slab (soffit + sides + top)
			_add_soffit_seg(prev_c, prev_rt, prev_u, c, rt, cur_u, wall_out, wall_h, roof_top, conc_col, verts, norms, uvs, cols, idx)
			var l0t: Vector3 = prev_c - prev_rt * wall_out + Vector3(0.0, roof_top, 0.0)
			var r0t: Vector3 = prev_c + prev_rt * wall_out + Vector3(0.0, roof_top, 0.0)
			var l1t: Vector3 = c - rt * wall_out + Vector3(0.0, roof_top, 0.0)
			var r1t: Vector3 = c + rt * wall_out + Vector3(0.0, roof_top, 0.0)
			_quad_uv(l1t, r1t, r0t, l0t, Vector3.UP, Vector2(0.0, cur_u), Vector2(wall_out * 2.0, cur_u), Vector2(wall_out * 2.0, prev_u), Vector2(0.0, prev_u), conc_col, verts, norms, uvs, cols, idx)
			# Interior wall colliders
			for side: float in [-1.0, 1.0]:
				var a0: Vector3 = prev_c + prev_rt * (side * wall_in)
				var b0: Vector3 = c + rt * (side * wall_in)
				faces.append_array([a0, b0, a0 + Vector3(0.0, 4.5, 0.0), a0 + Vector3(0.0, 4.5, 0.0), b0, b0 + Vector3(0.0, 4.5, 0.0)])

		# Always-lit warm ceiling luminaire every ~24m inside tunnel
		if ki % 6 == 3:
			_add_box(c + Vector3(0.0, wall_h - 0.12, 0.0), fwd, rt, Vector3(1.1, 0.18, 0.55), lamp_col, verts, norms, uvs, cols, idx)

		prev_c = c
		prev_rt = rt
		prev_u = cur_u
		has_prev = true

	# Monumental concrete portals + terrain-conforming rock/wingwall collars sealing doorway grid seams
	for m: int in 2:
		var p_mouth: int = ent_k if m == 0 else ex_k
		var p_rock: int = portals.x if m == 0 else portals.y
		if p_mouth < s or p_mouth > end_i:
			continue
		var fwd_p: Vector3 = RoadGraph.tangent(e, p_mouth) * (1.0 if m == 0 else -1.0)
		var rt_p: Vector3 = fwd_p.cross(Vector3.UP).normalized()
		var cm: Vector3 = pts[p_mouth] - origin
		if not (_clear(cm - rt_p * (wall_out + 1.2), origin, 1.4, cm.y, cm.y + wall_h) and _clear(cm + rt_p * (wall_out + 1.2), origin, 1.4, cm.y, cm.y + wall_h)):
			continue  # a pilaster would stand on a joining road
		# Portal headwall & pilasters
		_add_box(cm + Vector3(0.0, wall_h + 1.85, 0.0), fwd_p, rt_p, Vector3(wall_out * 2.0 + 4.8, 3.7, 2.4), conc_col, verts, norms, uvs, cols, idx)
		_add_box(cm - rt_p * (wall_out + 1.2) + Vector3(0.0, wall_h * 0.5, 0.0), fwd_p, rt_p, Vector3(2.4, wall_h + 0.4, 2.6), conc_col, verts, norms, uvs, cols, idx)
		_add_box(cm + rt_p * (wall_out + 1.2) + Vector3(0.0, wall_h * 0.5, 0.0), fwd_p, rt_p, Vector3(2.4, wall_h + 0.4, 2.6), conc_col, verts, norms, uvs, cols, idx)
		for side: float in [-1.0, 1.0]:
			_add_box(cm + rt_p * (side * wall_in) + Vector3(0.0, wall_h + 0.5, 0.0) - fwd_p * 1.22, fwd_p, rt_p, Vector3(0.45, 0.24, 0.12), lamp_col, verts, norms, uvs, cols, idx)
		if OsmWorld.enabled:
			continue  # cut-and-cover: the cutting is the terrain itself, no rock cheeks up to the uncut hillside
		# Sloped concrete-and-rock portal cheeks joining wall_out out to +-14m terrain
		var k_from: int = clampi(mini(p_mouth, p_rock) - 1, 0, pts.size() - 1)
		var k_to: int = clampi(maxi(p_mouth, p_rock) + 3, 0, pts.size() - 1)
		var rt_w: Vector3 = RoadGraph.tangent(e, p_rock).cross(Vector3.UP).normalized()
		for side: float in [-1.0, 1.0]:
			var prev_row: PackedVector3Array = []
			for kr: int in range(k_from, k_to + 1, 2):
				var pw_r: Vector3 = pts[kr]
				var t_k: float = float(kr - k_from) / maxf(float(k_to - k_from), 1.0)
				if m == 1:
					t_k = 1.0 - t_k
				var r_row := PackedVector3Array()
				for li: int in 4:
					var frac: float = float(li) / 3.0
					var lat_d: float = side * lerpf(wall_out - 0.2, 14.5, frac)
					var w_pt: Vector3 = pw_r + rt_w * lat_d
					var th: float = TerrainFn.base_height(w_pt.x, w_pt.z) - 0.25
					var hood_y: float = pw_r.y + lerpf(0.2, wall_h + 2.4, t_k)
					var pt_y: float = lerpf(hood_y, th, smoothstep(0.0, 1.0, frac))
					r_row.append(Vector3(w_pt.x - origin.x, pt_y - origin.y, w_pt.z - origin.z))
				if not prev_row.is_empty():
					for li: int in 3:
						var q00: Vector3 = prev_row[li] if side > 0.0 else prev_row[li + 1]
						var q01: Vector3 = prev_row[li + 1] if side > 0.0 else prev_row[li]
						var q10: Vector3 = r_row[li] if side > 0.0 else r_row[li + 1]
						var q11: Vector3 = r_row[li + 1] if side > 0.0 else r_row[li]
						var p_n: Vector3 = (q11 - q00).cross(q10 - q00).normalized()
						if p_n.y < 0.0:
							p_n = -p_n
						_quad_uv(q00, q10, q11, q01, p_n, Vector2(li * 1.5, 0.0), Vector2(li * 1.5, 2.0), Vector2((li + 1) * 1.5, 2.0), Vector2((li + 1) * 1.5, 0.0), rock_col, verts, norms, uvs, cols, idx)
				prev_row = r_row
