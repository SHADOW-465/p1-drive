class_name GpsRoute
extends RefCounted
## R6c: one waypoint and the shortest road-graph route (A*) shared by the full
## map, the minimap, and the HUD. A second place() while active clears it.

const ARRIVE_M: float = 32.0
const OFF_M: float = 45.0
const OFF_HOLD: float = 0.40
const TURN_IN: float = 0.49   # ~28 deg, a real junction rather than a gentle bend
const TURN_STEP: float = 0.17 # ~10 deg, ignore shallower kinks
const UTURN_ABS: float = 2.62 # ~150 deg

static var active: bool = false
static var reachable: bool = false
static var waypoint: Vector2 = Vector2.ZERO
static var route_pts: PackedVector2Array = PackedVector2Array()
static var remain_m: float = 0.0
static var total_m: float = 0.0
static var turn_kind: String = ""  # left, right, straight, uturn, arrive, none
static var turn_dist_m: float = 0.0

static var _cum: PackedFloat32Array = PackedFloat32Array()
static var _prog: int = 0
static var _off_t: float = 0.0
static var _car_xz: Vector2 = Vector2.ZERO
static var _fwd: Vector2 = Vector2(0.0, -1.0)
static var _adj_n: int = -1
static var _adj_to: Array[PackedInt32Array] = []
static var _adj_e: Array[PackedInt32Array] = []
static var _adj_len: Array[PackedFloat32Array] = []


static func clear() -> void:
	active = false
	reachable = false
	waypoint = Vector2.ZERO
	route_pts = PackedVector2Array()
	_cum = PackedFloat32Array()
	remain_m = 0.0
	total_m = 0.0
	turn_kind = ""
	turn_dist_m = 0.0
	_prog = 0
	_off_t = 0.0


## Click / key: first call sets the waypoint, the next call clears it.
static func toggle(from_xz: Vector2, click_xz: Vector2) -> void:
	if active:
		clear()
		return
	place(from_xz, click_xz)


static func place(from_xz: Vector2, click_xz: Vector2, max_snap: float = 3000.0) -> bool:
	var snap: Dictionary = _snap_xz(click_xz, max_snap)
	if snap.is_empty():
		return false
	var sp: Vector3 = snap["pos"]
	waypoint = Vector2(sp.x, sp.z)
	active = true
	_build(from_xz)
	return active


static func update(car_w: Vector3, fwd_xz: Vector2, dt: float) -> void:
	if not active:
		return
	_car_xz = Vector2(car_w.x, car_w.z)
	if fwd_xz.length_squared() > 1e-6:
		_fwd = fwd_xz.normalized()
	if _car_xz.distance_to(waypoint) <= ARRIVE_M:
		clear()
		return
	if not reachable:
		_off_t += dt
		if _off_t >= 1.0:
			_off_t = 0.0
			_build(_car_xz)
		return
	var proj: Vector3 = _project(_car_xz)
	if proj.y > OFF_M:
		_off_t += dt
		if _off_t >= OFF_HOLD:
			_off_t = 0.0
			_build(_car_xz)
		return
	_off_t = 0.0
	_prog = int(proj.x)
	remain_m = maxf(total_m - proj.z, 0.0)
	_update_turn()


static func format_dist(metres: float) -> String:
	if metres >= 1000.0:
		return "%.1f km" % (metres / 1000.0)
	return "%d m" % roundi(metres)


static func draw_world(ci: CanvasItem, px_per_m: float) -> void:
	if not active or not reachable or route_pts.size() < 2:
		return
	var ppm: float = maxf(px_per_m, 0.001)
	var w: float = maxf(5.0, 4.2 / ppm)
	ci.draw_polyline(route_pts, Color(0.02, 0.06, 0.09, 0.88), w + 3.0 / ppm, true)
	ci.draw_polyline(route_pts, Color(0.22, 0.95, 1.0, 0.96), w, true)


