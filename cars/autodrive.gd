class_name Autodrive
extends RefCounted
## Graph-following AI driver for --autodrive (T19): follows RoadGraph edges across
## junctions with curvature-limited target speed.

const WHEELBASE: float = 2.7  # m, all four cars are 2.6-2.8

var edge: int = 0
var idx: int = 10
var dir: int = 1


func sync_to_world(wpos: Vector3, fwd: Vector3 = Vector3.ZERO) -> void:
	var np: Dictionary = RoadGraph.nearest_point(wpos)
	if np.is_empty():
		return
	edge = np["edge"]
	idx = np["i"]
	if fwd.length_squared() > 1e-4:
		dir = 1 if RoadGraph.tangent(edge, idx).dot(fwd) >= 0.0 else -1
	else:
		dir = 1


func drive(car: Car) -> void:
	if RoadGraph.e_pts.is_empty():
		return
	var wpos: Vector3 = Origin.to_world(car.position)
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	# Advance along the current edge while behind the car.
	for _step: int in 24:
		var t: Vector3 = RoadGraph.tangent(edge, idx) * dir
		if (wpos - pts[idx]).dot(t) <= 0.0:
			break
		var nxt: int = idx + dir
		if nxt < 0 or nxt >= pts.size():
			_pick_next_edge(t)
			pts = RoadGraph.e_pts[edge]
			break
		idx = nxt

	# Pure pursuit on the lane line: the wheel angle that arcs the car through a point ld ahead, as a fraction of
	# the car's speed-dependent steering lock. (A fixed 18 deg-per-full-lock gain was 4-8x too sharp below
	# 150 km/h and weaved the car off narrow OSM streets.)
	var ld: float = clampf(4.0 + 0.3 * car.speed, 8.0, 30.0)
	var tgt: Array = _ahead(ld)
	var look_w: Vector3 = tgt[0]
	var lane_fwd: Vector3 = RoadGraph.tangent(tgt[1], tgt[2]) * float(tgt[3])
	lane_fwd.y = 0.0
	if lane_fwd.length_squared() > 1e-4:  # follow the right-hand lane, not the median
		look_w += lane_fwd.normalized().cross(Vector3.UP) * RoadGraph.lane_offset(tgt[1], tgt[2], tgt[3])
	var rel: Vector3 = car.global_transform.inverse() * Origin.to_local(look_w)
	var dist: float = maxf(Vector2(rel.x, rel.z).length(), 1.0)
	var alpha: float = atan2(rel.x, maxf(-rel.z, 0.5))
	var wheel: float = atan(2.0 * WHEELBASE * sin(alpha) / dist)
	car.in_steer = clampf(wheel / deg_to_rad(car._max_steer_deg(car.speed_kmh)), -1.0, 1.0)

	var v_target: float = _target_speed(car.speed)
	var err: float = v_target - car.speed
	if err > 1.5:
		car.in_throttle = clampf(err * 0.14, 0.15, 0.95)
		car.in_brake = 0.0
	elif err < -2.0:
		car.in_throttle = 0.0
		car.in_brake = clampf(-err * 0.12, 0.05, 0.85)
	else:
		car.in_throttle = 0.25 if err > 0.0 else 0.0
		car.in_brake = 0.0
	car.in_handbrake = false
	car.in_drs = false


func _pick_next_edge(cur_fwd: Vector3) -> void:
	var nx: Vector3i = _next_edge(cur_fwd)
	edge = nx.x
	dir = nx.y
	idx = nx.z


## The edge the car takes at the node ahead: the best-aligned one. Vector3i(edge, dir, first idx).
func _next_edge(cur_fwd: Vector3) -> Vector3i:
	return _next_edge_from(edge, dir, cur_fwd)


static func _next_edge_from(from_e: int, from_d: int, cur_fwd: Vector3) -> Vector3i:
	var node: int = RoadGraph.e_b[from_e] if from_d > 0 else RoadGraph.e_a[from_e]
	var candidates: PackedInt32Array = RoadGraph.node_edges[node]
	var best_e: int = from_e
	var best_d: int = -from_d
	var best_dot: float = -2.0
	for ce: int in candidates:
		if ce == from_e and candidates.size() > 1:
			continue
		var c_dir: int = 1 if RoadGraph.e_a[ce] == node else -1
		var d: float = cur_fwd.dot(_start_fwd(ce, c_dir))
		var far: int = RoadGraph.e_b[ce] if c_dir > 0 else RoadGraph.e_a[ce]
		if RoadGraph.node_edges[far].size() < 2:
			d -= 3.0  # a dead end (OSM cut at the map edge) only when nothing else leaves the node
		if d > best_dot:
			best_dot = d
			best_e = ce
			best_d = c_dir
	return Vector3i(best_e, best_d, 1 if best_d > 0 else RoadGraph.e_pts[best_e].size() - 2)


