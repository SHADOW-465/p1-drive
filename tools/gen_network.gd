extends SceneTree
## Builds data/roads/network.json from routes/towns in data/world_def.json + data/hero/*.json (T25).
## Run: godot --headless --path . -s res://tools/gen_network.gd

const CTRL: float = 40.0  # control point spacing
const SUB: int = 64
const SNAP_DIST: float = 4.0

var nodes: Array[Dictionary] = []
var edges: Array[Dictionary] = []
var _pinned_y: Dictionary[int, float] = {}  # node id -> fixed hero y
var bad: int = 0


func _init() -> void:
	var hero_files: Array[String] = _list_hero_files()
	# 1. Load hero nodes first so generated routes can snap to exact hero heights.
	var hero_data: Array[Dictionary] = []
	for path: String in hero_files:
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		hero_data.append(d)
		var id_map: Dictionary[int, int] = {}
		for hn: Dictionary in d["nodes"]:
			var p := Vector3(hn["p"][0], hn["p"][1], hn["p"][2])
			var nid: int = _get_or_create_node(p, true, bool(hn.get("town", false)))
			id_map[int(hn["id"])] = nid
		d["_id_map"] = id_map

	# 2. Spline + split generated routes at shared waypoints AND XZ crossings.
	var routes: Array = TerrainFn.def["routes"]
	var uses: Dictionary[Vector2, int] = {}
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		for i: int in wp.size():
			var k := Vector2(snappedf(wp[i][0], 0.1), snappedf(wp[i][1], 0.1))
			uses[k] = uses.get(k, 0) + (2 if i == 0 or i == wp.size() - 1 else 1)

	var pieces: Array[Dictionary] = []  # {name, type, pts: PackedVector3Array}
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		var line := PackedVector3Array()
		for p: Array in wp:
			line.append(Vector3(p[0], 0.0, p[1]))
		var fine: PackedVector3Array = RoadGraph.spline(line, SUB)
		var k0: int = 0
		for k: int in range(1, wp.size()):
			var wk := Vector2(snappedf(wp[k][0], 0.1), snappedf(wp[k][1], 0.1))
			if uses[wk] >= 2:
				pieces.append({"name": r["name"], "type": r["type"], "pts": RoadGraph.resample(fine.slice(k0 * SUB, k * SUB + 1), CTRL)})
				k0 = k

	# Split any intersecting generated pieces so crossings become junction nodes.
	pieces = _split_crossings(pieces)

	# Pre-register endpoints of generated pieces and relax non-pinned node heights to satisfy MAX_GRADE.
	for pc: Dictionary in pieces:
		var pts: PackedVector3Array = pc["pts"]
		if pts.size() >= 2:
			pc["a"] = _get_or_create_node(pts[0], false, false)
			pc["b"] = _get_or_create_node(pts[pts.size() - 1], false, false)
	_relax_node_heights(pieces)

	for pc: Dictionary in pieces:
		_emit_generated_edge(pc["name"], pc["type"], pc["pts"])

	# 3. Copy hero edges verbatim.
	for d: Dictionary in hero_data:
		var id_map: Dictionary = d["_id_map"]
		for he: Dictionary in d["edges"]:
			var a: int = id_map[int(he["a"])]
			var b: int = id_map[int(he["b"])]
			edges.append({
				"id": edges.size(),
				"a": a,
				"b": b,
				"type": he["type"],
				"elevated": bool(he.get("elevated", false)),
				"pts": he["pts"],
			})

	# 4. Flag town nodes from world_def.json.
	for tw: Array in TerrainFn.def.get("towns", []):
		var tp := Vector2(tw[0], tw[1])
		var best_n: int = -1
		var best_d: float = 120.0 * 120.0
		for n: Dictionary in nodes:
			var np := Vector2(n["p"][0], n["p"][2])
			var d2: float = np.distance_squared_to(tp)
			if d2 < best_d:
				best_d = d2
				best_n = int(n["id"])
		if best_n >= 0:
			nodes[best_n]["town"] = true

	var f := FileAccess.open("res://data/roads/network.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "seed": TerrainFn.world_seed, "nodes": nodes, "edges": edges}))
	f.close()

	RoadGraph.load_file("res://data/roads/network.json")
	var km: PackedFloat32Array = RoadGraph.km_by_type()
	print("network: %d nodes, %d edges, %.1f km (highway %.1f, country %.1f, mountain %.1f, city %.1f)" % [
		nodes.size(), edges.size(), RoadGraph.total_km(), km[0], km[1], km[2], km[3]])
	var msg: String = RoadGraph.self_check()
	if msg != "":
		print("NETWORK FAIL: ", msg)
		bad += 1
	if RoadGraph.total_km() < 100.0:
		print("NETWORK FAIL: total km %.1f < 100" % RoadGraph.total_km())
		bad += 1
	if not _check_connected():
		print("NETWORK FAIL: graph disconnected")
		bad += 1
	_check_radii()
	quit(1 if bad > 0 else 0)


func _list_hero_files() -> Array[String]:
	var out: Array[String] = []
	if DirAccess.dir_exists_absolute("res://data/hero"):
		for fn: String in DirAccess.get_files_at("res://data/hero"):
			if fn.ends_with(".json"):
				out.append("res://data/hero/" + fn)
	out.sort()
	return out


func _get_or_create_node(p: Vector3, pin_y: bool, town: bool) -> int:
	var pxz := Vector2(p.x, p.z)
	for n: Dictionary in nodes:
		var nxz := Vector2(n["p"][0], n["p"][2])
		if nxz.distance_to(pxz) < SNAP_DIST:
			var nid: int = int(n["id"])
			if pin_y:
				n["p"] = _arr(p)
				_pinned_y[nid] = p.y
			if town:
				n["town"] = true
			return nid
	var id: int = nodes.size()
	var y: float = p.y if pin_y else TerrainFn.base_height(p.x, p.z)
	nodes.append({"id": id, "p": _arr(Vector3(p.x, y, p.z)), "town": town})
	if pin_y:
		_pinned_y[id] = y
	return id


func _split_crossings(pieces: Array[Dictionary]) -> Array[Dictionary]:
	# Iteratively split any crossing between two non-adjacent segments in XZ.
	var cur: Array[Dictionary] = pieces
	for _round: int in 8:
		var did_split: bool = false
		for i: int in cur.size():
			var pts_a: PackedVector3Array = cur[i]["pts"]
			for j: int in range(i, cur.size()):
				var pts_b: PackedVector3Array = cur[j]["pts"]
				var hit: Dictionary = _find_crossing(pts_a, pts_b, i == j)
				if not hit.is_empty():
					var ix_p: Vector3 = hit["pos"]
					var ia: int = hit["ia"]
					var ib: int = hit["ib"]
					var new_list: Array[Dictionary] = []
					for k: int in cur.size():
						if k == i and k == j:
							var s0: PackedVector3Array = pts_a.slice(0, ia + 1) + PackedVector3Array([ix_p])
							var s1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ia + 1, ib + 1) + PackedVector3Array([ix_p])
							var s2: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ib + 1)
							for sub: PackedVector3Array in [s0, s1, s2]:
								if sub.size() >= 2:
									new_list.append({"name": cur[i]["name"], "type": cur[i]["type"], "pts": RoadGraph.resample(sub, CTRL)})
						elif k == i:
							var sa0: PackedVector3Array = pts_a.slice(0, ia + 1) + PackedVector3Array([ix_p])
							var sa1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_a.slice(ia + 1)
							new_list.append({"name": cur[i]["name"], "type": cur[i]["type"], "pts": RoadGraph.resample(sa0, CTRL)})
							new_list.append({"name": cur[i]["name"], "type": cur[i]["type"], "pts": RoadGraph.resample(sa1, CTRL)})
						elif k == j:
							var sb0: PackedVector3Array = pts_b.slice(0, ib + 1) + PackedVector3Array([ix_p])
							var sb1: PackedVector3Array = PackedVector3Array([ix_p]) + pts_b.slice(ib + 1)
							new_list.append({"name": cur[j]["name"], "type": cur[j]["type"], "pts": RoadGraph.resample(sb0, CTRL)})
							new_list.append({"name": cur[j]["name"], "type": cur[j]["type"], "pts": RoadGraph.resample(sb1, CTRL)})
						else:
							new_list.append(cur[k])
					cur = new_list
					did_split = true
					break
			if did_split:
				break
		if not did_split:
			break
	return cur


