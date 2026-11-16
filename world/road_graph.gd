class_name RoadGraph
extends RefCounted
## Road network (PLAN 2.4), loaded once from data/roads/network.json. Pure static and
## immutable after load, so tile workers read it freely (hence no autoload node).
## Every edge is resampled to a dense polyline with uniform spacing (~STEP m).

enum { HIGHWAY, COUNTRY, MOUNTAIN, CITY }
const TYPE_NAMES: PackedStringArray = ["highway", "country", "mountain", "city"]
const WIDTH: PackedFloat32Array = [22.0, 7.0, 6.5, 10.0]  # paved width
const MAX_GRADE: PackedFloat32Array = [0.05, 0.08, 0.11, 0.06]
const STEP: float = 4.0
const MARGIN: float = 96.0  # index runs cover the tile grown by this (terrain stamping reach)
const TILE: float = 1024.0

static var nodes: PackedVector3Array = []
static var node_town: PackedByteArray = []
static var node_edges: Array[PackedInt32Array] = []
static var e_type: PackedInt32Array = []
static var e_a: PackedInt32Array = []
static var e_b: PackedInt32Array = []
static var e_elev: PackedByteArray = []
static var e_pts: Array[PackedVector3Array] = []  # dense polyline, world coords
static var e_step: PackedFloat32Array = []  # exact spacing of that edge's polyline
static var _index: Dictionary[Vector2i, Array] = {}  # tile -> [Vector3i(edge, first, last)]


static func _static_init() -> void:
	load_file("res://data/roads/network.json")


static func load_file(path: String) -> void:
	nodes = []
	node_town = []
	node_edges = []
	e_type = []
	e_a = []
	e_b = []
	e_elev = []
	e_pts = []
	e_step = []
	_index = {}
	if not FileAccess.file_exists(path):
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for n: Dictionary in d["nodes"]:
		nodes.append(Vector3(n["p"][0], n["p"][1], n["p"][2]))
		node_town.append(1 if n.get("town", false) else 0)
		node_edges.append(PackedInt32Array())
	for e: Dictionary in d["edges"]:
		var id: int = e_type.size()
		var ctrl := PackedVector3Array()
		for p: Array in e["pts"]:
			ctrl.append(Vector3(p[0], p[1], p[2]))
		e_type.append(TYPE_NAMES.find(e["type"]))
		e_a.append(int(e["a"]))
		e_b.append(int(e["b"]))
		e_elev.append(1 if e.get("elevated", false) else 0)
		node_edges[e_a[id]].append(id)
		node_edges[e_b[id]].append(id)
		var dense: PackedVector3Array = resample(spline(ctrl, 8), STEP)
		e_pts.append(dense)
		e_step.append(dense[0].distance_to(dense[1]))
		_index_edge(id, dense)


## Centripetal Catmull-Rom through all control points, `sub` pieces per span.
static func spline(ctrl: PackedVector3Array, sub: int) -> PackedVector3Array:
	var n: int = ctrl.size()
	var out := PackedVector3Array()
	if n < 3:
		return ctrl
	for i: int in n - 1:
		var p1: Vector3 = ctrl[i]
		var p2: Vector3 = ctrl[i + 1]
		var p0: Vector3 = ctrl[i - 1] if i > 0 else p1 * 2.0 - p2
		var p3: Vector3 = ctrl[i + 2] if i < n - 2 else p2 * 2.0 - p1
		var t1: float = sqrt(p0.distance_to(p1))
		var t2: float = t1 + sqrt(p1.distance_to(p2))
		var t3: float = t2 + sqrt(p2.distance_to(p3))
		for k: int in sub:
			var t: float = lerpf(t1, t2, float(k) / sub)
			var a1: Vector3 = p0.lerp(p1, t / t1) if t1 > 0.0 else p1
			var a2: Vector3 = p1.lerp(p2, (t - t1) / (t2 - t1))
			var a3: Vector3 = p2.lerp(p3, (t - t2) / (t3 - t2)) if t3 > t2 else p2
			var b1: Vector3 = a1.lerp(a2, t / t2)
			var b2: Vector3 = a2.lerp(a3, (t - t1) / (t3 - t1))
			out.append(b1.lerp(b2, (t - t1) / (t2 - t1)))
	out.append(ctrl[n - 1])
	return out


## Uniform arc-length resampling; first and last points are kept exactly.
static func resample(pts: PackedVector3Array, step: float) -> PackedVector3Array:
	var total: float = 0.0
	for i: int in pts.size() - 1:
		total += pts[i].distance_to(pts[i + 1])
	var count: int = maxi(roundi(total / step), 1)
	var ds: float = total / count
	var out := PackedVector3Array([pts[0]])
	var seg: int = 0
	var seg_start: float = 0.0
	var seg_len: float = pts[0].distance_to(pts[1])
	for k: int in range(1, count):
		var s: float = k * ds
		while s > seg_start + seg_len and seg < pts.size() - 2:
			seg_start += seg_len
			seg += 1
			seg_len = pts[seg].distance_to(pts[seg + 1])
		out.append(pts[seg].lerp(pts[seg + 1], (s - seg_start) / maxf(seg_len, 1e-6)))
	out.append(pts[pts.size() - 1])
	return out