static func draw_pin(ci: CanvasItem, at: Vector2) -> void:
	ci.draw_circle(at, 12.0, Color(0.02, 0.05, 0.08, 0.55))
	ci.draw_arc(at, 12.0, 0.0, TAU, 22, Color(0.22, 0.95, 1.0, 0.95), 2.0, true)
	var diamond := PackedVector2Array([
		at + Vector2(0.0, -8.0),
		at + Vector2(6.5, 0.0),
		at + Vector2(0.0, 8.0),
		at + Vector2(-6.5, 0.0),
	])
	ci.draw_colored_polygon(diamond, Color(0.04, 0.07, 0.10, 0.96))
	var inner := PackedVector2Array([
		at + Vector2(0.0, -4.6),
		at + Vector2(3.8, 0.0),
		at + Vector2(0.0, 4.6),
		at + Vector2(-3.8, 0.0),
	])
	ci.draw_colored_polygon(inner, Color(0.30, 0.96, 1.0, 1.0))


static func self_check() -> String:
	if RoadGraph.e_pts.is_empty() or RoadGraph.nodes.is_empty():
		return "no roads"
	var direct_bad: String = _check_direct_edges()
	if direct_bad != "":
		return direct_bad
	var join_bad: String = _check_junction()
	if join_bad != "":
		return join_bad
	var off_bad: String = _check_off_route()
	if off_bad != "":
		return off_bad
	clear()
	return ""


static func _planar_len(edge_i: int) -> float:
	var src: PackedVector3Array = RoadGraph.e_pts[edge_i]
	var acc: float = 0.0
	for i: int in range(1, src.size()):
		acc += Vector2(src[i].x - src[i - 1].x, src[i].z - src[i - 1].z).length()
	return acc


static func _poly_len(pts: PackedVector2Array) -> float:
	var acc: float = 0.0
	for i: int in range(1, pts.size()):
		acc += pts[i - 1].distance_to(pts[i])
	return acc


static func _check_direct_edges() -> String:
	for edge_i: int in RoadGraph.e_type.size():
		var last: int = RoadGraph.e_pts[edge_i].size() - 1
		var solved: Dictionary = _solve(edge_i, 0, edge_i, last)
		if not bool(solved.get("ok", false)):
			return "edge %d has no route" % edge_i
		var pts: PackedVector2Array = solved["pts"]
		if pts.size() < 2:
			return "edge %d route is empty" % edge_i
		var el: float = _planar_len(edge_i)
		var got: float = _poly_len(pts)
		if got > el * 1.05 + 25.0 or got < el * 0.90:
			return "edge %d route %.0f m is not the direct edge %.0f m" % [edge_i, got, el]
		var goal: Vector3 = RoadGraph.e_pts[edge_i][last]
		if pts[pts.size() - 1].distance_to(Vector2(goal.x, goal.z)) > 6.0:
			return "edge %d does not end on its node" % edge_i
		for p: int in range(1, pts.size()):
			if pts[p].distance_to(pts[p - 1]) > 90.0:
				return "edge %d has a %.0f m gap" % [edge_i, pts[p].distance_to(pts[p - 1])]
	return ""


static func _check_junction() -> String:
	for edge_i: int in RoadGraph.e_type.size():
		var join: int = RoadGraph.e_b[edge_i]
		var nbrs: PackedInt32Array = RoadGraph.node_edges[join]
		var other: int = -1
		for e: int in nbrs.size():
			if nbrs[e] != edge_i:
				other = nbrs[e]
				break
		if other < 0:
			continue
		var half: int = maxi(RoadGraph.e_pts[other].size() / 2, 1)
		var solved: Dictionary = _solve(edge_i, 0, other, half)
		if not bool(solved.get("ok", false)):
			return "junction %d -> %d failed" % [edge_i, other]
		var pts: PackedVector2Array = solved["pts"]
		var got: float = _poly_len(pts)
		var cap: float = RoadGraph.edge_length(edge_i) + RoadGraph.edge_length(other) * 0.65
		if got > cap * 1.15 + 80.0:
			return "junction %d -> %d route %.0f m exceeds %.0f m" % [edge_i, other, got, cap]
		var goal: Vector3 = RoadGraph.e_pts[other][half]
		if pts.is_empty() or pts[pts.size() - 1].distance_to(Vector2(goal.x, goal.z)) > 8.0:
			return "junction %d -> %d missed the goal" % [edge_i, other]
		if got + 2.0 < pts[0].distance_to(pts[pts.size() - 1]):
			return "junction %d -> %d polyline is shorter than its ends" % [edge_i, other]
		return ""
	return "no junction to test"