func _find_crossing(a: PackedVector3Array, b: PackedVector3Array, same: bool) -> Dictionary:
	for ia: int in a.size() - 1:
		var a0 := Vector2(a[ia].x, a[ia].z)
		var a1 := Vector2(a[ia + 1].x, a[ia + 1].z)
		var j_start: int = ia + 3 if same else 0
		for ib: int in range(j_start, b.size() - 1):
			if not same and ((ia <= 1 and ib <= 1) or (ia >= a.size() - 3 and ib >= b.size() - 3) or (ia <= 1 and ib >= b.size() - 3) or (ia >= a.size() - 3 and ib <= 1)):
				continue
			var b0 := Vector2(b[ib].x, b[ib].z)
			var b1 := Vector2(b[ib + 1].x, b[ib + 1].z)
			var res: Variant = Geometry2D.segment_intersects_segment(a0, a1, b0, b1)
			if res is Vector2:
				var p2 := res as Vector2
				if p2.distance_to(Vector2(a[0].x, a[0].z)) < 50.0 or p2.distance_to(Vector2(a[a.size() - 1].x, a[a.size() - 1].z)) < 50.0:
					continue
				if p2.distance_to(Vector2(b[0].x, b[0].z)) < 50.0 or p2.distance_to(Vector2(b[b.size() - 1].x, b[b.size() - 1].z)) < 50.0:
					continue
				return {"ia": ia, "ib": ib, "pos": Vector3(p2.x, 0.0, p2.y)}
	return {}


