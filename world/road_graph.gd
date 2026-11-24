class_name RoadGraph
extends RefCounted
## Road network (PLAN 2.4 / RD2), loaded once from data/roads/network.json. Pure static and
## immutable after load, so tile workers read it freely (hence no autoload node).
## Every edge is resampled to a dense polyline with uniform spacing (~STEP m).

enum { HIGHWAY, COUNTRY, MOUNTAIN, CITY, RAMP, RURAL }
const TYPE_NAMES: PackedStringArray = ["highway", "country", "mountain", "city", "ramp", "rural"]
const WIDTH: PackedFloat32Array = [22.0, 8.0, 6.5, 10.0, 7.5, 5.5]  # paved width
const MAX_GRADE: PackedFloat32Array = [0.05, 0.08, 0.115, 0.06, 0.075, 0.095]

enum { KIND_ROAD, KIND_BRIDGE, KIND_OVERPASS, KIND_TUNNEL }
const KIND_NAMES: PackedStringArray = ["road", "bridge", "overpass", "tunnel"]

enum { NODE_NORMAL, NODE_MERGE, NODE_ROUNDABOUT, NODE_SIGNAL }
const NODE_KIND_NAMES: PackedStringArray = ["normal", "merge", "roundabout", "signal"]

const STEP: float = 4.0
const MARGIN: float = 128.0  # index runs cover the tile grown by this (terrain stamping reach)
const TILE: float = 1024.0

static var nodes: PackedVector3Array = []
static var node_town: PackedByteArray = []
static var node_kind: PackedInt32Array = []
static var node_radius: PackedFloat32Array = []
static var node_edges: Array[PackedInt32Array] = []
static var e_type: PackedInt32Array = []
static var e_a: PackedInt32Array = []
static var e_b: PackedInt32Array = []
static var e_kind: PackedInt32Array = []
static var e_width: PackedFloat32Array = []  # paved width (m) of each edge
static var e_elev: PackedByteArray = []
static var e_pts: Array[PackedVector3Array] = []  # dense polyline, world coords
static var e_step: PackedFloat32Array = []  # exact spacing of that edge's polyline
static var e_bank: Array[PackedFloat32Array] = []  # roll angle (rad), + = right edge higher (left turn)
static var spawn_edge: int = -1
static var spawn_i: int = 0
static var spawn_pos: Vector3 = Vector3.ZERO
static var spawn_fwd: Vector3 = Vector3.FORWARD
static var _index: Dictionary[Vector2i, Array] = {}  # tile -> [Vector3i(edge, first, last)]
static var e_cap: Array[PackedFloat32Array] = []  # OSM: slab half-width so a parallel carriageway is not stacked
static var e_side: Array[PackedFloat32Array] = []  # +1 neighbour lies to the right of travel
static var _fine: Dictionary[Vector2i, PackedInt32Array] = {}  # OSM: 16 m cell -> samples (edge << 16 | i)
const FINE: float = 16.0


static func _static_init() -> void:
	load_file(OsmWorld.DIR + "network.json" if OsmWorld.enabled else "res://data/roads/network.json")


static func load_file(path: String) -> void:
	nodes = []
	node_town = []
	node_kind = []
	node_radius = []
	node_edges = []
	e_type = []
	e_a = []
	e_b = []
	e_kind = []
	e_elev = []
	e_width = []
	e_pts = []
	e_step = []
	e_bank = []
	spawn_edge = -1
	spawn_i = 0
	spawn_pos = Vector3.ZERO
	spawn_fwd = Vector3.FORWARD
	_index = {}
	e_cap = []
	e_side = []
	if not FileAccess.file_exists(path):
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for n: Dictionary in d["nodes"]:
		nodes.append(Vector3(n["p"][0], n["p"][1], n["p"][2]))
		node_town.append(1 if n.get("town", false) else 0)
		var nk_i: int = NODE_KIND_NAMES.find(str(n.get("kind", "normal")))
		node_kind.append(nk_i if nk_i >= 0 else NODE_NORMAL)
		node_radius.append(float(n.get("radius", 0.0)))
		node_edges.append(PackedInt32Array())
	for e: Dictionary in d["edges"]:
		var id: int = e_type.size()
		var ctrl := PackedVector3Array()
		for p: Array in e["pts"]:
			ctrl.append(Vector3(p[0], p[1], p[2]))
		var t_i: int = TYPE_NAMES.find(str(e["type"]))
		e_type.append(t_i)
		e_a.append(int(e["a"]))
		e_b.append(int(e["b"]))
		var ek_str: String = str(e.get("kind", "bridge" if bool(e.get("elevated", false)) else "road"))
		var ek_i: int = KIND_NAMES.find(ek_str)
		if ek_i < 0:
			ek_i = KIND_ROAD
		e_kind.append(ek_i)
		var elev: int = 1 if (bool(e.get("elevated", false)) or ek_i == KIND_BRIDGE or ek_i == KIND_OVERPASS) else 0
		e_elev.append(elev)
		node_edges[e_a[id]].append(id)
		node_edges[e_b[id]].append(id)
		e_width.append(float(e.get("width", WIDTH[maxi(t_i, 0)])))
		# Baked OSM polylines are already a 10 m spline. Re-fitting Catmull-Rom with phantom
		# endpoints curls the first and last span and kinks every node. Just resample those.
		var curve: PackedVector3Array = ctrl if bool(e.get("dense", false)) else spline(ctrl, 8)
		var dense: PackedVector3Array = resample(_despike(curve), STEP)
		e_pts.append(dense)
		var step_d: float = dense[0].distance_to(dense[1]) if dense.size() >= 2 else STEP
		e_step.append(step_d)
		e_bank.append(_compute_bank(t_i, elev, dense, step_d))
		_index_edge(id, dense)
	_pin_node_heights()
	_smooth_highway_kinks()
	_smooth_profiles()
	_fit_carriageways()
	_plane_junctions()
	_lock_gores()
	_build_fine()

	var sp: Dictionary = d.get("spawn", {})
	if sp.has("edge") and int(sp["edge"]) >= 0 and int(sp["edge"]) < e_pts.size():
		spawn_edge = int(sp["edge"])
		var spts: PackedVector3Array = e_pts[spawn_edge]
		spawn_i = clampi(roundi(float(sp["s"]) / e_step[spawn_edge]) if sp.has("s") else int(sp.get("i", spts.size() / 2)), 0, spts.size() - 1)
		spawn_pos = spts[spawn_i]
		spawn_fwd = tangent(spawn_edge, spawn_i)
		if float(sp.get("dir", 1.0)) < 0.0:
			spawn_fwd = -spawn_fwd
	elif not e_pts.is_empty():
		spawn_edge = 0
		spawn_i = mini(10, e_pts[0].size() - 1)
		spawn_pos = e_pts[0][spawn_i]
		spawn_fwd = tangent(0, spawn_i)


