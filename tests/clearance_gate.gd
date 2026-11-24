extends Node
## Gate (M4b): road corridor clearance. Builds the FULL tile of every road tile in each region (worker pool) and samples
## along the road splines: nothing may stand in a road's clear corridor (carriageway + shoulder, RoadMesher.clear_hw;
## city roads also keep their sidewalk free of buildings). Checks terrain above the road surface, terrain holes, scatter
## (trunk + crown), building roofs, and props (any prop vertex above the road surface). Every spawn must land on a
## carriageway lane, clear of junction pads, facing along the road. Headless; prints CLEARANCE PASS or FAIL: lines.
## Args: [--region=tokyo_hakone|monaco_alps|dubai_jais] [--max_tiles=N] (default: every road tile).

const SAMPLE_STEP: int = 2  # every 2nd 4 m spline sample
const MAX_REPORT: int = 6
const KERB_TOL: float = 0.15  # structure up to kerb height over a road surface (deck fascia, slab edges) is not an obstacle

var tiles: Array[Vector2i] = []
var results: Array = []  # per tile: [count by kind (Dictionary), examples (PackedStringArray)]
var _scatter_dims: Array[Vector2] = []  # per scatter type: (radius, height) at scale 1
var _gid: int = -1
var _tally: Dictionary = {}  # debug breakdown of prop violations (class_zone_height_kind)
var _t0: int = 0


func _ready() -> void:
	var only: String = Settings.arg_value("--region", "")
	var max_tiles: int = int(Settings.arg_value("--max_tiles", "0"))
	Scatter.ensure_resources()
	for ti: int in Scatter.TYPE_COUNT:
		var bb: AABB = Scatter.get_lod0_mesh(ti).get_aabb()
		# crown radius: the mesh's horizontal half extent (most foliage stays inside 80 % of the box)
		_scatter_dims.append(Vector2(maxf(maxf(absf(bb.position.x), absf(bb.end.x)), maxf(absf(bb.position.z), absf(bb.end.z))) * 0.8, bb.end.y))
	var per_region: Dictionary = {}
	for reg: Dictionary in OsmWorld.meta["regions"]:
		if only != "" and str(reg["id"]) != only:
			continue
		var b: Array = reg["bounds"]
		var list: Array[Vector2i] = []
		for key: Vector2i in RoadGraph._index:
			if key.x * 1024.0 + 1024.0 < float(b[0]) or key.x * 1024.0 > float(b[2]) or key.y * 1024.0 + 1024.0 < float(b[1]) or key.y * 1024.0 > float(b[3]):
				continue
			if _has_own_samples(key):
				list.append(key)
		list.sort()
		if max_tiles > 0 and list.size() > max_tiles:
			var step: float = float(list.size()) / max_tiles
			var cut: Array[Vector2i] = []
			for k: int in max_tiles:
				cut.append(list[int(k * step)])
			list = cut
		per_region[reg["id"]] = list.size()
		tiles.append_array(list)
	if Settings.arg_value("--tile", "") != "":  # debug: one tile
		var tp: PackedStringArray = Settings.arg_value("--tile", "").split(",")
		tiles = [Vector2i(int(tp[0]), int(tp[1]))]
	print("CLEARANCE tiles ", per_region)
	results.resize(tiles.size())
	_t0 = Time.get_ticks_msec()
	# workers build tiles; the main thread keeps running frames (mesh / occluder calls on workers sync with it)
	_gid = WorkerThreadPool.add_group_task(_check_tile, tiles.size(), -1, true)


func _process(_dt: float) -> void:
	if _gid < 0 or not WorkerThreadPool.is_group_task_completed(_gid):
		return
	WorkerThreadPool.wait_for_group_task_completion(_gid)
	_gid = -1
	_report()


func _report() -> void:
	var t0: int = _t0
	var total: Dictionary = {}
	var examples: PackedStringArray = []
	for r: Array in results:
		var c: Dictionary = r[0]
		c.erase("props_detail")
		for k: String in c:
			total[k] = int(total.get(k, 0)) + int(c[k])
		for s: String in r[1]:
			if examples.size() < 40:
				examples.append(s)
	var spawn_fails: PackedStringArray = _check_spawns()
	print("CLEARANCE %d tiles in %.1f s: %s" % [tiles.size(), (Time.get_ticks_msec() - t0) / 1000.0, total])
	var bad: int = 0
	for k: String in total:
		bad += int(total[k])
	for s: String in examples:
		print("  ", s)
	if Settings.has_arg("--tally"):
		var keys: Array = _tally.keys()
		keys.sort_custom(func(a: String, b: String) -> bool: return int(_tally[a]) > int(_tally[b]))
		for k: String in keys:
			print("  tally ", k, " ", _tally[k])
	for s: String in spawn_fails:
		print("FAIL: ", s)
	if bad > 0:
		print("FAIL: %d corridor violations %s" % [bad, total])
	elif spawn_fails.is_empty():
		print("CLEARANCE PASS")
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()