func _relax_node_heights(pieces: Array[Dictionary]) -> void:
	for _pass: int in 600:
		for pc: Dictionary in pieces:
			if not pc.has("a"):
				continue
			var a: int = pc["a"]
			var b: int = pc["b"]
			if a == b:
				continue
			var type: int = RoadGraph.TYPE_NAMES.find(pc["type"])
			var pts: PackedVector3Array = pc["pts"]
			var elen: float = 0.0
			for i: int in pts.size() - 1:
				elen += pts[i].distance_to(pts[i + 1])
			var max_dy: float = RoadGraph.MAX_GRADE[type] * 0.72 * elen
			var ya: float = nodes[a]["p"][1]
			var yb: float = nodes[b]["p"][1]
			var diff: float = yb - ya
			if absf(diff) > max_dy:
				var excess: float = (absf(diff) - max_dy) * signf(diff)
				var pin_a: bool = _pinned_y.has(a)
				var pin_b: bool = _pinned_y.has(b)
				if not pin_a and not pin_b:
					ya += excess * 0.5
					yb -= excess * 0.5
				elif not pin_a:
					ya += excess
				elif not pin_b:
					yb -= excess
				nodes[a]["p"][1] = snappedf(ya, 0.01)
				nodes[b]["p"][1] = snappedf(yb, 0.01)


func _emit_generated_edge(rname: String, rtype: String, pts: PackedVector3Array) -> void:
	var type: int = RoadGraph.TYPE_NAMES.find(rtype)
	var n: int = pts.size()
	if n < 2:
		return
	var a: int = _get_or_create_node(pts[0], false, false)
	var b: int = _get_or_create_node(pts[n - 1], false, false)
	if a == b and n < 4:
		return
	var ds: float = pts[0].distance_to(pts[1])
	var g: float = RoadGraph.MAX_GRADE[type] * 0.80 * ds
	var y := PackedFloat32Array()
	for p: Vector3 in pts:
		y.append(TerrainFn.base_height(p.x, p.z))
	y[0] = nodes[a]["p"][1]
	y[n - 1] = nodes[b]["p"][1]
	for _pass: int in 6:
		var prev: float = y[0]
		for i: int in range(1, n - 1):
			var cur: float = y[i]
			y[i] = (prev + 2.0 * cur + y[i + 1]) * 0.25
			prev = cur
	for i: int in range(1, n - 1):
		var rem: float = (n - 1 - i) * g
		y[i] = clampf(y[i], maxf(y[i - 1] - g, y[n - 1] - rem), minf(y[i - 1] + g, y[n - 1] + rem))
	for i: int in range(n - 2, 0, -1):
		y[i] = clampf(y[i], y[i + 1] - g, y[i + 1] + g)
	var worst: float = 0.0
	var out: Array = []
	for i: int in n:
		if i > 0:
			worst = maxf(worst, absf(y[i] - y[i - 1]) / maxf(ds, 0.1))
		out.append(_arr(Vector3(pts[i].x, y[i], pts[i].z)))
	if worst > RoadGraph.MAX_GRADE[type]:
		print("NETWORK FAIL: %s grade %.3f (a=%d y=%.1f b=%d y=%.1f n=%d)" % [rname, worst, a, y[0], b, y[n - 1], n])
		bad += 1
	edges.append({"id": edges.size(), "a": a, "b": b, "type": rtype, "elevated": false, "pts": out})


func _check_connected() -> bool:
	if nodes.is_empty():
		return false
	var adj: Array[Array] = []
	adj.resize(nodes.size())
	for i: int in nodes.size():
		adj[i] = []
	for e: Dictionary in edges:
		adj[int(e["a"])].append(int(e["b"]))
		adj[int(e["b"])].append(int(e["a"]))
	var seen: Dictionary[int, bool] = {0: true}
	var q: Array[int] = [0]
	while not q.is_empty():
		var u: int = q.pop_back()
		for v: int in adj[u]:
			if not seen.has(v):
				seen[v] = true
				q.append(v)
	return seen.size() == nodes.size()


func _check_radii() -> void:
	var min_r := PackedFloat32Array([1e9, 1e9, 1e9, 1e9])
	for e: int in RoadGraph.e_pts.size():
		var t: int = RoadGraph.e_type[e]
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var ds: float = RoadGraph.e_step[e] * 4.0
		for i: int in range(4, pts.size() - 4, 4):
			var v0 := Vector2(pts[i].x - pts[i - 4].x, pts[i].z - pts[i - 4].z).normalized()
			var v1 := Vector2(pts[i + 4].x - pts[i].x, pts[i + 4].z - pts[i].z).normalized()
			var ang: float = acos(clampf(v0.dot(v1), -1.0, 1.0))
			if ang > 0.01:
				min_r[t] = minf(min_r[t], ds / ang)
	print("min radius (m): highway %.0f country %.0f mountain %.0f city %.0f" % [min_r[0], min_r[1], min_r[2], min_r[3]])


func _arr(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]


func _limit(v: float, l: float, r: float, g: float) -> float:
	var lo: float = maxf(l, r) - g
	var hi: float = minf(l, r) + g
	return (lo + hi) * 0.5 if lo > hi else clampf(v, lo, hi)