static func _index_edge(id: int, dense: PackedVector3Array) -> void:
	var open: Dictionary[Vector2i, int] = {}  # tile -> first index of the current run
	for i: int in dense.size() + 1:
		var now: Dictionary[Vector2i, bool] = {}
		if i < dense.size():
			var p: Vector3 = dense[i]
			for tz: int in range(floori((p.z - MARGIN) / TILE), floori((p.z + MARGIN) / TILE) + 1):
				for tx: int in range(floori((p.x - MARGIN) / TILE), floori((p.x + MARGIN) / TILE) + 1):
					now[Vector2i(tx, tz)] = true
					if not open.has(Vector2i(tx, tz)):
						open[Vector2i(tx, tz)] = i
		for key: Vector2i in open.keys():
			if not now.has(key):
				if not _index.has(key):
					_index[key] = []
				_index[key].append(Vector3i(id, open[key], i - 1))
				open.erase(key)


## Runs of dense points inside tile (tx, tz) grown by MARGIN: [Vector3i(edge, first, last)].
static func runs_in_tile(tx: int, tz: int) -> Array:
	return _index.get(Vector2i(tx, tz), [])


static func tangent(edge: int, i: int) -> Vector3:
	var pts: PackedVector3Array = e_pts[edge]
	return (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()


static func edge_length(edge: int) -> float:
	return e_step[edge] * (e_pts[edge].size() - 1)


## Position at distance `dist` along the edge (clamped).
static func sample(edge: int, dist: float) -> Vector3:
	var pts: PackedVector3Array = e_pts[edge]
	var f: float = clampf(dist / e_step[edge], 0.0, pts.size() - 1.0)
	var i: int = mini(int(f), pts.size() - 2)
	return pts[i].lerp(pts[i + 1], f - i)


## Nearest dense point: {pos, tangent, edge, i} or {} when nothing lies within max_dist.
## Looks in the 3x3 tiles around the position first, then falls back to every edge.
static func nearest_point(w: Vector3, max_dist: float = 1e9) -> Dictionary:
	var best: float = max_dist * max_dist
	var be: int = -1
	var bi: int = 0
	var runs: Array = []
	var t := Vector2i(floori(w.x / TILE), floori(w.z / TILE))
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			runs.append_array(_index.get(t + Vector2i(dx, dz), []))
	if runs.is_empty() or max_dist > TILE:
		runs = []
		for e: int in e_pts.size():
			runs.append(Vector3i(e, 0, e_pts[e].size() - 1))
	for r: Vector3i in runs:
		var pts: PackedVector3Array = e_pts[r.x]
		for i: int in range(r.y, r.z + 1):
			var d: float = pts[i].distance_squared_to(w)
			if d < best:
				best = d
				be = r.x
				bi = i
	if be < 0:
		return {}
	return {"pos": e_pts[be][bi], "tangent": tangent(be, bi), "edge": be, "i": bi}


static func total_km() -> float:
	var m: float = 0.0
	for e: int in e_pts.size():
		m += edge_length(e)
	return m / 1000.0


static func km_by_type() -> PackedFloat32Array:
	var km := PackedFloat32Array([0, 0, 0, 0])
	for e: int in e_pts.size():
		km[e_type[e]] += edge_length(e) / 1000.0
	return km


static func self_check() -> String:
	if e_pts.is_empty():
		return "no edges loaded"
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		if pts[0].distance_to(nodes[e_a[e]]) > 0.01 or pts[pts.size() - 1].distance_to(nodes[e_b[e]]) > 0.01:
			return "edge %d does not end on its nodes" % e
		if e_type[e] < 0:
			return "edge %d has an unknown type" % e
		var max_dy: float = (MAX_GRADE[e_type[e]] + 0.01) * e_step[e]
		for i: int in pts.size() - 1:
			var d: float = pts[i].distance_to(pts[i + 1])
			if d < STEP * 0.5 or d > STEP * 1.5:
				return "edge %d spacing %f at %d" % [e, d, i]
			if absf(pts[i + 1].y - pts[i].y) > max_dy and e_elev[e] == 0:
				return "edge %d too steep at %d" % [e, i]
		# index completeness: every point is in a run of its own tile
		for i: int in range(0, pts.size(), 7):
			var found: bool = false
			for r: Vector3i in runs_in_tile(floori(pts[i].x / TILE), floori(pts[i].z / TILE)):
				found = found or (r.x == e and i >= r.y and i <= r.z)
			if not found:
				return "edge %d point %d missing from the index" % [e, i]
	var np: Dictionary = nearest_point(e_pts[0][3] + Vector3(1.0, 5.0, 1.0), 50.0)
	if np.is_empty() or np["edge"] != 0:
		return "nearest_point failed"
	if total_km() < 1.0:
		return "network too short"
	return ""
