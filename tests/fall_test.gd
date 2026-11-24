extends Node
## Gate (fall): drives a river road and a motorway interchange at speed.
## Fails if the body drops below the road/terrain surface. Prints FALL PASS / FALL FAIL.

var main: Node3D
var car: Car
var world: TileStreamer
var phase: int = 0
var f: int = 0
var _phase_ms: int = 0
var fail: String = ""

var _edge: int = 0
var _idx: int = 0
var _dir: int = 1
var _river_e: int = -1
var _fast_e: int = -1
var _fast_i: int = 0
var _fast_dir: int = 1
var _ic: Vector3 = Vector3.ZERO
var _prev: Vector2 = Vector2.ZERO
var _travel: float = 0.0
var _river_m: float = 0.0
var _fast_m: float = 0.0
var _max_kmh: float = 0.0
var _min_clear: float = 100.0
var _passed_ic: bool = false
var _shot: bool = false
var _tiles: Dictionary[Vector2i, bool] = {}
var _park_w: Vector2 = Vector2.ZERO


func _ready() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	main.call("_swap_car", "mclaren_p1_vecarz")  # the real P1 (resolves to the code-built one when assets_nc is absent)
	car = main.get_node(^"P1") as Car
	world = main.get_node(^"World") as TileStreamer
	_phase_ms = Time.get_ticks_msec()


func _physics_process(_dt: float) -> void:
	if fail != "":
		return
	f += 1
	match phase:
		0:
			if not car.freeze:
				if not _pick_routes():
					_finish(fail)
					return
				car.player_controlled = false
				_park(_river_e, 24, 1)
				phase = 1
				f = 0
				_phase_ms = Time.get_ticks_msec()
			elif f > 14400 and _wall_s() > 60.0:  # same rule as phase 1: tile jobs run on wall time
				_finish("boot timeout")
		1:
			if _settled():
				_launch()
				phase = 2
				f = 0
				_phase_ms = Time.get_ticks_msec()
			elif f > 7200 and _wall_s() > 60.0:  # tile jobs run on threads in wall time; a light frame must not out-run them
				_finish("river tiles did not ready")
		2:
			_drive(false)
			if fail != "":
				_finish(fail)
			elif _river_m >= 180.0 and _travel >= 750.0:
				print("river leg %.0f m on water roads, max %.0f km/h, clear %.2f" % [_river_m, _max_kmh, _min_clear])
				_park(_fast_e, _fast_i, _fast_dir)
				phase = 3
				f = 0
				_phase_ms = Time.get_ticks_msec()
			elif f > 5400:
				_finish("river leg short (on-road %.0f m, river %.0f m, max %.0f km/h, now %.0f km/h, %d wheels)" % [_travel, _river_m, _max_kmh, car.speed_kmh, car.wheels_in_contact()])
		3:
			if _settled():
				_launch()
				phase = 4
				f = 0
				_phase_ms = Time.get_ticks_msec()
			elif f > 7200 and _wall_s() > 60.0:
				_finish("interchange tiles did not ready")
		4:
			_drive(true)
			if fail != "":
				_finish(fail)
			elif _passed_ic and _fast_m >= 1200.0 and _tiles.size() >= 2 and _max_kmh >= 250.0:
				_finish("")
			elif f > 5400:
				_finish("fast leg short (%.0f m at speed, tiles %d, interchange %s, max %.0f)" % [_fast_m, _tiles.size(), str(_passed_ic), _max_kmh])


func _pick_routes() -> bool:
	_river_e = _best_river_edge()
	if _river_e < 0:
		fail = "no river road to drive"
		return false
	if not _best_fast_leg():
		fail = "no straight motorway interchange"
		return false
	var rp: Vector3 = RoadGraph.e_pts[_river_e][24]
	print("fall route river edge %d at (%.0f, %.0f), highway edge %d toward (%.0f, %.0f)" % [_river_e, rp.x, rp.z, _fast_e, _ic.x, _ic.z])
	return true


