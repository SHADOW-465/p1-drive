class_name RoadMesher
extends RefCounted
## Worker-side road builders (PLAN 2.5): terrain conform stamping, road mesh (+ junction pads),
## collider faces. Reads only RoadGraph. Mesh format: see shaders/road.gdshader.

const OFF: float = 0.35  # terrain sits this far below the road surface
const VERGE_W: float = 2.5
const VERGE_DROP: float = 0.6
const SIDEWALK: float = 2.5
const KERB: float = 0.15
const MID_LIFT: float = 1.0  # MID ribbons float above the coarse terrain
const TILE: float = 1024.0
const DIRT: Color = Color(0.13, 0.11, 0.06)  # linear; verge/cut tint on the terrain

static var _profiles: Array[PackedFloat32Array] = []  # per type: strips of [x0, y0, x1, y1, class]


static func _static_init() -> void:
	for type: int in 4:
		var hw: float = RoadGraph.WIDTH[type] * 0.5
		var p := PackedFloat32Array()
		if type == RoadGraph.CITY:
			var o: float = hw + SIDEWALK
			p.append_array([-o - VERGE_W, KERB - VERGE_DROP, -o, KERB, 1.0, -o, KERB, -hw, KERB, 0.5, -hw, KERB, -hw, 0.0, 0.5])
			p.append_array([-hw, 0.0, hw, 0.0, 0.0])
			p.append_array([hw, 0.0, hw, KERB, 0.5, hw, KERB, o, KERB, 0.5, o, KERB, o + VERGE_W, KERB - VERGE_DROP, 1.0])
		else:
			p.append_array([-hw - VERGE_W, -VERGE_DROP, -hw, 0.0, 1.0, -hw, 0.0, hw, 0.0, 0.0, hw, 0.0, hw + VERGE_W, -VERGE_DROP, 1.0])
		_profiles.append(p)


## Half width of everything the terrain must stay under (paved + sidewalks).
static func half_width(type: int) -> float:
	return RoadGraph.WIDTH[type] * 0.5 + (SIDEWALK if type == RoadGraph.CITY else 0.0)


## Roads stop this far from a node; the junction pad fills the gap. 0 at dead ends.
static func node_cut(node: int) -> float:
	var ids: PackedInt32Array = RoadGraph.node_edges[node]
	if ids.size() < 2:
		return 0.0
	var hw: float = 0.0
	for e: int in ids:
		hw = maxf(hw, RoadGraph.WIDTH[RoadGraph.e_type[e]] * 0.5)
	return 1.6 * hw + 3.0


## First and last cross-section index of an edge's road strip.
static func edge_range(e: int) -> Vector2i:
	var n: int = RoadGraph.e_pts[e].size()
	var a: int = ceili(node_cut(RoadGraph.e_a[e]) / RoadGraph.e_step[e])
	var b: int = n - 1 - ceili(node_cut(RoadGraph.e_b[e]) / RoadGraph.e_step[e])
	if a >= b:
		a = (n - 1) / 2
		b = a
	return Vector2i(a, b)