## The next `count` route samples from the car's index on, carried across nodes the way the car will drive them.
func route_points(count: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var e: int = edge
	var d: int = dir
	var i: int = idx
	for _hop: int in 8:
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		while i >= 0 and i < pts.size() and out.size() < count:
			out.append(pts[i])
			i += d
		if out.size() >= count:
			break
		var end_i: int = pts.size() - 1 if d > 0 else 0
		var nx: Vector3i = _next_edge_from(e, d, RoadGraph.tangent(e, end_i) * d)
		e = nx.x
		d = nx.y
		i = nx.z
	return out


static func _start_fwd(e: int, d: int) -> Vector3:
	var c_i: int = 1 if d > 0 else RoadGraph.e_pts[e].size() - 2
	return RoadGraph.tangent(e, clampi(c_i, 0, RoadGraph.e_pts[e].size() - 1)) * d


## Point dist_m ahead along the route, carried across the node onto the edge the car will take.
func _ahead_pos(dist_m: float) -> Vector3:
	return _ahead(dist_m)[0]


## [world point, edge, index, dir] dist_m along the route from the car's index (across up to 8 nodes).
func _ahead(dist_m: float) -> Array:
	var e: int = edge
	var d: int = dir
	var i: int = idx
	var left: float = dist_m
	for _hop: int in 8:
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var step_m: float = maxf(RoadGraph.e_step[e], 1.0)
		var room: float = float(pts.size() - 1 - i if d > 0 else i) * step_m
		if left <= room:
			var j: int = clampi(i + d * roundi(left / step_m), 0, pts.size() - 1)
			return [pts[j], e, j, d]
		left -= room
		var end_i: int = pts.size() - 1 if d > 0 else 0
		var nx: Vector3i = _next_edge_from(e, d, RoadGraph.tangent(e, end_i) * d)
		e = nx.x
		d = nx.y
		i = nx.z
	return [RoadGraph.e_pts[e][i], e, i, d]


## Highest speed (m/s) from which the car can still brake (6 m/s^2) into the turn at the node ahead, taken as an arc
## of ~20 m. A straight continuation (or a node far away) does not limit.
func junction_cap() -> float:
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var end_i: int = pts.size() - 1 if dir > 0 else 0
	var dist: float = absf(end_i - idx) * RoadGraph.e_step[edge]
	if dist > 260.0:
		return 1e3
	var fwd: Vector3 = RoadGraph.tangent(edge, end_i) * dir
	var nx: Vector3i = _next_edge(fwd)
	fwd.y = 0.0
	var nf: Vector3 = _start_fwd(nx.x, nx.y)
	nf.y = 0.0
	if fwd.length_squared() < 1e-6 or nf.length_squared() < 1e-6:
		return 1e3
	var turn: float = acos(clampf(fwd.normalized().dot(nf.normalized()), -1.0, 1.0))
	if turn < 0.08:
		return 1e3
	var v_turn: float = sqrt(1.05 * 9.81 * 20.0 / turn)
	return sqrt(v_turn * v_turn + 2.0 * 6.0 * dist)


## Highest speed (m/s) from which every bend in the next ~320 m of the route (across nodes) can still be taken:
## v(r) = sqrt(0.95 g r) at the bend, reached by braking at 6 m/s^2 over the distance to it.
func _target_speed(_cur_speed: float) -> float:
	var pts: PackedVector3Array = route_points(80)
	var v_max: float = 210.0 / 3.6
	var s: float = 0.0
	for k: int in range(1, pts.size()):
		s += Vector2(pts[k].x - pts[k - 1].x, pts[k].z - pts[k - 1].z).length()
		if k < 5 or k + 5 >= pts.size():
			continue
		var a := Vector2(pts[k].x - pts[k - 5].x, pts[k].z - pts[k - 5].z)
		var b := Vector2(pts[k + 5].x - pts[k].x, pts[k + 5].z - pts[k].z)
		var ang: float = absf(a.angle_to(b))
		if ang < 0.02:
			continue
		var r: float = (a.length() + b.length()) * 0.5 / ang
		v_max = minf(v_max, sqrt(0.95 * 9.81 * r + 2.0 * 6.0 * maxf(s - 10.0, 0.0)))
	return maxf(v_max, 36.0 / 3.6)