static func _compute_bank(type: int, elev: int, pts: PackedVector3Array, step_d: float) -> PackedFloat32Array:
	var n: int = pts.size()
	var bank_arr := PackedFloat32Array()
	bank_arr.resize(n)
	if elev == 1 or n < 10 or (type != HIGHWAY and type != RAMP and type != COUNTRY):
		return bank_arr
	var max_b: float = deg_to_rad(4.0 if type == HIGHWAY else (4.5 if type == RAMP else 3.0))
	var gain: float = 950.0 if type == HIGHWAY else (520.0 if type == RAMP else 560.0)
	var w: int = 3
	if OsmWorld.enabled:
		# Surveyed polylines carry sub-degree kinks; over a 12 m chord any of them saturates the bank and the
		# sign flips every few samples (a +-0.45 m heave in the outer lane). Measure the turn over 120 m and
		# reach full bank at R = 600 m.
		w = maxi(roundi(60.0 / maxf(step_d, 1.0)), 3)
		gain = max_b * 600.0
	for i: int in range(w, n - w):
		var v0 := Vector2(pts[i].x - pts[i - w].x, pts[i].z - pts[i - w].z)
		var v1 := Vector2(pts[i + w].x - pts[i].x, pts[i + w].z - pts[i].z)
		if v0.length_squared() < 1e-4 or v1.length_squared() < 1e-4:
			continue
		var d0: Vector2 = v0.normalized()
		var d1: Vector2 = v1.normalized()
		# In XZ (+X east, +Z south): d0.x*d1.y - d0.y*d1.x < 0 is a LEFT turn -> +rt (outer) rises (+bank).
		var turn_left: float = -(d0.x * d1.y - d0.y * d1.x)
		var kappa: float = turn_left / maxf(step_d * float(w), 1.0)
		bank_arr[i] = clampf(kappa * gain, -max_b, max_b)
	for _pass: int in 8:
		var prev: float = bank_arr[0]
		for i: int in range(1, n - 1):
			var cur: float = bank_arr[i]
			bank_arr[i] = (prev + 2.0 * cur + bank_arr[i + 1]) * 0.25
			prev = cur
	var fade_pts: float = 40.0 / maxf(step_d, 1.0)
	for i: int in n:
		var end_fade: float = clampf(minf(float(i), float(n - 1 - i)) / maxf(fade_pts, 1.0), 0.0, 1.0)
		bank_arr[i] *= end_fade * end_fade * (3.0 - 2.0 * end_fade)
	return bank_arr


## The bake stores one height per node, taken from whichever edge was written last, so two
## edges can meet with a multi-metre step. Keep the highest-class road's height and blend
## every other edge up to it. XZ is already shared; only Y moves, so the tile index stays valid.
static func _pin_node_heights() -> void:
	var rank: PackedInt32Array = [3, 1, 1, 1, 2, 1]  # highway, country, mountain, city, ramp, rural
	var best := PackedInt32Array()
	best.resize(nodes.size())
	best.fill(-1)
	var acc_y := PackedFloat32Array()
	acc_y.resize(nodes.size())
	var acc_n := PackedInt32Array()
	acc_n.resize(nodes.size())
	for e: int in e_pts.size():
		var r: int = rank[clampi(e_type[e], 0, rank.size() - 1)]
		for end_i: int in 2:
			var n: int = e_a[e] if end_i == 0 else e_b[e]
			var y: float = e_pts[e][0 if end_i == 0 else e_pts[e].size() - 1].y
			if r > best[n]:
				best[n] = r
				acc_y[n] = y
				acc_n[n] = 1
			elif r == best[n]:
				acc_y[n] += y
				acc_n[n] += 1
	for n: int in nodes.size():
		if acc_n[n] > 0:
			var p: Vector3 = nodes[n]
			p.y = acc_y[n] / float(acc_n[n])
			nodes[n] = p
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		var npts: int = pts.size()
		if npts < 2:
			continue
		var dy_a: float = nodes[e_a[e]].y - pts[0].y
		var dy_b: float = nodes[e_b[e]].y - pts[npts - 1].y
		if absf(dy_a) >= 0.01 or absf(dy_b) >= 0.01:
			for i: int in npts:
				var t: float = float(i) / float(npts - 1)
				var p: Vector3 = pts[i]
				p.y += lerpf(dy_a, dy_b, t)
				pts[i] = p
		pts = resample(pts, STEP)
		e_pts[e] = pts
		var step_d: float = pts[0].distance_to(pts[1]) if pts.size() >= 2 else STEP
		e_step[e] = step_d
		e_bank[e] = _compute_bank(e_type[e], e_elev[e], pts, step_d)
	_index.clear()
	for e: int in e_pts.size():
		_index_edge(e, e_pts[e])