func _best_river_edge() -> int:
	var best_e: int = -1
	var best_score: float = -1.0
	for e: int in RoadGraph.e_pts.size():
		if RoadGraph.e_kind[e] != RoadGraph.KIND_ROAD or RoadGraph.e_elev[e] != 0:
			continue
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		if pts.size() < 80:
			continue
		var near: int = 0
		for i: int in range(0, pts.size(), 6):
			var rq: Vector4 = TerrainFn.river_query(pts[i].x, pts[i].z)
			if rq.x < rq.z + 150.0 and rq.w > 0.04 and rq.w < 0.96:
				near += 1
		if near < 4:
			continue
		var rad: float = _window_radius(e, 20, 1, 1200.0)
		var score: float = float(near) * minf(rad, 900.0)
		if score > best_score:
			best_score = score
			best_e = e
	return best_e


func _best_fast_leg() -> bool:
	var best_r: float = 0.0
	for n: int in RoadGraph.nodes.size():
		var ids: PackedInt32Array = RoadGraph.node_edges[n]
		if ids.size() < 3:
			continue
		for e: int in ids:
			if RoadGraph.e_type[e] != RoadGraph.HIGHWAY or RoadGraph.e_pts[e].size() < 220:
				continue
			var toward_a: bool = RoadGraph.e_a[e] == n
			if not _drive_through(n, e):
				continue  # a motorway terminus whose ramps all turn back is not an interchange to drive through
			var dir: int = -1 if toward_a else 1
			var idx: int = 150 if dir < 0 else RoadGraph.e_pts[e].size() - 151
			idx = clampi(idx, 8, RoadGraph.e_pts[e].size() - 9)
			var rad: float = _window_radius(e, idx, dir, 1600.0)
			if rad > best_r:
				best_r = rad
				_fast_e = e
				_fast_i = idx
				_fast_dir = dir
				_ic = RoadGraph.nodes[n]
	return _fast_e >= 0 and best_r >= 360.0


## True when node n carries the motorway on straight (within 10 deg) from edge e.
func _drive_through(n: int, e: int) -> bool:
	var travel: Vector3 = -RoadMesher._out_dir_xz(e, n)
	for o: int in RoadGraph.node_edges[n]:
		if o != e and RoadGraph.e_type[o] == RoadGraph.HIGHWAY and RoadMesher._out_dir_xz(o, n).dot(travel) > 0.985:
			return true
	return false


func _window_radius(edge: int, idx: int, dir: int, meters: float) -> float:
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var step_m: float = RoadGraph.e_step[edge]
	var prev: Vector3 = RoadGraph.tangent(edge, idx) * float(dir)
	prev.y = 0.0
	if prev.length_squared() < 1e-6:
		return 0.0
	prev = prev.normalized()
	var min_r: float = 5000.0
	var walked: float = 0.0
	var j: int = idx
	while walked < meters:
		var nxt: int = j + dir * 8
		if nxt < 0 or nxt >= pts.size():
			break
		var t: Vector3 = RoadGraph.tangent(edge, nxt) * float(dir)
		t.y = 0.0
		t = t.normalized()
		var ang: float = acos(clampf(prev.dot(t), -1.0, 1.0))
		var ds: float = absf(nxt - j) * step_m
		if ang > 0.02:
			min_r = minf(min_r, ds / ang)
		prev = t
		walked += ds
		j = nxt
	return min_r


func _park(edge: int, idx: int, dir: int) -> void:
	_edge = edge
	_idx = idx
	_dir = dir
	_travel = 0.0
	_prev = Vector2.ZERO
	var pts: PackedVector3Array = RoadGraph.e_pts[edge]
	var travel: Vector3 = RoadGraph.tangent(edge, idx) * float(dir)
	travel.y = 0.0
	if travel.length_squared() < 1e-6:
		travel = Vector3.FORWARD
	travel = travel.normalized()
	var wpos: Vector3 = pts[idx] + travel.cross(Vector3.UP) * RoadGraph.lane_offset(edge, idx, dir)
	_park_w = Vector2(wpos.x, wpos.z)
	# Body origin sits about at road height when the wheels are at rest.
	wpos.y += 0.2
	car.freeze = true
	car.player_controlled = false
	var local: Vector3 = Origin.to_local(wpos)
	car.teleport(Transform3D(Basis.looking_at(travel, Vector3.UP), local))
	var rig: CameraRig = main.get("rig") as CameraRig
	if rig != null:
		rig.snap()
	_prev = Vector2(wpos.x, wpos.z)