func _has_own_samples(key: Vector2i) -> bool:
	for r: Vector3i in RoadGraph.runs_in_tile(key.x, key.y):
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		for i: int in range(r.y, r.z + 1):
			if floori(pts[i].x / 1024.0) == key.x and floori(pts[i].z / 1024.0) == key.y:
				return true
	return false


func _check_tile(k: int) -> void:
	var t: Vector2i = tiles[k]
	var d: Dictionary = TileGen.build(t.x, t.y, TileGen.FULL)
	var cnt: Dictionary = {}
	var ex: PackedStringArray = []
	var o := Vector3(t.x * 1024.0, 0.0, t.y * 1024.0)
	var ms := PackedInt32Array([Time.get_ticks_msec()])
	_terrain(d, t, o, cnt, ex)
	ms.append(Time.get_ticks_msec())
	_scatter(d, o, cnt, ex)
	ms.append(Time.get_ticks_msec())
	_props(d, o, cnt, ex)
	ms.append(Time.get_ticks_msec())
	_buildings(d, t, o, cnt, ex)
	ms.append(Time.get_ticks_msec())
	if Settings.has_arg("--timing"):
		print("tile %s build %.0f ms, terrain %d scatter %d props %d buildings %d ms" % [t, d["ms"], ms[1] - ms[0], ms[2] - ms[1], ms[3] - ms[2], ms[4] - ms[3]])
	results[k] = [cnt, ex]


func _bump(cnt: Dictionary, ex: PackedStringArray, kind: String, msg: String) -> void:
	cnt[kind] = int(cnt.get(kind, 0)) + 1
	if int(cnt[kind]) <= 2 and ex.size() < MAX_REPORT:
		ex.append("%s %s" % [kind, msg])


## Terrain mesh height at tile-local (x, z), on the same triangles as the mesh (diagonal (i+1, j) -> (i, j+1)).
static func _terrain_y(verts: PackedVector3Array, x: float, z: float) -> float:
	var n: int = TileGen.GRID[TileGen.FULL]
	var cell: float = TileGen.TILE / (n - 1)
	var fx: float = clampf(x / cell, 0.0, n - 1.001)
	var fz: float = clampf(z / cell, 0.0, n - 1.001)
	var i: int = int(fx)
	var j: int = int(fz)
	fx -= i
	fz -= j
	var ha: float = verts[j * n + i].y
	var hb: float = verts[j * n + i + 1].y
	var hc: float = verts[(j + 1) * n + i].y
	var hd: float = verts[(j + 1) * n + i + 1].y
	if fx + fz <= 1.0:
		return ha + (hb - ha) * fx + (hc - ha) * fz
	return hd + (hc - hd) * (1.0 - fx) + (hb - hd) * (1.0 - fz)


## Own road samples of this tile, every SAMPLE_STEP: [edge, i, point].
static func _samples(t: Vector2i) -> Array:
	var out: Array = []
	for r: Vector3i in RoadGraph.runs_in_tile(t.x, t.y):
		var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
		for i: int in range(r.y, r.z + 1, SAMPLE_STEP):
			var p: Vector3 = pts[i]
			var lx: float = p.x - t.x * 1024.0
			var lz: float = p.z - t.y * 1024.0
			if lx >= 1.0 and lx <= 1023.0 and lz >= 1.0 and lz <= 1023.0:
				out.append([r.x, i, p])
	return out


func _terrain(d: Dictionary, t: Vector2i, o: Vector3, cnt: Dictionary, ex: PackedStringArray) -> void:
	var hm: PackedFloat32Array = d.get("hm", PackedFloat32Array())
	for v: float in hm:
		if is_nan(v):
			_bump(cnt, ex, "terrain_hole", "in tile %s" % t)
			break
	var verts: PackedVector3Array = d["verts"]
	for s: Array in _samples(t):
		var e: int = s[0]
		var i: int = s[1]
		var p: Vector3 = s[2]
		var rt: Vector3 = RoadGraph.tangent(e, i).cross(Vector3.UP).normalized()
		var sb: float = sin(RoadGraph.bank(e, i))
		var c: float = RoadMesher.clear_hw(e) - 0.1
		for f: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var q: Vector3 = p + rt * (c * f)
			if q.x < o.x or q.x > o.x + 1024.0 or q.z < o.z or q.z > o.z + 1024.0:
				continue  # the neighbouring tile checks it
			var ry: float = p.y + c * f * sb
			var ty: float = _terrain_y(verts, q.x - o.x, q.z - o.z)
			# another road's surface may legitimately be here (junction pad, parallel ramp): only the lowest road counts
			if ty > ry and RoadMesher.corridor_edge(q.x, q.z, ry - 30.0, ry - 0.5, 0.0, false, e) < 0:
				_bump(cnt, ex, "terrain", "%.1f m over edge %d (%s) at %s" % [ty - ry, e, RoadGraph.TYPE_NAMES[RoadGraph.e_type[e]], q.snapped(Vector3.ONE * 0.1)])
				break