## Survey heights and the node pinning above leave grade breaks of 10 %+ inside one 4 m sample (a V-sag of
## vertical radius ~30 m bottoms a car out at 170 km/h). Every run of edges joined end to end through plain
## continuation nodes is smoothed as one profile: three passes of a centred moving average over +-PROFILE_HALF
## (~Gaussian, sigma = half / sqrt(2)), the window shrinking at both ends so junction heights stay exact. A 12 %
## break then spreads into a vertical curve of R ~ 600 m on motorways (half 36 m), ~350 m elsewhere (20 m),
## ~170 m on mountain roads (10 m), which keep their real switchback grades. Only y moves.
const PROFILE_HALF: PackedFloat32Array = [36.0, 20.0, 10.0, 20.0, 28.0, 20.0]


static func _smooth_profiles() -> void:
	if not OsmWorld.enabled:
		return
	var seen := PackedByteArray()
	seen.resize(e_pts.size())
	for e0: int in e_pts.size():
		if seen[e0] != 0:
			continue
		# Walk back to the start of the chain, then collect it forwards as (edge, forward?) pairs.
		var e: int = e0
		var fwd: bool = true
		for _guard: int in e_pts.size():
			var back_node: int = e_a[e] if fwd else e_b[e]
			if node_edges[back_node].size() != 2:
				break
			var pe: int = node_edges[back_node][0] if node_edges[back_node][1] == e else node_edges[back_node][1]
			if pe == e0 or seen[pe] != 0:
				break
			fwd = e_b[pe] == back_node
			e = pe
		var chain: Array[Vector2i] = []
		var y := PackedFloat32Array()
		var half: float = 0.0
		var step_sum: float = 0.0
		for _guard: int in e_pts.size():
			seen[e] = 1
			chain.append(Vector2i(e, 1 if fwd else 0))
			half = maxf(half, PROFILE_HALF[clampi(e_type[e], 0, PROFILE_HALF.size() - 1)])
			var pts: PackedVector3Array = e_pts[e]
			var n: int = pts.size()
			for k: int in range(0 if y.is_empty() else 1, n):
				y.append(pts[k if fwd else n - 1 - k].y)
			step_sum += e_step[e] * float(n - 1)
			var end_node: int = e_b[e] if fwd else e_a[e]
			if node_edges[end_node].size() != 2:
				break
			var ne: int = node_edges[end_node][0] if node_edges[end_node][1] == e else node_edges[end_node][1]
			if seen[ne] != 0:
				break
			fwd = e_a[ne] == end_node
			e = ne
		if y.size() < 5:
			continue
		var r: int = maxi(roundi(half / maxf(step_sum / float(y.size() - 1), 1.0)), 1)
		for _pass: int in 3:
			y = _box_pinned(y, r)
		var at: int = 0
		for c: Vector2i in chain:
			var pts: PackedVector3Array = e_pts[c.x]
			var n: int = pts.size()
			for k: int in n:
				var j: int = k if c.y == 1 else n - 1 - k
				var p: Vector3 = pts[j]
				p.y = y[at + k]
				pts[j] = p
			e_pts[c.x] = pts
			at += n - 1
			for end_i: int in 2:  # continuation nodes moved with the profile
				var nd: int = e_a[c.x] if end_i == 0 else e_b[c.x]
				if node_edges[nd].size() == 2:
					nodes[nd] = pts[0] if end_i == 0 else pts[n - 1]