func _wall_s() -> float:
	return (Time.get_ticks_msec() - _phase_ms) / 1000.0


func _settled() -> bool:
	var wpos: Vector3 = Origin.to_world(car.position)
	if Vector2(wpos.x - _park_w.x, wpos.z - _park_w.y).length() > 40.0:
		return false
	var key := Vector2i(floori(wpos.x / TileGen.TILE), floori(wpos.z / TileGen.TILE))
	return world.centre == key and world.is_live(key, TileGen.FULL) and world.is_ready()


func _launch() -> void:
	_travel = 0.0
	_prev = Vector2(Origin.to_world(car.position).x, Origin.to_world(car.position).z)
	car.freeze = false
	car.player_controlled = false


func _drive(fast: bool) -> void:
	var wpos: Vector3 = Origin.to_world(car.position)
	_follow(wpos)
	var travel: Vector3 = RoadGraph.tangent(_edge, _idx) * float(_dir)
	travel.y = 0.0
	var lane: Vector3 = RoadGraph.e_pts[_edge][_idx]
	if travel.length_squared() > 1e-6:
		travel = travel.normalized()
		lane += travel.cross(Vector3.UP) * RoadGraph.lane_offset(_edge, _idx, _dir)
	var lat: float = Vector2(wpos.x - lane.x, wpos.z - lane.z).length()
	var step: float = Vector2(wpos.x - _prev.x, wpos.z - _prev.y).length()
	_prev = Vector2(wpos.x, wpos.z)
	if step < 80.0:
		_travel += step
		if lat < 12.0 and _near_river(wpos):
			_river_m += step
	var support: float = float(main.call("surface_y", wpos))
	var clear: float = wpos.y - support
	_min_clear = minf(_min_clear, clear)
	if clear < -1.7 or int(main.get("fall_count")) > 0:
		fail = "dropped %.2f m under the surface at (%.0f, %.0f) speed %.0f" % [clear, wpos.x, wpos.z, car.speed_kmh]
		return
	_max_kmh = maxf(_max_kmh, car.speed_kmh)
	var cap: float = 72.0 if fast else minf(72.0, sqrt(maxf(_ahead_radius(), 40.0) * 7.5))
	var fwd: Vector3 = -car.global_basis.z
	fwd.y = 0.0
	var align: float = 0.0
	if fwd.length_squared() > 1e-6 and travel.length_squared() > 1e-6:
		align = fwd.normalized().dot(travel)
	if lat < 8.0 and align > 0.82 and car.wheels_in_contact() >= 3:
		var hv: float = Vector2(car.linear_velocity.x, car.linear_velocity.z).length()
		if hv < cap * 0.94:
			var dir_f: Vector3 = fwd.normalized()
			car.linear_velocity = Vector3(dir_f.x * cap, car.linear_velocity.y, dir_f.z * cap)
		car.in_throttle = 1.0
		car.in_brake = 0.0
		car.in_drs = cap > 55.0
	else:
		car.in_throttle = 0.35
		car.in_brake = 0.35 if lat > 10.0 else 0.0
		car.in_drs = false
	if fast and car.speed_kmh >= 250.0 and lat < 14.0:
		_fast_m += step
		_tiles[Vector2i(floori(wpos.x / TileGen.TILE), floori(wpos.z / TileGen.TILE))] = true
		if Vector2(wpos.x - _ic.x, wpos.z - _ic.z).length() < 55.0:
			_passed_ic = true
	if not _shot and not fast and _river_m > 120.0 and DisplayServer.get_name() != "headless":
		_shot = true
		get_viewport().get_texture().get_image().save_png("res://docs/shots/s3_river_drive.png")
	if f % 120 == 0:
		print("t=%.1fs %.0f km/h lat %.1f wheels %d clear %.2f travel %.0f" % [f / 60.0, car.speed_kmh, lat, car.wheels_in_contact(), clear, _travel])