func _scatter(d: Dictionary, o: Vector3, cnt: Dictionary, ex: PackedStringArray) -> void:
	for ch: Dictionary in d.get("scatter", []):
		var bufs: Array = ch["bufs"]
		var cp: Vector3 = ch["pos"]
		for ti: int in Scatter.TYPE_COUNT:
			var buf: PackedFloat32Array = bufs[ti]
			for b: int in range(0, buf.size(), 16):
				var sc: float = Vector2(buf[b], buf[b + 2]).length()
				var w := Vector3(buf[b + 3], buf[b + 7], buf[b + 11]) + cp + o
				var dim: Vector2 = _scatter_dims[ti] * sc
				var e: int = RoadMesher.corridor_edge(w.x, w.z, w.y, w.y + dim.y, dim.x)
				if e >= 0:
					_bump(cnt, ex, "scatter", "type %d (r %.1f) in edge %d (%s) at %s" % [ti, dim.x, e, RoadGraph.TYPE_NAMES[RoadGraph.e_type[e]], w.snapped(Vector3.ONE * 0.1)])


func _props(d: Dictionary, o: Vector3, cnt: Dictionary, ex: PackedStringArray) -> void:
	if not d.has("props"):
		return
	# Props are emitted as quads (RoadMesher._quad_uv): each is probed with RoadMesher.quad_hit (centre, corners and edge
	# midpoints at their own height, vertical edges over their whole span) against every road's clear envelope.
	var pv: PackedVector3Array = (d["props"] as Dictionary)["verts"]
	var pc: PackedColorArray = (d["props"] as Dictionary)["cols"]
	var seen: Dictionary[Vector3i, bool] = {}
	for q0: int in range(0, pv.size() - 3, 4):
		var hit: Array = RoadMesher.quad_hit(pv[q0] + o, pv[q0 + 1] + o, pv[q0 + 2] + o, pv[q0 + 3] + o)
		if hit.is_empty():
			continue
		var e: int = hit[0]
		var w: Vector3 = hit[1]
		var ry: float = _surface_y(e, w)
		var key := Vector3i(floori(w.x / 4.0), floori(ry / 4.0), floori(w.z / 4.0))
		if seen.has(key):
			continue
		seen[key] = true
		var np: Dictionary = RoadGraph.nearest_point(Vector3(w.x, ry, w.z), 64.0)
		var lat: float = 0.0
		if not np.is_empty() and int(np["edge"]) == e:
			var rt: Vector3 = (np["tangent"] as Vector3).cross(Vector3.UP).normalized()
			lat = (w - (np["pos"] as Vector3)).dot(rt)
		var cls: float = pc[q0].a
		var zone: String = "centre" if absf(lat) < 0.6 else ("edge" if absf(lat) > RoadMesher.clear_hw(e) - 0.6 else "lane")
		var tk: String = "%.2f_%s_%s_%s" % [cls, zone, "over" if w.y - ry > 2.0 else "low", RoadGraph.KIND_NAMES[RoadGraph.e_kind[e]]]
		_tally[tk] = int(_tally.get(tk, 0)) + 1
		_bump(cnt, ex, "props", "%.2f m (class %.2f) lat %.2f of clear %.2f, edge %d (%s %s) at %s" % [w.y - ry, cls, lat, RoadMesher.clear_hw(e), e, RoadGraph.TYPE_NAMES[RoadGraph.e_type[e]], RoadGraph.KIND_NAMES[RoadGraph.e_kind[e]], w.snapped(Vector3.ONE * 0.1)])


