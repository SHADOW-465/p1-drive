extends SceneTree
## Builds data/roads/network.json from the routes in data/world_def.json (PLAN 2.4).
## Run: godot --headless --path . -s res://tools/gen_network.gd
## Waypoints shared by routes (and route ends) become nodes; routes are split there.

const CTRL: float = 40.0  # control point spacing
const SUB: int = 64

var nodes: Array[Dictionary] = []
var node_of: Dictionary[Vector2, int] = {}
var edges: Array[Dictionary] = []
var bad: int = 0


func _init() -> void:
	var routes: Array = TerrainFn.def["routes"]
	var uses: Dictionary[Vector2, int] = {}
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		for i: int in wp.size():
			var k := Vector2(wp[i][0], wp[i][1])
			uses[k] = uses.get(k, 0) + (2 if i == 0 or i == wp.size() - 1 else 1)
	for r: Dictionary in routes:
		var wp: Array = r["wp"]
		var line := PackedVector3Array()
		for p: Array in wp:
			line.append(Vector3(p[0], 0.0, p[1]))
		var fine: PackedVector3Array = RoadGraph.spline(line, SUB)
		var k0: int = 0
		for k: int in range(1, wp.size()):
			if uses[Vector2(wp[k][0], wp[k][1])] >= 2:
				_edge(r, fine.slice(k0 * SUB, k * SUB + 1))
				k0 = k
	var f := FileAccess.open("res://data/roads/network.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 1, "seed": TerrainFn.world_seed, "nodes": nodes, "edges": edges}))
	f.close()
	RoadGraph.load_file("res://data/roads/network.json")
	var km: PackedFloat32Array = RoadGraph.km_by_type()
	print("network: %d nodes, %d edges, %.1f km (highway %.1f, country %.1f, mountain %.1f, city %.1f)" % [nodes.size(), edges.size(), RoadGraph.total_km(), km[0], km[1], km[2], km[3]])
	var msg: String = RoadGraph.self_check()
	if msg != "":
		print("NETWORK FAIL: ", msg)
		bad += 1
	quit(1 if bad > 0 else 0)


func _node(p: Vector3) -> int:
	var k := Vector2(p.x, p.z)
	if not node_of.has(k):
		node_of[k] = nodes.size()
		nodes.append({"id": nodes.size(), "p": _arr(Vector3(p.x, TerrainFn.base_height(p.x, p.z), p.z)), "town": false})
	return node_of[k]


func _arr(p: Vector3) -> Array:
	return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]


func _edge(r: Dictionary, fine: PackedVector3Array) -> void:
	var type: int = RoadGraph.TYPE_NAMES.find(r["type"])
	var pts: PackedVector3Array = RoadGraph.resample(fine, CTRL)
	var n: int = pts.size()
	var a: int = _node(pts[0])
	var b: int = _node(pts[n - 1])
	var ds: float = pts[0].distance_to(pts[1])
	var g: float = RoadGraph.MAX_GRADE[type] * 0.85 * ds
	var y := PackedFloat32Array()
	for p: Vector3 in pts:
		y.append(TerrainFn.base_height(p.x, p.z))
	y[0] = nodes[a]["p"][1]
	y[n - 1] = nodes[b]["p"][1]
	for pass_i: int in 6:  # smooth: cuts and embankments instead of following every bump
		var prev: float = y[0]
		for i: int in range(1, n - 1):
			var cur: float = y[i]
			y[i] = (prev + 2.0 * cur + y[i + 1]) * 0.25
			prev = cur
	for pass_i: int in 400:  # grade limit, ends pinned
		for i: int in range(1, n - 1):
			y[i] = _limit(y[i], y[i - 1], y[i + 1], g)
		for i: int in range(n - 2, 0, -1):
			y[i] = _limit(y[i], y[i - 1], y[i + 1], g)
	var worst: float = 0.0
	var out: Array = []
	for i: int in n:
		if i > 0:
			worst = maxf(worst, absf(y[i] - y[i - 1]) / ds)
		out.append(_arr(Vector3(pts[i].x, y[i], pts[i].z)))
	if worst > RoadGraph.MAX_GRADE[type]:
		print("NETWORK FAIL: %s grade %.3f" % [r["name"], worst])
		bad += 1
	edges.append({"id": edges.size(), "a": a, "b": b, "type": r["type"], "elevated": false, "pts": out})


func _limit(v: float, l: float, r: float, g: float) -> float:
	var lo: float = maxf(l, r) - g
	var hi: float = minf(l, r) + g
	return (lo + hi) * 0.5 if lo > hi else clampf(v, lo, hi)