## Centred moving average of radius r whose window shrinks to fit at both ends (so y[0] and y[n-1] stay put).
static func _box_pinned(y: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var n: int = y.size()
	var pre := PackedFloat64Array()
	pre.resize(n + 1)
	for i: int in n:
		pre[i + 1] = pre[i] + y[i]
	var out := PackedFloat32Array()
	out.resize(n)
	for i: int in n:
		var w: int = mini(r, mini(i, n - 1 - i))
		out[i] = (pre[i + w + 1] - pre[i - w]) / float(2 * w + 1)
	return out


## Spread a sharp motorway kink over ~220 m so a fast car stays on the slab through the node.
## The through pair's endpoints move with the node; the other arms are dragged to the new point.
static func _smooth_highway_kinks() -> void:
	if not OsmWorld.enabled:
		return
	var use_a := PackedInt32Array()
	var use_b := PackedInt32Array()
	use_a.resize(e_pts.size())
	use_b.resize(e_pts.size())
	var jobs: Array[Vector3i] = []
	for n_i: int in nodes.size():
		var ids: PackedInt32Array = node_edges[n_i]
		if ids.size() < 3:
			continue
		var best_a: int = -1
		var best_b: int = -1
		var best_dot: float = 2.0
		for ia: int in ids.size():
			if e_type[ids[ia]] != HIGHWAY:
				continue
			var da: Vector3 = _arm_out(ids[ia], n_i)
			for ib: int in range(ia + 1, ids.size()):
				if e_type[ids[ib]] != HIGHWAY:
					continue
				var dot_ab: float = da.dot(_arm_out(ids[ib], n_i))
				if dot_ab < best_dot:
					best_dot = dot_ab
					best_a = ids[ia]
					best_b = ids[ib]
		if best_a < 0:
			continue
		var deflect: float = acos(clampf(-best_dot, -1.0, 1.0))
		if deflect < 0.12 or deflect > (1.75 if OsmWorld.enabled else 0.95):
			continue  # OSM: up to 100 deg, a motorway terminus snapped onto a junction turns square
		var want: int = clampi(roundi(220.0 / STEP), 12, 70)
		var ca: int = mini(want, e_pts[best_a].size() / 3)
		var cb: int = mini(want, e_pts[best_b].size() / 3)
		if mini(ca, cb) < 6:
			continue
		jobs.append(Vector3i(n_i, best_a, best_b))
		if e_a[best_a] == n_i:
			use_a[best_a] = maxi(use_a[best_a], ca)
		else:
			use_b[best_a] = maxi(use_b[best_a], ca)
		if e_a[best_b] == n_i:
			use_a[best_b] = maxi(use_a[best_b], cb)
		else:
			use_b[best_b] = maxi(use_b[best_b], cb)
	for e_i: int in e_pts.size():
		var spare: int = e_pts[e_i].size() - 8
		if use_a[e_i] + use_b[e_i] > spare and use_a[e_i] + use_b[e_i] > 0:
			var scale: float = float(maxi(spare, 0)) / float(use_a[e_i] + use_b[e_i])
			use_a[e_i] = int(float(use_a[e_i]) * scale)
			use_b[e_i] = int(float(use_b[e_i]) * scale)
	var touched: Dictionary = {}
	for job: Vector3i in jobs:
		var n_i: int = job.x
		var ea: int = job.y
		var eb: int = job.z
		var ca2: int = use_a[ea] if e_a[ea] == n_i else use_b[ea]
		var cb2: int = use_a[eb] if e_a[eb] == n_i else use_b[eb]
		if mini(ca2, cb2) < 6:
			continue
		if not _bend_pair(n_i, ea, eb, mini(ca2, cb2)):
			continue
		touched[ea] = true
		touched[eb] = true
		for oe: int in node_edges[n_i]:
			if oe == ea or oe == eb:
				continue
			_drag_endpoint(oe, n_i, nodes[n_i])
			touched[oe] = true
	if touched.is_empty():
		return
	for key: Variant in touched.keys():
		var e_i: int = int(key)
		var pts: PackedVector3Array = e_pts[e_i]
		if pts.size() >= 2:
			pts[0] = nodes[e_a[e_i]]
			pts[pts.size() - 1] = nodes[e_b[e_i]]
			pts = resample(pts, STEP)
			pts[0] = nodes[e_a[e_i]]
			pts[pts.size() - 1] = nodes[e_b[e_i]]
		e_pts[e_i] = pts
		var step_d: float = pts[0].distance_to(pts[1]) if pts.size() >= 2 else STEP
		e_step[e_i] = step_d
		e_bank[e_i] = _compute_bank(e_type[e_i], e_elev[e_i], pts, step_d)
	_index.clear()
	for e_i: int in e_pts.size():
		_index_edge(e_i, e_pts[e_i])


## OSM junctions: every arm leaves the node at its own grade, so slabs that overlap there step against each other.
## Fit one plane through the node (least squares over the arms' first 25 m, slope <= 12 %) and lay each arm on it for
## 15 m, blending back to its own profile by 45 m: the centreline height and the cross-fall (bank), so the overlapping
## slabs are the same surface. Only y and bank move.
static func _plane_junctions() -> void:
	if not OsmWorld.enabled:
		return
	for n_i: int in nodes.size():
		var ids: PackedInt32Array = node_edges[n_i]
		if ids.size() < 3:
			continue
		var c: Vector3 = nodes[n_i]
		var thru: Vector2i = _through_arms(n_i)
		var sxx: float = 0.0
		var sxz: float = 0.0
		var szz: float = 0.0
		var sxy: float = 0.0
		var szy: float = 0.0
		for e: int in ids:
			var pts: PackedVector3Array = e_pts[e]
			var at_a: bool = e_a[e] == n_i
			# The through road keeps its own grade (a bent motorway launches a fast car); side arms adapt to it.
			var wt: float = 20.0 if e == thru.x or e == thru.y else 1.0
			for k: int in mini(ceili(25.0 / maxf(e_step[e], 1.0)) + 1, pts.size()):
				var p: Vector3 = pts[k if at_a else pts.size() - 1 - k] - c
				sxx += wt * p.x * p.x
				sxz += wt * p.x * p.z
				szz += wt * p.z * p.z
				sxy += wt * p.x * p.y
				szy += wt * p.z * p.y
		var det: float = sxx * szz - sxz * sxz
		if absf(det) < 1e-3:
			continue
		var g := Vector2((sxy * szz - szy * sxz) / det, (szy * sxx - sxy * sxz) / det)
		if g.length() > 0.12:
			g = g.normalized() * 0.12
		for e: int in ids:
			var pts: PackedVector3Array = e_pts[e]
			var at_a: bool = e_a[e] == n_i
			var step_d: float = maxf(e_step[e], 1.0)
			# A short edge gives each end half of it: the blend must reach 0 by then, or the two ends meet in a step.
			var reach: float = minf(45.0, (pts.size() - 1) * step_d * 0.5)
			var kmax: int = floori(reach / step_d)
			var bk: PackedFloat32Array = e_bank[e]
			for k: int in kmax + 1:
				var j: int = k if at_a else pts.size() - 1 - k
				var p: Vector3 = pts[j]
				var w: float = 1.0 - smoothstep(reach / 3.0, reach, k * step_d)
				p.y = lerpf(p.y, c.y + g.x * (p.x - c.x) + g.y * (p.z - c.z), w)
				pts[j] = p
				if not bk.is_empty():
					var rt: Vector3 = tangent(e, j).cross(Vector3.UP).normalized()
					bk[j] = lerpf(bk[j], atan(g.x * rt.x + g.y * rt.z), w)
			e_pts[e] = pts
			if not bk.is_empty():
				e_bank[e] = bk


## OSM gores: an arm leaving within ~35 deg of the through road overlaps its lanes for tens of metres. Lay it on the
## through road's surface (height and cross-fall at its lateral offset) until the two slabs part, then blend back to its
## own profile over 60 m, so the overlapping slabs are one surface and a car cannot ride up a climbing ramp.
static func _lock_gores() -> void:
	if not OsmWorld.enabled:
		return
	for n_i: int in nodes.size():
		var ids: PackedInt32Array = node_edges[n_i]
		if ids.size() < 3:
			continue
		var thru: Vector2i = _through_arms(n_i)
		if thru.x < 0:
			continue
		for e: int in ids:
			if e == thru.x or e == thru.y:
				continue
			var de: Vector3 = _arm_out(e, n_i)
			for t: int in [thru.x, thru.y]:
				if de.dot(_arm_out(t, n_i)) > 0.82:
					_lock_arm(e, t, n_i)
					break


static func _lock_arm(e: int, t: int, node: int) -> void:
	var pe: PackedVector3Array = e_pts[e]
	var pt: PackedVector3Array = e_pts[t]
	var ne: int = pe.size()
	var nt: int = pt.size()
	var e_out: bool = e_a[e] == node  # stored order runs away from the node
	var t_out: bool = e_a[t] == node
	var sgn: float = 1.0 if e_out == t_out else -1.0  # bank sign between the two stored orders
	var reach: float = e_width[t] * 0.5 + e_width[e] * 0.5 + 2.3
	var be: PackedFloat32Array = e_bank[e]
	var bt: PackedFloat32Array = e_bank[t]
	var orig := pe.duplicate()
	var orig_b := be.duplicate()
	var j: int = 0
	var last: int = -1
	var limit: int = ne / 2
	for k: int in limit:
		var ie: int = k if e_out else ne - 1 - k
		var p: Vector3 = pe[ie]
		while j + 1 < nt:
			var a0: Vector3 = pt[j if t_out else nt - 1 - j]
			var a1: Vector3 = pt[j + 1 if t_out else nt - 2 - j]
			if Vector2(a1.x - p.x, a1.z - p.z).length_squared() < Vector2(a0.x - p.x, a0.z - p.z).length_squared():
				j += 1
			else:
				break
		var it: int = j if t_out else nt - 1 - j
		var q: Vector3 = pt[it]
		var rt: Vector3 = tangent(t, it).cross(Vector3.UP).normalized()
		var lat: float = (p - q).dot(rt)
		if absf(lat) > reach or j >= nt - 2:
			break
		p.y = q.y + lat * tan(bt[it])
		pe[ie] = p
		be[ie] = bt[it] * sgn
		last = k
	if last < 0:
		return
	var span: int = mini(15, ne - 1 - last - 4)
	var ie_l: int = last if e_out else ne - 1 - last
	var dy: float = pe[ie_l].y - orig[ie_l].y
	var db: float = be[ie_l] - orig_b[ie_l]
	for k: int in range(1, maxi(span, 0) + 1):
		var ie: int = last + k if e_out else ne - 1 - last - k
		var w: float = 1.0 - smoothstep(0.0, 1.0, float(k) / float(span + 1))
		var p: Vector3 = orig[ie]
		p.y += dy * w
		pe[ie] = p
		be[ie] = orig_b[ie] + db * w
	e_pts[e] = pe
	e_bank[e] = be


## The pair of arms at a node that carry straight on (most opposite, higher road class preferred).
static func _through_arms(node: int) -> Vector2i:
	var rank: PackedInt32Array = [3, 1, 1, 1, 2, 1]
	var ids: PackedInt32Array = node_edges[node]
	var best := Vector2i(-1, -1)
	var best_score: float = 1e9
	for a: int in ids.size():
		var da: Vector3 = _arm_out(ids[a], node)
		for b: int in range(a + 1, ids.size()):
			var score: float = da.dot(_arm_out(ids[b], node)) - float(rank[clampi(e_type[ids[a]], 0, 5)] + rank[clampi(e_type[ids[b]], 0, 5)]) * 0.05
			if score < best_score:
				best_score = score
				best = Vector2i(ids[a], ids[b])
	return best


static func _build_fine() -> void:
	_fine = {}
	if not OsmWorld.enabled:
		return
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		for i: int in pts.size():
			var k := Vector2i(floori(pts[i].x / FINE), floori(pts[i].z / FINE))
			if not _fine.has(k):
				_fine[k] = PackedInt32Array()
			_fine[k].append((e << 16) | i)


## True when (wx, wz) lies on the pavement (+ margin) of a road other than own_edge whose surface is within 2.5 m of y.
static func on_other_road(wx: float, wz: float, y: float, own_edge: int, margin: float) -> bool:
	var cx: int = floori(wx / FINE)
	var cz: int = floori(wz / FINE)
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			for code: int in _fine.get(Vector2i(cx + dx, cz + dz), PackedInt32Array()):
				var e: int = code >> 16
				if e == own_edge:
					continue
				var p: Vector3 = e_pts[e][code & 0xFFFF]
				if absf(p.y - y) > 2.5:
					continue
				var r: float = e_width[e] * 0.5 + margin + e_step[e] * 0.5
				if (wx - p.x) * (wx - p.x) + (wz - p.z) * (wz - p.z) < r * r:
					return true
	return false


static func _arm_out(edge: int, node: int) -> Vector3:
	var pts: PackedVector3Array = e_pts[edge]
	var d: Vector3 = pts[mini(4, pts.size() - 1)] - pts[0] if e_a[edge] == node else pts[maxi(pts.size() - 5, 0)] - pts[pts.size() - 1]
	d.y = 0.0
	return d.normalized() if d.length_squared() > 1e-4 else Vector3.FORWARD


static func _bend_pair(node: int, ea: int, eb: int, count: int) -> bool:
	var pa: PackedVector3Array = e_pts[ea]
	var pb: PackedVector3Array = e_pts[eb]
	if count < 2 or pa.size() <= count + 1 or pb.size() <= count + 1:
		return false
	var a_start: bool = e_a[ea] == node
	var b_start: bool = e_a[eb] == node
	var ia: int = count if a_start else pa.size() - 1 - count
	var ib: int = count if b_start else pb.size() - 1 - count
	var p0: Vector3 = pa[ia]
	var p3: Vector3 = pb[ib]
	var tin: Vector3 = (pa[ia - 1] - pa[ia]) if a_start else (pa[ia + 1] - pa[ia])
	var tout: Vector3 = (pb[ib + 1] - pb[ib]) if b_start else (pb[ib - 1] - pb[ib])
	tin.y = 0.0
	tout.y = 0.0
	if tin.length_squared() < 1e-6 or tout.length_squared() < 1e-6:
		return false
	tin = tin.normalized()
	tout = tout.normalized()
	var handle: float = p0.distance_to(p3) * 0.28
	var c1: Vector3 = p0 + tin * handle
	var c2: Vector3 = p3 - tout * handle
	c1.y = lerpf(p0.y, p3.y, 0.35)
	c2.y = lerpf(p0.y, p3.y, 0.65)
	for i: int in count + 1:
		var t_a: float = 0.5 * float(count - i) / float(count) if a_start else 0.5 * float(i) / float(count)
		var idx_a: int = i if a_start else pa.size() - 1 - count + i
		pa[idx_a] = _bez(p0, c1, c2, p3, t_a)
		var t_b: float = 0.5 + 0.5 * float(i) / float(count) if b_start else 1.0 - 0.5 * float(i) / float(count)
		var idx_b: int = i if b_start else pb.size() - 1 - count + i
		pb[idx_b] = _bez(p0, c1, c2, p3, t_b)
	var mid: Vector3 = _bez(p0, c1, c2, p3, 0.5)
	pa[0 if a_start else pa.size() - 1] = mid
	pb[0 if b_start else pb.size() - 1] = mid
	nodes[node] = mid
	e_pts[ea] = pa
	e_pts[eb] = pb
	return true


static func _bez(p0: Vector3, c1: Vector3, c2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u: float = 1.0 - t
	return p0 * (u * u * u) + c1 * (3.0 * u * u * t) + c2 * (3.0 * u * t * t) + p3 * (t * t * t)


static func _drag_endpoint(edge: int, node: int, target: Vector3) -> void:
	var pts: PackedVector3Array = e_pts[edge]
	if pts.size() < 2:
		return
	var at_a: bool = e_a[edge] == node
	var end_i: int = 0 if at_a else pts.size() - 1
	var shift: Vector3 = target - pts[end_i]
	if shift.length_squared() < 1e-4:
		return
	var blend: int = mini(48, pts.size() - 1)
	for i: int in blend + 1:
		var idx: int = i if at_a else pts.size() - 1 - i
		pts[idx] = pts[idx] + shift * (1.0 - float(i) / float(blend))
	pts[end_i] = target
	e_pts[edge] = pts


## Drops short reversals (a point that doubles back within 18 m). The bake leaves a few
## of these where a node sits just off the last straight sample; they kink the collider.
static func _despike(pts: PackedVector3Array) -> PackedVector3Array:
	if pts.size() < 4:
		return pts
	var out := PackedVector3Array()
	out.append(pts[0])
	for i: int in range(1, pts.size() - 1):
		var a: Vector3 = out[out.size() - 1]
		var b: Vector3 = pts[i]
		var c: Vector3 = pts[i + 1]
		var v1 := Vector2(b.x - a.x, b.z - a.z)
		var v2 := Vector2(c.x - b.x, c.z - b.z)
		var l1: float = v1.length()
		var l2: float = v2.length()
		if l1 > 0.05 and l2 > 0.05 and l1 < 18.0 and l2 < 18.0 and v1.dot(v2) < 0.0:
			continue
		out.append(b)
	out.append(pts[pts.size() - 1])
	return out if out.size() >= 2 else pts


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
	var open: Dictionary[Vector2i, int] = {}
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


static func bank(edge: int, i: int) -> float:
	if edge < 0 or edge >= e_bank.size():
		return 0.0
	var b: PackedFloat32Array = e_bank[edge]
	return b[clampi(i, 0, b.size() - 1)] if not b.is_empty() else 0.0


## Right-of-travel vector (includes superelevation roll when banked).
static func right(edge: int, i: int) -> Vector3:
	var rt: Vector3 = tangent(edge, i).cross(Vector3.UP).normalized()
	var b: float = bank(edge, i)
	if absf(b) > 1e-5:
		rt = (rt * cos(b) + Vector3.UP * sin(b)).normalized()
	return rt


## Lateral offset (m, + = right of travel) to the middle of a driving lane.
## `at` picks the local carriageway width where a parallel OSM way narrows the slab; `dir` is the travel direction along the edge.
static func lane_offset(edge: int, at: int = -1, dir: int = 1) -> float:
	var w: float = e_width[edge]
	var off: float = 0.0
	match e_type[edge]:
		HIGHWAY:
			off = w * 0.293  # center of outer right lane (6.45 m of 22)
		COUNTRY:
			off = w * 0.23
		MOUNTAIN:
			off = w * 0.223
		CITY:
			off = w * 0.22
		RURAL:
			off = w * 0.218
	if OsmWorld.enabled and edge >= 0 and edge < e_cap.size() and not e_cap[edge].is_empty():
		# A parallel carriageway narrows only the side facing it. Clamp the line 2.2 m inside both paved
		# edges, plus half the narrowing so the car keeps well clear of the gap between the twins.
		# The cap tapers, so the line drifts and never jumps.
		var idx: int = at if at >= 0 else e_cap[edge].size() / 2
		var hw: float = w * 0.5
		var l_hw: float = side_hw(edge, idx, -float(dir), hw)
		var r_hw: float = side_hw(edge, idx, float(dir), hw)
		var lo: float = -(l_hw - 2.2 - (hw - l_hw) * 0.5)
		var hi: float = r_hw - 2.2 - (hw - r_hw) * 0.5
		off = clampf(off, lo, hi) if lo <= hi else (lo + hi) * 0.5
	return off


## Usable half-width on one side (+1 = right of the edge tangent): hw, or the carriageway cap on the side facing the twin.
static func side_hw(edge: int, i: int, side: float, hw: float) -> float:
	var c: float = slab_cap(edge, i)
	return minf(hw, c) if c < hw and neighbor_side(edge, i) * side > 0.0 else hw


## Slab half-width at a sample. 1e6 means the full paved width (no parallel carriageway).
static func slab_cap(edge: int, i: int) -> float:
	if edge < 0 or edge >= e_cap.size() or e_cap[edge].is_empty():
		return 1.0e6
	var c: PackedFloat32Array = e_cap[edge]
	return c[clampi(i, 0, c.size() - 1)]


## +1 when the nearest parallel carriageway is to the right of travel, -1 to the left, 0 if none.
static func neighbor_side(edge: int, i: int) -> float:
	if edge < 0 or edge >= e_side.size() or e_side[edge].is_empty():
		return 0.0
	var s: PackedFloat32Array = e_side[edge]
	return s[clampi(i, 0, s.size() - 1)]


## True when a parallel way owns the other half, so a centre median would stand in a lane.
static func divided(edge: int) -> bool:
	if edge < 0 or edge >= e_cap.size() or edge >= e_width.size():
		return false
	var hw: float = e_width[edge] * 0.5 - 0.4
	var n: int = 0
	for v: float in e_cap[edge]:
		if v < hw:
			n += 1
	return n > 8


## Keep each OSM carriageway's collider on its own side of the gap. Ways that share a node
## are junctions (already inset), except along the run far from that node.
static func _fit_carriageways() -> void:
	e_cap = []
	e_side = []
	if not OsmWorld.enabled or e_pts.is_empty():
		return
	const CELL: float = 24.0
	var buckets: Dictionary = {}
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		for i: int in pts.size():
			var key := Vector2i(floori(pts[i].x / CELL), floori(pts[i].z / CELL))
			if not buckets.has(key):
				var fresh: Array[Vector2i] = []
				buckets[key] = fresh
			(buckets[key] as Array[Vector2i]).append(Vector2i(e, i))
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		var raw := PackedFloat32Array()
		raw.resize(pts.size())
		raw.fill(1.0e6)
		var sides := PackedFloat32Array()
		sides.resize(pts.size())
		var ph: float = e_width[e] * 0.5
		for i: int in pts.size():
			var p: Vector3 = pts[i]
			var best: float = 1.0e6
			var best_lat: float = 0.0
			var fwd: Vector3 = tangent(e, i)
			var rt: Vector3 = fwd.cross(Vector3.UP)
			var cx: int = floori(p.x / CELL)
			var cz: int = floori(p.z / CELL)
			for dz: int in range(-1, 2):
				for dx: int in range(-1, 2):
					var key := Vector2i(cx + dx, cz + dz)
					if not buckets.has(key):
						continue
					for item: Vector2i in buckets[key]:
						if item.x == e:
							continue
						var oph: float = e_width[item.x] * 0.5
						# A ramp beside a motorway is not the other carriageway. Only a similar-width
						# twin whose pavement overlaps ours gets a split, so the slab is not stacked.
						if oph < ph * 0.55 or oph > ph * 1.8:
							continue
						var q: Vector3 = e_pts[item.x][item.y]
						if absf(q.y - p.y) > 1.5:
							continue  # a road clearly above or below cannot stack on this slab
						if _junction_neighbour(e, item.x, p):
							continue
						if absf(fwd.dot(tangent(item.x, item.y))) < 0.9:
							continue  # crossing or diverging arm, not a parallel carriageway
						var dist: float = Vector2(q.x - p.x, q.z - p.z).length()
						if dist > 1.2 and ph + oph - dist > 3.0 and dist < best:
							best = dist
							best_lat = (q - p).dot(rt)
			if best < 1.0e5:
				raw[i] = maxf(best * 0.5 - 0.2, 2.4)
				sides[i] = signf(best_lat)
		# Taper 1 m per 20 m: the slab edge and the lane line drift, never step, at speed.
		var taper: float = 0.05 * e_step[e]
		for i: int in range(1, raw.size()):
			raw[i] = minf(raw[i], raw[i - 1] + taper)
		for i: int in range(raw.size() - 2, -1, -1):
			raw[i] = minf(raw[i], raw[i + 1] + taper)
		# Tapered samples have no twin point of their own; they keep the side of the nearest one.
		for pass_i: int in 2:
			var carry: float = 0.0
			for k: int in raw.size():
				var i: int = k if pass_i == 0 else raw.size() - 1 - k
				if sides[i] != 0.0:
					carry = sides[i]
				elif raw[i] < 1.0e5:
					sides[i] = carry
		e_cap.append(raw)
		e_side.append(sides)
		# Twins banked about their own centrelines leave a step in the gap between them; keep them flat there.
		var bk: PackedFloat32Array = e_bank[e]
		if not bk.is_empty():
			for i: int in bk.size():
				bk[i] *= clampf((raw[i] - ph) / 6.0, 0.0, 1.0)
			e_bank[e] = bk


static func _junction_neighbour(e: int, other: int, p: Vector3) -> bool:
	var nodes_s: PackedInt32Array = PackedInt32Array()
	if e_a[e] == e_a[other] or e_a[e] == e_b[other]:
		nodes_s.append(e_a[e])
	if e_b[e] == e_a[other] or e_b[e] == e_b[other]:
		nodes_s.append(e_b[e])
	for n: int in nodes_s:
		if p.distance_squared_to(nodes[n]) < 28.0 * 28.0:
			return true
	return false


static func edge_length(edge: int) -> float:
	return e_step[edge] * (e_pts[edge].size() - 1)


## Position at distance `dist` along the edge (clamped).
static func sample(edge: int, dist: float) -> Vector3:
	var pts: PackedVector3Array = e_pts[edge]
	var f: float = clampf(dist / e_step[edge], 0.0, pts.size() - 1.0)
	var i: int = mini(int(f), pts.size() - 2)
	return pts[i].lerp(pts[i + 1], f - i)


## Nearest dense point: {pos, tangent, edge, i} or {} when nothing lies within max_dist.
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
	var km := PackedFloat32Array()
	km.resize(TYPE_NAMES.size())
	for e: int in e_pts.size():
		km[e_type[e]] += edge_length(e) / 1000.0
	return km


static func self_check() -> String:
	if e_pts.is_empty():
		return "no edges loaded"
	for e: int in e_pts.size():
		var pts: PackedVector3Array = e_pts[e]
		# Surveyed endpoints are rounded to 1 cm in the bake; the generator hits the node exactly.
		var end_tol: float = 0.03 if OsmWorld.enabled else 0.01
		if pts[0].distance_to(nodes[e_a[e]]) > end_tol or pts[pts.size() - 1].distance_to(nodes[e_b[e]]) > end_tol:
			return "edge %d does not end on its nodes" % e
		if e_type[e] < 0 or e_type[e] >= TYPE_NAMES.size():
			return "edge %d has an unknown type" % e
		# Real OSM approach ramps exceed the generator caps (worst baked chord is ~0.66).
		# 0.80 still rejects a broken vertical wall.
		var grade_cap: float = 0.80 if OsmWorld.enabled else MAX_GRADE[e_type[e]] + 0.01
		var max_dy: float = grade_cap * e_step[e]
		for i: int in pts.size() - 1:
			var d: float = pts[i].distance_to(pts[i + 1])
			if pts.size() == 2 and d < STEP:
				continue  # connector shorter than one sample
			# Euclidean gap can be under half a step where a hairpin folds inside one sample.
			# A gap over 1.5 steps is a broken resample.
			if d < 0.4 or d > STEP * 1.5:
				return "edge %d spacing %f at %d" % [e, d, i]
			if absf(pts[i + 1].y - pts[i].y) > max_dy:
				return "edge %d too steep at %d" % [e, i]
		for i: int in range(0, pts.size(), 7):
			var found: bool = false
			for r: Vector3i in runs_in_tile(floori(pts[i].x / TILE), floori(pts[i].z / TILE)):
				found = found or (r.x == e and i >= r.y and i <= r.z)
			if not found:
				return "edge %d point %d missing from the index" % [e, i]
	var np: Dictionary = nearest_point(e_pts[0][3] + Vector3(1.0, 5.0, 1.0), 50.0)
	if np.is_empty() or np["edge"] != 0:
		return "nearest_point failed"
	if total_km() < 100.0:
		return "network too short"
	if spawn_edge >= 0:
		for n: int in nodes.size():
			if node_edges[n].size() >= 3 and spawn_pos.distance_to(nodes[n]) < 200.0:
				return "spawn too close to junction node %d" % n
	return ""