## Road surface height of edge e under world point w (nearest segment, banked).
static func _surface_y(e: int, w: Vector3) -> float:
	var pts: PackedVector3Array = RoadGraph.e_pts[e]
	var best: float = 1e18
	var y: float = pts[0].y
	for i: int in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var t: float = clampf(Vector2(w.x - a.x, w.z - a.z).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var q := Vector2(a.x + ab.x * t, a.z + ab.y * t)
		var dd: float = q.distance_squared_to(Vector2(w.x, w.z))
		if dd < best:
			best = dd
			var rt: Vector3 = RoadGraph.tangent(e, i).cross(Vector3.UP).normalized()
			var lat: float = Vector2(w.x - q.x, w.z - q.y).dot(Vector2(rt.x, rt.z))
			y = lerpf(a.y, b.y, t) + lat * sin(RoadGraph.bank(e, i))
	return y


func _buildings(d: Dictionary, t: Vector2i, o: Vector3, cnt: Dictionary, ex: PackedStringArray) -> void:
	if not d.has("city"):
		return
	# roof triangles in an 8 m grid (tile-local)
	var grid: Dictionary[Vector2i, PackedVector3Array] = {}
	for ch: Dictionary in d["city"]:
		var arr: Array = ch["lod0"]
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for k: int in range(0, idx.size(), 3):
			if nr[idx[k]].y < 0.9:
				continue
			var a: Vector3 = v[idx[k]]
			var b: Vector3 = v[idx[k + 1]]
			var c: Vector3 = v[idx[k + 2]]
			for gz: int in range(floori(minf(a.z, minf(b.z, c.z)) / 8.0), floori(maxf(a.z, maxf(b.z, c.z)) / 8.0) + 1):
				for gx: int in range(floori(minf(a.x, minf(b.x, c.x)) / 8.0), floori(maxf(a.x, maxf(b.x, c.x)) / 8.0) + 1):
					var key := Vector2i(gx, gz)
					if not grid.has(key):
						grid[key] = PackedVector3Array()
					grid[key].append_array([a, b, c])
	if grid.is_empty():
		return
	for s: Array in _samples(t):
		var e: int = s[0]
		var i: int = s[1]
		var p: Vector3 = s[2]
		var rt: Vector3 = RoadGraph.tangent(e, i).cross(Vector3.UP).normalized()
		var c: float = RoadMesher.clear_hw(e) + (RoadMesher.SIDEWALK if RoadGraph.e_type[e] == RoadGraph.CITY else 0.0) - 0.1
		for f: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var q: Vector3 = p + rt * (c * f) - o
			var tris: PackedVector3Array = grid.get(Vector2i(floori(q.x / 8.0), floori(q.z / 8.0)), PackedVector3Array())
			var hit: bool = false
			for k: int in range(0, tris.size(), 3):
				if tris[k].y > p.y - 1.0 and Geometry2D.point_is_inside_triangle(Vector2(q.x, q.z), Vector2(tris[k].x, tris[k].z), Vector2(tris[k + 1].x, tris[k + 1].z), Vector2(tris[k + 2].x, tris[k + 2].z)):
					hit = true
					break
			if hit:
				_bump(cnt, ex, "building", "over edge %d (%s) at %s" % [e, RoadGraph.TYPE_NAMES[RoadGraph.e_type[e]], (q + o).snapped(Vector3.ONE * 0.1)])
				break


## Every meta spawn and the FPS-gate spawns: on a carriageway lane of a real edge, clear of the junction pads.
func _check_spawns() -> PackedStringArray:
	var out: PackedStringArray = []
	var list: Array = []
	for sp: Dictionary in OsmWorld.meta["spawns"]:
		var p: Array = sp["pos"]
		list.append([str(sp["id"]), Vector3(float(p[0]), float(p[1]), float(p[2])), 1.0])
	list.append(["fps_tokyo", Vector3(9777.0, 18.6, -1692.0), -1.0])
	list.append(["fps_monaco", Vector3(-8057.4, 36.4, 241.2), 1.0])
	list.append(["fps_dubai", Vector3(-553.0, 6.1, 5500.0), -1.0])
	for it: Array in list:
		var pose: Dictionary = RoadMesher.spawn_pose(it[1], it[2])
		if pose.is_empty():
			out.append("spawn %s: no road" % it[0])
			continue
		var e: int = pose["edge"]
		var i: int = pose["i"]
		var pos: Vector3 = pose["pos"]
		var fwd: Vector3 = pose["fwd"]
		var rng: Vector2i = RoadMesher.edge_range(e)
		var lat: float = (pos - RoadGraph.e_pts[e][i]).dot(RoadGraph.tangent(e, i).cross(Vector3.UP).normalized())
		var hw: float = RoadGraph.e_width[e] * 0.5
		if absf(lat) > hw - 1.2:
			out.append("spawn %s: %.1f m off centre of a %.1f m road (not on the carriageway)" % [it[0], lat, hw * 2.0])
		if i < rng.x + 2 or i > rng.y - 2:
			out.append("spawn %s: inside a junction pad (edge %d i %d, strip %s)" % [it[0], e, i, rng])
		if absf(fwd.normalized().dot(RoadGraph.tangent(e, i))) < 0.98:
			out.append("spawn %s: not facing along the road" % it[0])
		var other: int = RoadMesher.corridor_edge(pos.x, pos.z, pos.y, pos.y + 1.2, 0.0, true, e)
		if other >= 0 and RoadGraph.e_type[other] == RoadGraph.CITY and RoadMesher.corridor_edge(pos.x, pos.z, pos.y, pos.y + 1.2, -RoadMesher.KERB_W, false, e) < 0:
			out.append("spawn %s: on the sidewalk of edge %d" % [it[0], other])
	return out
