class_name Autodrive
extends RefCounted
## Graph-following AI driver for --autodrive (T19): follows RoadGraph edges across
## junctions with curvature-limited target speed.

var edge: int = 0
var idx: int = 10
var dir: int = 1


func sync_to_world(wpos: Vector3) -> void:
	var np: Dictionary = RoadGraph.nearest_point(wpos)
	if np.is_empty():
		return
	edge = np["edge"]
	idx = np["i"]
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

	var look_w: Vector3 = _ahead_pos(28.0)
	var lane_fwd: Vector3 = RoadGraph.tangent(edge, idx) * dir
	lane_fwd.y = 0.0
	if lane_fwd.length_squared() > 1e-4:  # follow the right-hand lane, not the median
		look_w += lane_fwd.normalized().cross(Vector3.UP) * RoadGraph.lane_offset(edge)
	var look_loc: Vector3 = Origin.to_local(look_w)
	var rel: Vector3 = car.global_transform.inverse() * look_loc
	var ang: float = atan2(rel.x, maxf(-rel.z, 0.5))
	car.in_steer = clampf(ang / deg_to_rad(18.0), -1.0, 1.0)

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
	var node: int = RoadGraph.e_b[edge] if dir > 0 else RoadGraph.e_a[edge]
	var candidates: PackedInt32Array = RoadGraph.node_edges[node]
	var best_e: int = edge
	var best_d: int = -dir
	var best_dot: float = -2.0
	for ce: int in candidates:
		if ce == edge and candidates.size() > 1:
			continue
		var c_dir: int = 1 if RoadGraph.e_a[ce] == node else -1
		var c_i: int = 1 if c_dir > 0 else RoadGraph.e_pts[ce].size() - 2
		var c_fwd: Vector3 = RoadGraph.tangent(ce, clampi(c_i, 0, RoadGraph.e_pts[ce].size() - 1)) * c_dir
		var d: float = cur_fwd.dot(c_fwd)
		if d > best_dot:
			best_dot = d
			best_e = ce
			best_d = c_dir
	edge = best_e
	dir = best_d
	idx = 1 if dir > 0 else RoadGraph.e_pts[edge].size() - 2


func _ahead_pos(dist_m: float) -> Vector3:
	var step_m: float = RoadGraph.e_step[edge]
	var steps: int = maxi(int(dist_m / maxf(step_m, 1.0)), 1)
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var i: int = clampi(idx + dir * steps, 0, pts.size() - 1)
	return pts[i]


func _target_speed(_cur_speed: float) -> float:
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var min_r: float = 400.0
	var prev_t: Vector3 = RoadGraph.tangent(edge, idx) * dir
	prev_t.y = 0.0
	prev_t = prev_t.normalized()
	for k: int in range(3, 28, 3):
		var j: int = clampi(idx + dir * k, 0, pts.size() - 1)
		if j == idx:
			continue
		var t: Vector3 = RoadGraph.tangent(edge, j) * dir
		t.y = 0.0
		t = t.normalized()
		var ds: float = absf(j - idx) * RoadGraph.e_step[edge]
		var ang: float = acos(clampf(prev_t.dot(t), -1.0, 1.0))
		if ang > 0.02:
			min_r = minf(min_r, (ds * 0.5) / ang)
		prev_t = t
		idx = idx  # keep lint clean; scan uses k
	return clampf(sqrt(1.05 * 9.81 * min_r), 36.0 / 3.6, 210.0 / 3.6)