func _near_river(wpos: Vector3) -> bool:
	var rq: Vector4 = TerrainFn.river_query(wpos.x, wpos.z)
	return rq.x < rq.z + 70.0 and rq.w > 0.03 and rq.w < 0.98


func _ahead_radius() -> float:
	return _window_radius(_edge, _idx, _dir, 220.0)


func _follow(wpos: Vector3) -> void:
	var pts: PackedVector3Array = RoadGraph.e_pts[_edge]
	for _step: int in 24:
		var t: Vector3 = RoadGraph.tangent(_edge, _idx) * float(_dir)
		if (wpos - pts[_idx]).dot(t) <= 0.0:
			break
		var nxt: int = _idx + _dir
		if nxt < 0 or nxt >= pts.size():
			_pick_next(t)
			pts = RoadGraph.e_pts[_edge]
			break
		_idx = nxt
	var step_m: float = maxf(RoadGraph.e_step[_edge], 1.0)
	var look: int = clampi(int(clampf(car.speed, 18.0, 80.0) * 0.85 / step_m), 6, 36)
	var li: int = clampi(_idx + _dir * look, 0, pts.size() - 1)
	var look_w: Vector3 = pts[li]
	var lane_fwd: Vector3 = RoadGraph.tangent(_edge, _idx) * float(_dir)
	lane_fwd.y = 0.0
	if lane_fwd.length_squared() > 1e-6:
		look_w += lane_fwd.normalized().cross(Vector3.UP) * RoadGraph.lane_offset(_edge, _idx, _dir)
	var rel: Vector3 = car.global_transform.inverse() * Origin.to_local(look_w)
	car.in_steer = clampf(atan2(rel.x, maxf(-rel.z, 0.5)) / deg_to_rad(20.0), -1.0, 1.0)
	car.in_handbrake = false


func _pick_next(cur_fwd: Vector3) -> void:
	var node: int = RoadGraph.e_b[_edge] if _dir > 0 else RoadGraph.e_a[_edge]
	var best_e: int = _edge
	var best_d: int = -_dir
	var best_dot: float = -2.0
	for ce: int in RoadGraph.node_edges[node]:
		if ce == _edge and RoadGraph.node_edges[node].size() > 1:
			continue
		var c_dir: int = 1 if RoadGraph.e_a[ce] == node else -1
		var c_i: int = 1 if c_dir > 0 else RoadGraph.e_pts[ce].size() - 2
		var c_fwd: Vector3 = RoadGraph.tangent(ce, clampi(c_i, 0, RoadGraph.e_pts[ce].size() - 1)) * float(c_dir)
		var d: float = cur_fwd.dot(c_fwd)
		if phase == 4 and RoadGraph.e_type[ce] == RoadGraph.HIGHWAY:
			d += 0.35
		if d > best_dot:
			best_dot = d
			best_e = ce
			best_d = c_dir
	_edge = best_e
	_dir = best_d
	_idx = 1 if _dir > 0 else RoadGraph.e_pts[_edge].size() - 2


func _finish(why: String) -> void:
	set_physics_process(false)
	car.in_throttle = 0.0
	car.in_brake = 0.0
	if why == "":
		print("FALL PASS (max %.0f km/h, min clear %.2f m, fast tiles %d, respawns %d)" % [_max_kmh, _min_clear, _tiles.size(), int(main.get("fall_count"))])
	else:
		print("FALL FAIL: " + why)
	main.call("quit_game")
	await get_tree().create_timer(0.4).timeout
	get_tree().quit(0 if why == "" else 1)