## Conforms the (n+2)^2 margin grid to the roads: bench under the road, smooth blend back.
static func stamp(tx: int, tz: int, n: int, lod: int, h: PackedFloat32Array, cols: PackedColorArray) -> PackedFloat32Array:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return PackedFloat32Array()
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var ox: float = tx * TILE - cell
	var oz: float = tz * TILE - cell
	var full: bool = lod == TileGen.FULL
	var stride: int = 2 if full else 8
	var best := PackedFloat32Array()  # distance beyond the bench edge, per vertex
	best.resize(m * m)
	best.fill(1e9)
	var bw := PackedFloat32Array()
	bw.resize(m * m)
	var ry := PackedFloat32Array()
	ry.resize(m * m)
	for r: Vector3i in runs:
		if RoadGraph.e_elev[r.x] == 1:
			continue
		var type: int = RoadGraph.e_type[r.x]
		var bench: float = half_width(type) + (12.0 if full else 45.0)
		var blend: float = (14.0 if type == RoadGraph.MOUNTAIN else 30.0) if full else 45.0
		var reach: float = bench + blend
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		var i: int = (r.y / stride) * stride
		while i < r.z:
			var i2: int = mini(i + stride, pts.size() - 1)
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i2]
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
					var dd: float = sqrt(dx * dx + dz * dz) - bench
					var q: int = gz * m + gx
					if dd < best[q] and dd < blend:
						best[q] = dd
						bw[q] = 1.0 - smoothstep(0.0, blend, dd)
						ry[q] = a.y + (b.y - a.y) * t
	for q: int in m * m:
		var w: float = bw[q]
		if w > 0.0:
			h[q] = lerpf(h[q], ry[q] - OFF, w)
			var c: Color = cols[q]
			var k: float = w * 0.5 * (1.0 - c.a)
			cols[q] = Color(lerpf(c.r, DIRT.r, k), lerpf(c.g, DIRT.g, k), lerpf(c.b, DIRT.b, k), c.a)
	return bw


## Road mesh arrays into d["road"] (tile-local) and, for FULL, collider faces into d["road_faces"].
static func mesh(d: Dictionary, tx: int, tz: int, lod: int) -> void:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return
	var origin := Vector3(tx * TILE, 0.0, tz * TILE)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for r: Vector3i in runs:
		var e: int = r.x
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		if lod != TileGen.FULL:
			_ribbon(e, r, origin, verts, uvs, cols, idx)
			continue
		var rng: Vector2i = edge_range(e)
		var i: int = maxi(r.y, rng.x)
		var end: int = mini(r.z, rng.y - 1)  # last segment index
		while i <= end:
			if not _in_tile(pts[i], tx, tz):
				i += 1
				continue
			var s: int = i
			while i <= end and _in_tile(pts[i], tx, tz):
				i += 1
			_strip(e, s, i, origin, verts, uvs, cols, idx)
	if lod == TileGen.FULL:
		for node: int in RoadGraph.nodes.size():
			if _in_tile(RoadGraph.nodes[node], tx, tz) and RoadGraph.node_edges[node].size() >= 2:
				_pad(node, origin, verts, uvs, cols, idx)
	if verts.is_empty():
		return
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.UP)
	d["road"] = {"verts": verts, "norms": norms, "uvs": uvs, "cols": cols, "idx": idx}
	if lod == TileGen.FULL:
		var faces := PackedVector3Array()
		faces.resize(idx.size())
		for k: int in idx.size():
			faces[k] = verts[idx[k]]
		d["road_faces"] = faces


static func _in_tile(p: Vector3, tx: int, tz: int) -> bool:
	return floori(p.x / TILE) == tx and floori(p.z / TILE) == tz


static func _vcol(type: int, cls: float) -> Color:
	return Color(type / 4.0, RoadGraph.WIDTH[type] / 32.0, cls)