static func _check_off_route() -> String:
	var edge_i: int = 0
	var a_id: int = RoadGraph.e_a[edge_i]
	var b_id: int = RoadGraph.e_b[edge_i]
	var pa := Vector2(RoadGraph.nodes[a_id].x, RoadGraph.nodes[a_id].z)
	var pb := Vector2(RoadGraph.nodes[b_id].x, RoadGraph.nodes[b_id].z)
	clear()
	if not place(pa, pb, 80.0) or not active:
		return "off-route setup failed"
	toggle(pa, pb)
	if active:
		return "second toggle did not clear"
	if not place(pa, pb, 80.0):
		return "re-place failed"
	var saved: Vector2 = waypoint
	var far_i: int = -1
	var far_d: float = 0.0
	for n: int in RoadGraph.nodes.size():
		var np := Vector2(RoadGraph.nodes[n].x, RoadGraph.nodes[n].z)
		var d: float = _dist_to_pts(np)
		if d > far_d:
			far_d = d
			far_i = n
	if far_i < 0 or far_d < 150.0:
		return "no point far enough off the route"
	var far := Vector2(RoadGraph.nodes[far_i].x, RoadGraph.nodes[far_i].z)
	update(Vector3(far.x, RoadGraph.nodes[far_i].y, far.y), Vector2(1.0, 0.0), 1.0)
	if not active:
		return "leaving the route cleared the waypoint"
	if not reachable or route_pts.is_empty():
		return "recompute found no route"
	if route_pts[0].distance_to(far) > 70.0:
		return "recompute did not start at the car"
	if waypoint.distance_to(saved) > 1.0:
		return "recompute moved the waypoint"
	return ""


static func _build(from_xz: Vector2) -> void:
	_off_t = 0.0
	_car_xz = from_xz
	var start: Dictionary = _snap_xz(from_xz, 250.0)
	var goal: Dictionary = _snap_xz(waypoint, 40.0)
	if start.is_empty() or goal.is_empty():
		_fail_route()
		return
	var solved: Dictionary = _solve(int(start["edge"]), int(start["i"]), int(goal["edge"]), int(goal["i"]))
	if not bool(solved.get("ok", false)):
		_fail_route()
		return
	var pts: PackedVector2Array = solved["pts"]
	_finalize(pts)
	if total_m <= ARRIVE_M:
		clear()
		return
	reachable = true
	remain_m = total_m
	_prog = 0
	_update_turn()


static func _fail_route() -> void:
	reachable = false
	route_pts = PackedVector2Array()
	_cum = PackedFloat32Array()
	total_m = 0.0
	remain_m = 0.0
	turn_kind = "none"
	turn_dist_m = 0.0


static func _ensure_adj() -> void:
	var n: int = RoadGraph.nodes.size()
	if _adj_n == n and n > 0:
		return
	_adj_n = n
	_adj_to = []
	_adj_e = []
	_adj_len = []
	_adj_to.resize(n)
	_adj_e.resize(n)
	_adj_len.resize(n)
	for i: int in n:
		_adj_to[i] = PackedInt32Array()
		_adj_e[i] = PackedInt32Array()
		_adj_len[i] = PackedFloat32Array()
	for edge_i: int in RoadGraph.e_type.size():
		var a: int = RoadGraph.e_a[edge_i]
		var b: int = RoadGraph.e_b[edge_i]
		var length: float = RoadGraph.edge_length(edge_i)
		_adj_to[a].append(b)
		_adj_e[a].append(edge_i)
		_adj_len[a].append(length)
		if a != b:
			_adj_to[b].append(a)
			_adj_e[b].append(edge_i)
			_adj_len[b].append(length)