## Cross-sections s..e (inclusive) of edge `edge`, one quad strip per profile strip.
static func _strip(edge: int, s: int, e: int, origin: Vector3, verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var type: int = RoadGraph.e_type[edge]
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var step: float = RoadGraph.e_step[edge]
	var prof: PackedFloat32Array = _profiles[type]
	var rights := PackedVector3Array()
	for i: int in range(s, e + 1):
		rights.append(RoadGraph.tangent(edge, i).cross(Vector3.UP).normalized())
	for k: int in range(0, prof.size(), 5):
		var base: int = verts.size()
		var c: Color = _vcol(type, prof[k + 4])
		for i: int in range(s, e + 1):
			var p: Vector3 = pts[i] - origin
			var rt: Vector3 = rights[i - s]
			verts.append(p + rt * prof[k] + Vector3(0.0, prof[k + 1], 0.0))
			verts.append(p + rt * prof[k + 2] + Vector3(0.0, prof[k + 3], 0.0))
			uvs.append(Vector2(prof[k], i * step))
			uvs.append(Vector2(prof[k + 2], i * step))
			cols.append(c)
			cols.append(c)
			if i > s:
				var b: int = base + (i - s) * 2
				idx.append_array([b - 2, b, b - 1, b - 1, b, b + 1])


## MID LOD: flat paved ribbon, one quad per 8 points, owned by the tile of its first point.
static func _ribbon(edge: int, r: Vector3i, origin: Vector3, verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var type: int = RoadGraph.e_type[edge]
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var hw: float = RoadGraph.WIDTH[type] * 0.5
	var c: Color = _vcol(type, 0.0)
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
				uvs.append(Vector2(-hw, j * RoadGraph.e_step[edge]))
				uvs.append(Vector2(hw, j * RoadGraph.e_step[edge]))
				cols.append(c)
				cols.append(c)
			idx.append_array([b, b + 2, b + 1, b + 1, b + 2, b + 3])
		i = i2


## Junction pad: triangle fan from the node to the paved end corners of every incident road,
## plus a verge skirt along the open rim.
static func _pad(node: int, origin: Vector3, verts: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var centre: Vector3 = RoadGraph.nodes[node]
	var rim: Array[Vector4] = []  # x, y, z, owning edge
	for e: int in RoadGraph.node_edges[node]:
		var rng: Vector2i = edge_range(e)
		var i: int = rng.x if RoadGraph.e_a[e] == node else rng.y
		var p: Vector3 = RoadGraph.e_pts[e][i]
		var rt: Vector3 = RoadGraph.tangent(e, i).cross(Vector3.UP).normalized() * RoadGraph.WIDTH[RoadGraph.e_type[e]] * 0.5
		rim.append(Vector4(p.x - rt.x, p.y, p.z - rt.z, e))
		rim.append(Vector4(p.x + rt.x, p.y, p.z + rt.z, e))
	rim.sort_custom(func(a: Vector4, b: Vector4) -> bool: return atan2(a.z - centre.z, a.x - centre.x) < atan2(b.z - centre.z, b.x - centre.x))
	var base: int = verts.size()
	var asphalt: Color = _vcol(RoadGraph.CITY, 0.0)
	var verge: Color = _vcol(RoadGraph.CITY, 1.0)
	verts.append(centre - origin)
	uvs.append(Vector2(100.0, 0.0))  # far from every marking
	cols.append(asphalt)
	var n: int = rim.size()
	for k: int in n:
		var p := Vector3(rim[k].x, rim[k].y, rim[k].z)
		var out: Vector3 = (p - centre) * Vector3(1.0, 0.0, 1.0)
		verts.append(p - origin)
		verts.append(p - origin)
		verts.append(p - origin + out.normalized() * VERGE_W - Vector3(0.0, VERGE_DROP, 0.0))
		uvs.append_array([Vector2(100.0, 0.0), Vector2(100.0, 0.0), Vector2(100.0, 0.0)])
		cols.append_array([asphalt, verge, verge])
	for k: int in n:
		var a: int = base + 1 + k * 3
		var b: int = base + 1 + ((k + 1) % n) * 3
		idx.append_array([base, a, b])
		if rim[k].w != rim[(k + 1) % n].w:
			idx.append_array([b + 1, a + 1, a + 2, b + 1, a + 2, b + 2])


## Road props for FULL tiles (T18): guardrails (+ collision strips) and streetlights (+ glow quads).
static func props(d: Dictionary, tx: int, tz: int) -> void:
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if runs.is_empty():
		return
	var origin := Vector3(tx * TILE, 0.0, tz * TILE)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var g_verts := PackedVector3Array()
	var g_norms := PackedVector3Array()
	var g_uvs := PackedVector2Array()
	var g_cols := PackedColorArray()
	var g_idx := PackedInt32Array()
	var faces := PackedVector3Array()
	var rail_col := Color(0.56, 0.58, 0.62, 0.0).srgb_to_linear()
	var post_col := Color(0.28, 0.30, 0.33, 0.0).srgb_to_linear()
	var median_col := Color(0.45, 0.46, 0.48, 0.0).srgb_to_linear()
	var pole_col := Color(0.22, 0.24, 0.27, 0.0).srgb_to_linear()
	var lamp_col := Color(1.0, 0.86, 0.62, 1.0)  # alpha > 0.5 => emissive in props.gdshader
	var glow_col := Color(1.0, 0.84, 0.56, 1.0)
	for r: Vector3i in runs:
		var e: int = r.x
		var type: int = RoadGraph.e_type[e]
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var rng: Vector2i = edge_range(e)
		var i: int = maxi(r.y, rng.x)
		var end: int = mini(r.z, rng.y - 1)
		var hw: float = RoadGraph.WIDTH[type] * 0.5
		while i <= end:
			if not _in_tile(pts[i], tx, tz):
				i += 1
				continue
			var s: int = i
			while i <= end and _in_tile(pts[i], tx, tz):
				i += 1
			# Guardrails
			if type == RoadGraph.HIGHWAY:
				_rail_strip(e, s, i, origin, -(hw + 0.35), 0.07, 0.42, 0.78, rail_col, post_col, true, verts, norms, cols, idx, faces)
				_rail_strip(e, s, i, origin, hw + 0.35, 0.07, 0.42, 0.78, rail_col, post_col, true, verts, norms, cols, idx, faces)
				_rail_strip(e, s, i, origin, 0.0, 0.24, 0.0, 0.76, median_col, median_col, false, verts, norms, cols, idx, faces)
			elif type == RoadGraph.COUNTRY or type == RoadGraph.MOUNTAIN:
				_conditional_rails(e, s, i, origin, type, hw, rail_col, post_col, verts, norms, cols, idx, faces)
			# Streetlights
			if type == RoadGraph.CITY:
				for k: int in range(s, i):
					if k % 7 == 0:
						var side: float = -1.0 if ((k / 7) % 2 == 0) else 1.0
						var p: Vector3 = pts[k] - origin
						var fwd: Vector3 = RoadGraph.tangent(e, k)
						var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
						_add_lamp(p + rt * (side * (hw + 0.6)), fwd, rt * (-side), 6.2, 1.5, pole_col, lamp_col, glow_col, verts, norms, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx)
			elif type == RoadGraph.HIGHWAY:
				var na: Vector3 = RoadGraph.nodes[RoadGraph.e_a[e]]
				var nb: Vector3 = RoadGraph.nodes[RoadGraph.e_b[e]]
				for k: int in range(s, i):
					if k % 12 == 0:
						var pw: Vector3 = pts[k]
						var near_node: bool = pw.distance_squared_to(na) < 22500.0 or pw.distance_squared_to(nb) < 22500.0
						var near_city: bool = TerrainFn.biome_weights(pw.x, pw.z)[TerrainFn.CITY] > 0.15
						if near_node or near_city:
							var p: Vector3 = pw - origin
							var fwd: Vector3 = RoadGraph.tangent(e, k)
							var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
							_add_twin_lamp(p, fwd, rt, 7.2, 1.6, pole_col, lamp_col, glow_col, verts, norms, cols, idx, g_verts, g_norms, g_uvs, g_cols, g_idx)
	if not verts.is_empty():
		var props_d: Dictionary = {"verts": verts, "norms": norms, "cols": cols, "idx": idx}
		if not g_verts.is_empty():
			props_d["glow"] = {"verts": g_verts, "norms": g_norms, "uvs": g_uvs, "cols": g_cols, "idx": g_idx}
		d["props"] = props_d
	if not faces.is_empty():
		d["prop_faces"] = faces


static func _conditional_rails(e: int, s: int, end_i: int, origin: Vector3, type: int, hw: float, rail_col: Color, post_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	for side: int in [-1, 1]:
		var run_start: int = -1
		for k: int in range(s, end_i + 1, 2):
			var ki: int = mini(k, end_i)
			var p: Vector3 = pts[ki]
			var rt: Vector3 = RoadGraph.tangent(e, ki).cross(Vector3.UP).normalized()
			var sp_l: Vector3 = p - rt * (hw + 6.0)
			var sp_r: Vector3 = p + rt * (hw + 6.0)
			var hl: float = TerrainFn.base_height(sp_l.x, sp_l.z)
			var hr: float = TerrainFn.base_height(sp_r.x, sp_r.z)
			var need: bool = false
			if type == RoadGraph.COUNTRY:
				var h_side: float = hl if side < 0 else hr
				need = (p.y - h_side) > 3.0
			else:  # MOUNTAIN: downhill side
				var h_side: float = hl if side < 0 else hr
				var h_other: float = hr if side < 0 else hl
				need = (h_side < h_other - 0.5) and (p.y - h_side > 1.0)
			if need:
				if run_start < 0:
					run_start = ki
			elif run_start >= 0:
				if ki - run_start >= 2:
					_rail_strip(e, run_start, ki, origin, side * (hw + 0.35), 0.07, 0.42, 0.78, rail_col, post_col, true, verts, norms, cols, idx, faces)
				run_start = -1
		if run_start >= 0 and end_i - run_start >= 2:
			_rail_strip(e, run_start, end_i, origin, side * (hw + 0.35), 0.07, 0.42, 0.78, rail_col, post_col, true, verts, norms, cols, idx, faces)


static func _rail_strip(e: int, s: int, end_i: int, origin: Vector3, lat: float, half_w: float, y0: float, y1: float, col: Color, post_col: Color, with_posts: bool, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, faces: PackedVector3Array) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var steps: PackedInt32Array = []
	var k: int = s
	while k < end_i:
		steps.append(k)
		k += 2
	steps.append(end_i)
	var prev_c := Vector3.ZERO
	var prev_rt := Vector3.ZERO
	var has_prev: bool = false
	for si: int in steps.size():
		var ki: int = steps[si]
		var fwd: Vector3 = RoadGraph.tangent(e, ki)
		var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
		var c: Vector3 = pts[ki] - origin + rt * lat
		if has_prev:
			_add_prism_seg(prev_c, prev_rt, c, rt, half_w, y0, y1, col, verts, norms, cols, idx)
			# Vertical collision strip from ground to 0.95m (backface_collision = true on shape)
			var a0: Vector3 = prev_c
			var a1: Vector3 = prev_c + Vector3(0.0, 0.95, 0.0)
			var b0: Vector3 = c
			var b1: Vector3 = c + Vector3(0.0, 0.95, 0.0)
			faces.append_array([a0, b0, a1, a1, b0, b1])
		if with_posts and si % 2 == 0:
			_add_box(c + Vector3(0.0, y1 * 0.5, 0.0), fwd, rt, Vector3(0.11, y1, 0.11), post_col, verts, norms, cols, idx)
		prev_c = c
		prev_rt = rt
		has_prev = true


static func _add_prism_seg(c0: Vector3, rt0: Vector3, c1: Vector3, rt1: Vector3, hw: float, y0: float, y1: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
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
	_quad(l0b, l0t, l1t, l1b, nl, col, verts, norms, cols, idx)
	_quad(l0t, r0t, r1t, l1t, Vector3.UP, col, verts, norms, cols, idx)
	_quad(r0t, r0b, r1b, r1t, nr, col, verts, norms, cols, idx)


static func _add_lamp(base: Vector3, fwd: Vector3, inward: Vector3, h: float, reach: float, pole_col: Color, lamp_col: Color, glow_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, g_verts: PackedVector3Array, g_norms: PackedVector3Array, g_uvs: PackedVector2Array, g_cols: PackedColorArray, g_idx: PackedInt32Array) -> void:
	_add_box(base + Vector3(0.0, h * 0.5, 0.0), fwd, inward, Vector3(0.14, h, 0.14), pole_col, verts, norms, cols, idx)
	_add_box(base + Vector3(0.0, h - 0.08, 0.0) + inward * (reach * 0.5), fwd, inward, Vector3(reach, 0.10, 0.12), pole_col, verts, norms, cols, idx)
	var head_c: Vector3 = base + Vector3(0.0, h - 0.14, 0.0) + inward * reach
	_add_box(head_c, fwd, inward, Vector3(0.45, 0.10, 0.24), lamp_col, verts, norms, cols, idx)
	_add_glow_quad(base + inward * reach + Vector3(0.0, 0.04, 0.0), fwd, inward, 5.2, glow_col, g_verts, g_norms, g_uvs, g_cols, g_idx)


static func _add_twin_lamp(base: Vector3, fwd: Vector3, rt: Vector3, h: float, reach: float, pole_col: Color, lamp_col: Color, glow_col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, g_verts: PackedVector3Array, g_norms: PackedVector3Array, g_uvs: PackedVector2Array, g_cols: PackedColorArray, g_idx: PackedInt32Array) -> void:
	_add_box(base + Vector3(0.0, h * 0.5, 0.0), fwd, rt, Vector3(0.16, h, 0.16), pole_col, verts, norms, cols, idx)
	_add_box(base + Vector3(0.0, h - 0.08, 0.0), fwd, rt, Vector3(reach * 2.0, 0.11, 0.13), pole_col, verts, norms, cols, idx)
	for s: float in [-1.0, 1.0]:
		_add_box(base + Vector3(0.0, h - 0.15, 0.0) + rt * (s * reach), fwd, rt, Vector3(0.48, 0.10, 0.26), lamp_col, verts, norms, cols, idx)
		_add_glow_quad(base + rt * (s * reach) + Vector3(0.0, 0.04, 0.0), fwd, rt, 6.0, glow_col, g_verts, g_norms, g_uvs, g_cols, g_idx)


static func _add_glow_quad(c: Vector3, fwd: Vector3, rt: Vector3, half_sz: float, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var b: int = verts.size()
	verts.append_array([c - rt * half_sz - fwd * half_sz, c + rt * half_sz - fwd * half_sz, c + rt * half_sz + fwd * half_sz, c - rt * half_sz + fwd * half_sz])
	norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	uvs.append_array([Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	cols.append_array([col, col, col, col])
	idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])


static func _add_box(c: Vector3, fwd: Vector3, rt: Vector3, sz: Vector3, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var rx: Vector3 = rt * (sz.x * 0.5)
	var ry: Vector3 = Vector3.UP * (sz.y * 0.5)
	var rz: Vector3 = fwd * (sz.z * 0.5)
	_quad(c - rx - ry - rz, c - rx + ry - rz, c - rx + ry + rz, c - rx - ry + rz, -rt, col, verts, norms, cols, idx)
	_quad(c + rx - ry + rz, c + rx + ry + rz, c + rx + ry - rz, c + rx - ry - rz, rt, col, verts, norms, cols, idx)
	_quad(c - rx - ry + rz, c - rx + ry + rz, c + rx + ry + rz, c + rx - ry + rz, fwd, col, verts, norms, cols, idx)
	_quad(c + rx - ry - rz, c + rx + ry - rz, c - rx + ry - rz, c - rx - ry - rz, -fwd, col, verts, norms, cols, idx)
	_quad(c - rx + ry - rz, c + rx + ry - rz, c + rx + ry + rz, c - rx + ry + rz, Vector3.UP, col, verts, norms, cols, idx)


static func _quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, col: Color, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array) -> void:
	var b: int = verts.size()
	verts.append_array([p0, p1, p2, p3])
	norms.append_array([n, n, n, n])
	cols.append_array([col, col, col, col])
	idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