## Shortest path between two samples. Points on the same edge stay on it: leaving
## an edge is only possible at its endpoints, and the shorter along-edge direction
## is never beaten by a path that detours through those endpoints.
static func _solve(se: int, si: int, ge: int, gi: int) -> Dictionary:
	var empty := PackedVector2Array()
	if se < 0 or ge < 0:
		return {"ok": false, "pts": empty}
	if se == ge:
		var same := _span(se, si, gi)
		if same.size() < 2:
			return {"ok": false, "pts": empty}
		return {"ok": true, "pts": _simplify(same)}
	_ensure_adj()
	var n_nodes: int = RoadGraph.nodes.size()
	var g_cost := PackedFloat32Array()
	g_cost.resize(n_nodes)
	g_cost.fill(1.0e9)
	var parent := PackedInt32Array()
	parent.resize(n_nodes)
	parent.fill(-1)
	var via := PackedInt32Array()
	via.resize(n_nodes)
	via.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n_nodes)

	var s_pts: int = RoadGraph.e_pts[se].size()
	var s_step: float = RoadGraph.e_step[se]
	var sa: int = RoadGraph.e_a[se]
	var sb: int = RoadGraph.e_b[se]
	g_cost[sa] = float(si) * s_step
	g_cost[sb] = float(s_pts - 1 - si) * s_step
	var open: Array[int] = [sa]
	if sb != sa:
		open.append(sb)

	var g_pts: int = RoadGraph.e_pts[ge].size()
	var g_step: float = RoadGraph.e_step[ge]
	var ga: int = RoadGraph.e_a[ge]
	var gb: int = RoadGraph.e_b[ge]
	var tail_a: float = float(gi) * g_step
	var tail_b: float = float(g_pts - 1 - gi) * g_step
	var goal_at: Vector3 = RoadGraph.e_pts[ge][gi]
	var goal_xz := Vector2(goal_at.x, goal_at.z)

	var best: float = 1.0e9
	var best_node: int = -1
	var seed_pick: Vector2 = _consider(sa, g_cost[sa], ga, gb, tail_a, tail_b)
	if seed_pick.y < best:
		best = seed_pick.y
		best_node = int(seed_pick.x)
	if sb != sa:
		seed_pick = _consider(sb, g_cost[sb], ga, gb, tail_a, tail_b)
		if seed_pick.y < best:
			best = seed_pick.y
			best_node = int(seed_pick.x)

	var guard: int = 0
	while not open.is_empty() and guard < n_nodes * 12:
		guard += 1
		var pick: int = 0
		var pick_f: float = g_cost[open[0]] + _h(open[0], goal_xz)
		for k: int in range(1, open.size()):
			var f: float = g_cost[open[k]] + _h(open[k], goal_xz)
			if f < pick_f:
				pick_f = f
				pick = k
		var u: int = open[pick]
		open.remove_at(pick)
		if closed[u] == 1:
			continue
		if pick_f >= best:
			break
		closed[u] = 1
		var arrived: Vector2 = _consider(u, g_cost[u], ga, gb, tail_a, tail_b)
		if arrived.y < best:
			best = arrived.y
			best_node = int(arrived.x)
		var nbrs: PackedInt32Array = _adj_to[u]
		for j: int in nbrs.size():
			var v: int = nbrs[j]
			if closed[v] == 1:
				continue
			var ng: float = g_cost[u] + _adj_len[u][j]
			if ng + 0.05 < g_cost[v]:
				g_cost[v] = ng
				parent[v] = u
				via[v] = _adj_e[u][j]
				open.append(v)

	if best_node < 0:
		return {"ok": false, "pts": empty}

	var chain := PackedInt32Array()
	var via_e := PackedInt32Array()
	var cursor: int = best_node
	var steps: int = 0
	while cursor >= 0 and steps < n_nodes + 2:
		steps += 1
		chain.append(cursor)
		var prev: int = parent[cursor]
		if prev < 0:
			break
		via_e.append(via[cursor])
		cursor = prev
	if steps >= n_nodes + 2 or chain.is_empty():
		return {"ok": false, "pts": empty}
	chain.reverse()
	via_e.reverse()
	if via_e.size() > 0 and via_e[via_e.size() - 1] == ge:
		via_e.resize(via_e.size() - 1)
		chain.resize(chain.size() - 1)
		best_node = chain[chain.size() - 1]

	var raw := PackedVector2Array()
	var exit_node: int = chain[0]
	if exit_node == sb:
		_span_into(raw, se, si, s_pts - 1)
	elif exit_node == sa:
		_span_into(raw, se, si, 0)
	else:
		return {"ok": false, "pts": empty}
	for k: int in via_e.size():
		var edge_i: int = via_e[k]
		var from_n: int = chain[k]
		var to_n: int = chain[k + 1]
		var last_i: int = RoadGraph.e_pts[edge_i].size() - 1
		if RoadGraph.e_a[edge_i] == from_n and RoadGraph.e_b[edge_i] == to_n:
			_span_into(raw, edge_i, 0, last_i)
		elif RoadGraph.e_b[edge_i] == from_n and RoadGraph.e_a[edge_i] == to_n:
			_span_into(raw, edge_i, last_i, 0)
		else:
			return {"ok": false, "pts": empty}
	if best_node == ga:
		_span_into(raw, ge, 0, gi)
	elif best_node == gb:
		_span_into(raw, ge, g_pts - 1, gi)
	else:
		return {"ok": false, "pts": empty}
	if raw.size() < 2:
		return {"ok": false, "pts": empty}
	return {"ok": true, "pts": _simplify(raw)}


## Returns (node, cost) when `node` is an end of the goal edge, else (-1, inf).
static func _consider(node: int, cost: float, ga: int, gb: int, tail_a: float, tail_b: float) -> Vector2:
	var best_c: float = 1.0e9
	var best_n: int = -1
	if node == ga and cost + tail_a < best_c:
		best_c = cost + tail_a
		best_n = ga
	if node == gb and cost + tail_b < best_c:
		best_c = cost + tail_b
		best_n = gb
	return Vector2(best_n, best_c)


static func _h(node: int, goal_xz: Vector2) -> float:
	var p: Vector3 = RoadGraph.nodes[node]
	return Vector2(p.x, p.z).distance_to(goal_xz)


static func _span(edge_i: int, i0: int, i1: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	_span_into(pts, edge_i, i0, i1)
	return pts


static func _span_into(pts: PackedVector2Array, edge_i: int, i0: int, i1: int) -> void:
	var src: PackedVector3Array = RoadGraph.e_pts[edge_i]
	var dir: int = 1 if i1 >= i0 else -1
	var i: int = clampi(i0, 0, src.size() - 1)
	var end_i: int = clampi(i1, 0, src.size() - 1)
	while true:
		var p: Vector3 = src[i]
		_push(pts, Vector2(p.x, p.z))
		if i == end_i:
			return
		i += dir


static func _push(pts: PackedVector2Array, p: Vector2) -> void:
	if pts.is_empty() or pts[pts.size() - 1].distance_squared_to(p) > 0.16:
		pts.append(p)


static func _simplify(src: PackedVector2Array) -> PackedVector2Array:
	var count: int = src.size()
	if count < 3:
		return src
	var out := PackedVector2Array()
	out.append(src[0])
	var last: Vector2 = src[0]
	var last_dir: Vector2 = src[1] - src[0]
	if last_dir.length_squared() > 1e-6:
		last_dir = last_dir.normalized()
	for i: int in range(1, count - 1):
		var cur: Vector2 = src[i]
		var nxt: Vector2 = src[i + 1]
		var seg: Vector2 = nxt - cur
		var keep: bool = cur.distance_to(last) >= 10.0  # tight OSM corners lose >10% of their length at 24 m
		var look: Vector2 = src[mini(i + 4, count - 1)]
		var chord: Vector2 = look - last
		if chord.length_squared() > 1.0:
			var u: float = clampf((cur - last).dot(chord) / chord.length_squared(), 0.0, 1.0)
			if cur.distance_to(last + chord * u) > 1.2 and cur.distance_to(last) >= 4.0:
				keep = true
		if seg.length_squared() > 1.0:
			var dir: Vector2 = seg.normalized()
			if last_dir.length_squared() > 0.5 and last_dir.dot(dir) < 0.982 and cur.distance_to(last) >= 4.0:
				keep = true
			last_dir = dir
		if keep:
			out.append(cur)
			last = cur
	var end_pt: Vector2 = src[count - 1]
	if out[out.size() - 1].distance_squared_to(end_pt) > 0.16:
		out.append(end_pt)
	return out


static func _finalize(pts: PackedVector2Array) -> void:
	route_pts = pts
	_cum = PackedFloat32Array()
	_cum.resize(pts.size())
	var acc: float = 0.0
	if not pts.is_empty():
		_cum[0] = 0.0
	for i: int in range(1, pts.size()):
		acc += pts[i - 1].distance_to(pts[i])
		_cum[i] = acc
	total_m = acc


static func _project(xz: Vector2) -> Vector3:
	var n: int = route_pts.size()
	if n < 2:
		return Vector3(0.0, 1.0e9, 0.0)
	var lo: int = maxi(_prog - 6, 0)
	var hi: int = mini(_prog + 48, n - 2)
	var best: Vector3 = _project_range(xz, lo, hi)
	if best.y > 30.0:
		best = _project_range(xz, 0, n - 2)
	return best


static func _project_range(xz: Vector2, lo: int, hi: int) -> Vector3:
	var best_d: float = 1.0e12
	var best_i: int = lo
	var best_along: float = 0.0
	for i: int in range(lo, hi + 1):
		var a: Vector2 = route_pts[i]
		var b: Vector2 = route_pts[i + 1]
		var ab: Vector2 = b - a
		var l2: float = ab.length_squared()
		var t: float = 0.0
		if l2 > 1e-4:
			t = clampf((xz - a).dot(ab) / l2, 0.0, 1.0)
		var proj: Vector2 = a + ab * t
		var d: float = xz.distance_squared_to(proj)
		if d < best_d:
			best_d = d
			best_i = i
			best_along = _cum[i] + a.distance_to(proj)
	return Vector3(float(best_i), sqrt(best_d), best_along)


static func _dist_to_pts(xz: Vector2) -> float:
	if route_pts.size() < 2:
		return 1.0e9
	return _project_range(xz, 0, route_pts.size() - 2).y


static func _update_turn() -> void:
	if not reachable or route_pts.size() < 2:
		turn_kind = "none"
		turn_dist_m = 0.0
		return
	var ahead: Vector2 = _ahead_dir(_prog)
	if ahead.length_squared() > 0.5 and _fwd.length_squared() > 0.5 and ahead.dot(_fwd) < -0.35:
		turn_kind = "uturn"
		turn_dist_m = 0.0
		return
	var acc: float = 0.0
	var since: float = 0.0
	var dist: float = _dist_to_vertex(_prog)
	var prev: Vector2 = ahead
	for k: int in range(_prog + 1, route_pts.size() - 1):
		var step: Vector2 = route_pts[k + 1] - route_pts[k]
		var step_len: float = step.length()
		if step_len < 1.0:
			continue
		var dir: Vector2 = step / step_len
		if prev.length_squared() > 0.5:
			var cross: float = prev.x * dir.y - prev.y * dir.x
			var ang: float = atan2(cross, clampf(prev.dot(dir), -1.0, 1.0))
			if absf(ang) >= TURN_STEP:
				acc += ang
				since = 0.0
			else:
				since += step_len
				if since > 70.0:
					acc = 0.0
		prev = dir
		dist += step_len
		if absf(acc) >= TURN_IN and dist > 16.0:
			if absf(acc) >= UTURN_ABS:
				turn_kind = "uturn"
			elif acc > 0.0:
				turn_kind = "right"
			else:
				turn_kind = "left"
			turn_dist_m = dist
			return
	turn_dist_m = remain_m
	turn_kind = "arrive" if remain_m < 700.0 else "straight"


static func _ahead_dir(i: int) -> Vector2:
	if i < 0 or i >= route_pts.size():
		return Vector2.ZERO
	var origin: Vector2 = route_pts[i]
	for j: int in range(i + 1, route_pts.size()):
		var d: Vector2 = route_pts[j] - origin
		if d.length_squared() > 144.0:
			return d.normalized()
	if i + 1 < route_pts.size():
		var d2: Vector2 = route_pts[i + 1] - origin
		if d2.length_squared() > 0.01:
			return d2.normalized()
	return Vector2.ZERO


static func _dist_to_vertex(i: int) -> float:
	if i < 0 or i + 1 >= route_pts.size():
		return 0.0
	var a: Vector2 = route_pts[i]
	var b: Vector2 = route_pts[i + 1]
	var ab: Vector2 = b - a
	var l2: float = ab.length_squared()
	var t: float = 0.0
	if l2 > 1e-4:
		t = clampf((_car_xz - a).dot(ab) / l2, 0.0, 1.0)
	return a.lerp(b, t).distance_to(b)


static func _snap_xz(xz: Vector2, max_dist: float) -> Dictionary:
	var found: Dictionary = _snap_tiles(xz, max_dist)
	if not found.is_empty() or max_dist <= RoadGraph.TILE:
		return found
	var best: float = max_dist * max_dist
	var be: int = -1
	var bi: int = 0
	for edge_i: int in RoadGraph.e_pts.size():
		var pts: PackedVector3Array = RoadGraph.e_pts[edge_i]
		for i: int in pts.size():
			var d: float = Vector2(pts[i].x, pts[i].z).distance_squared_to(xz)
			if d < best:
				best = d
				be = edge_i
				bi = i
	if be < 0:
		return {}
	return {"edge": be, "i": bi, "pos": RoadGraph.e_pts[be][bi]}


static func _snap_tiles(xz: Vector2, max_dist: float) -> Dictionary:
	var best: float = max_dist * max_dist
	var be: int = -1
	var bi: int = 0
	var tile := Vector2i(floori(xz.x / RoadGraph.TILE), floori(xz.y / RoadGraph.TILE))
	var rad: int = clampi(int(ceil(max_dist / RoadGraph.TILE)), 0, 16)
	for dz: int in range(-rad, rad + 1):
		for dx: int in range(-rad, rad + 1):
			var runs: Array = RoadGraph.runs_in_tile(tile.x + dx, tile.y + dz)
			for r: Vector3i in runs:
				var pts: PackedVector3Array = RoadGraph.e_pts[r.x]
				var last: int = mini(r.z, pts.size() - 1)
				for i: int in range(maxi(r.y, 0), last + 1):
					var d: float = Vector2(pts[i].x, pts[i].z).distance_squared_to(xz)
					if d < best:
						best = d
						be = r.x
						bi = i
	if be < 0:
		return {}
	return {"edge": be, "i": bi, "pos": RoadGraph.e_pts[be][bi]}
