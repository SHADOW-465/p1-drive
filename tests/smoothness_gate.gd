extends Node
## Gate (smoothness, M1): drives P1, 600LT, Gemera and Bentley by autopilot over the road network at
## 100-300 km/h and fails on airtime > 0.15 s, a vertical or lateral velocity jolt in one tick, a yaw/roll-rate
## jump, or the body box touching anything. Prints SMOOTHNESS PASS / SMOOTHNESS FAIL: <reason>.

const DV_Y: float = 1.0  # m/s change of car-frame vertical speed in one tick (plan target 0.45; tighten as M4 lands)
const DV_LAT: float = 0.6  # m/s change of car-frame sideways speed in one 1/60 s tick (~3.5 g); real cornering is < 0.2
const DW: float = 0.6  # rad/s change of yaw or roll rate in one tick; a wheel-hop on a rough road is ~0.45
const AIR_TICKS: int = 9  # 0.15 s without wheel contact = airtime
const LAND_GRACE: int = 20  # ticks after a crest launch in which roll/yaw settle without it being a kick
## Routes on Horizon Triland (M4): start point, travel direction along the edge there (+1 = edge order), seconds, and
## the speed / tiles each run must reach. Each start is the regional motorway with the longest run of curve radius
## >= 250 m and no dead end or hairpin node ahead (tools: 5.8-9.2 km), so every car can reach full speed.
const ROUTES: Array[Dictionary] = [
	{"name": "tokyo", "pos": Vector3(8233.6, 43.3, 461.8), "dir": -1, "seconds": 45.0, "min_kmh": 250.0, "min_tiles": 3},
	{"name": "monaco", "pos": Vector3(-7394.9, 274.6, -1119.6), "dir": 1, "seconds": 40.0, "min_kmh": 240.0, "min_tiles": 2},
	{"name": "dubai", "pos": Vector3(-3656.9, 9.7, 5441.1), "dir": -1, "seconds": 40.0, "min_kmh": 250.0, "min_tiles": 2},
]

var main: Node3D
var car: Car
var ids: PackedStringArray = []
var runs: Array[Vector2i] = []  # (route, car) in drive order: every car on a route while its tiles are warm
var idx: int = -1
var route: Dictionary = {}
var start_w: Vector3
var k: int = 0
var booted: bool = false
var ad: Autodrive
var prev_v: Vector3
var prev_w: Vector3
var air: int = 0
var since_air: int = 999
var max_dv: float = 0.0
var max_dy: float = 0.0
var max_air: int = 0
var max_dw: float = 0.0
var max_kmh: float = 0.0
var states: Dictionary = {}
var tiles: Dictionary = {}
var parked: bool = true  # false while the car waits frozen at the route start for its tiles
var park_ms: int = 0


func _ready() -> void:
	for id: String in ["mclaren_p1_vecarz", "mclaren_600lt", "koenigsegg_gemera", "bentley_exp10_speed6"]:
		if CarRegistry.is_available(id):
			ids.append(id)
	if ids.is_empty():
		ids.append("p1")  # fresh clone without assets_nc
	for r: int in ROUTES.size():
		for c: int in ids.size():
			runs.append(Vector2i(r, c))
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _physics_process(_dt: float) -> void:
	if not booted:
		booted = not car.freeze
		return
	if not parked:
		var key := Vector2i(floori(start_w.x / TileGen.TILE), floori(start_w.z / TileGen.TILE))
		var world := main.get_node(^"World") as TileStreamer
		if not (world.centre == key and world.is_ready()):
			if Time.get_ticks_msec() - park_ms > 60000:
				_finish("route start tiles did not ready")
			return
		parked = true
		car.freeze = false
	if k == 0:
		idx += 1
		if idx >= runs.size():
			_finish("")
			return
		route = ROUTES[runs[idx].x]
		main.call("_swap_car", ids[runs[idx].y])
		car = main.get_node("P1") as Car
		car.player_controlled = false
		_to_route_start()
		ad = Autodrive.new()
		ad.sync_to_world(Origin.to_world(car.position), -car.global_basis.z)
		max_dv = 0.0
		max_dy = 0.0
		max_air = 0
		max_dw = 0.0
		max_kmh = 0.0
		air = 0
		since_air = 999
		states.clear()
		tiles.clear()
		prev_v = Vector3.ZERO
		prev_w = Vector3.ZERO
		car.contact_monitor = true
		car.max_contacts_reported = 4
	k += 1
	if k < 90:  # let the swap respawn settle
		return
	var t: float = (k - 90) / 60.0
	ad.drive(car)
	_drive_profile(t)
	var v: Vector3 = car.global_basis.inverse() * car.linear_velocity
	var w: Vector3 = car.global_basis.inverse() * car.angular_velocity
	since_air = 0 if car.wheels_in_contact() < 2 else since_air + 1
	if k > 100 and t > 1.5:
		var dv: float = absf(v.x - prev_v.x)
		var dy: float = absf(v.y - prev_v.y) if since_air > LAND_GRACE else 0.0
		max_dy = maxf(max_dy, dy)
		if dy > DV_Y:
			_finish("%s vertical jolt at t=%.1fs %.0f km/h: dv_y %.2f m/s, world %s" % [_id(), t, car.speed_kmh, dy, str(Origin.to_world(car.position).snapped(Vector3.ONE))])
			return
		var dw: float = maxf(absf(w.y - prev_w.y), absf(w.z - prev_w.z)) if since_air > LAND_GRACE else 0.0
		max_dv = maxf(max_dv, dv)
		max_dw = maxf(max_dw, dw)
		if (dv > DV_LAT or dw > DW):
			_finish("%s sideways kick at t=%.1fs %.0f km/h: dv_lat %.2f m/s, dw %.2f rad/s, wheels %d, v_lat %.2f, yaw rate %.2f, roll rate %.2f, world %s" % [_id(), t, car.speed_kmh, dv, dw, car.wheels_in_contact(), v.x, w.y, w.z, str(Origin.to_world(car.position).snapped(Vector3.ONE))])
			return
	if t > 1.5 and not car.get_colliding_bodies().is_empty():  # the root cause: the body box drove into the road colliders
		var hit: Node3D = car.get_colliding_bodies()[0] as Node3D
		_finish("%s body box touched %s/%s (%s) at t=%.1fs %.0f km/h, world %s" % [_id(), hit.get_parent().name, hit.name, _contact_info(hit), t, car.speed_kmh, str(Origin.to_world(car.position).snapped(Vector3.ONE))])
		return
	air = air + 1 if car.wheels_in_contact() == 0 else 0
	max_air = maxi(max_air, air)
	if air > AIR_TICKS or car.global_basis.y.y < 0.5 or int(main.get("fall_count")) > 0:
		_finish("%s airtime > 0.15 s at t=%.1fs %.0f km/h (air ticks %d, up %.2f, falls %d), world %s" % [_id(), t, car.speed_kmh, air, car.global_basis.y.y, int(main.get("fall_count")), str(Origin.to_world(car.position).snapped(Vector3.ONE))])
		return
	prev_v = v
	prev_w = w
	max_kmh = maxf(max_kmh, car.speed_kmh)
	var wp: Vector3 = Origin.to_world(car.position)
	tiles[Vector2i(floori(wp.x / TileGen.TILE), floori(wp.z / TileGen.TILE))] = true
	var aero := car.find_child("Aero", true, false) as ActiveAero
	if aero != null:
		states[aero.state_name()] = true
	if k % 600 == 0:
		print("%s t=%.0fs %.0f km/h tiles %d wheels %d" % [_id(), t, car.speed_kmh, tiles.size(), car.wheels_in_contact()])
	if t >= float(route["seconds"]):
		print("%s: max %.0f km/h, tiles %d, aero %s, max dv_lat %.2f, max dv_y %.2f, max dw %.2f, max air ticks %d" % [_id(), max_kmh, tiles.size(), ",".join(states.keys()), max_dv, max_dy, max_dw, max_air])
		if max_kmh < float(route["min_kmh"]) or tiles.size() < int(route["min_tiles"]):
			_finish("%s run too short: max %.0f km/h, %d tiles" % [_id(), max_kmh, tiles.size()])
			return
		k = 0


## Every car starts each route from the same place and heading, not where the last car stopped.
func _to_route_start() -> void:
	var np: Dictionary = RoadGraph.nearest_point(route["pos"], 800.0)
	var e: int = np["edge"]
	var rng: Vector2i = RoadMesher.edge_range(e)
	var i: int = clampi(int(np["i"]), mini(rng.x + 2, rng.y), maxi(rng.y - 2, rng.x))
	var fwd: Vector3 = RoadGraph.tangent(e, i) * float(route["dir"])
	fwd.y = 0.0
	fwd = fwd.normalized()
	start_w = RoadGraph.e_pts[e][i] + main.call("_lane_shift", e, fwd, i)
	car.freeze = true
	car.teleport(Transform3D(Basis.looking_at(fwd, Vector3.UP), Origin.to_local(start_w) + Vector3(0.0, 0.45, 0.0)))
	(main.get("rig") as CameraRig).snap()
	parked = false
	park_ms = Time.get_ticks_msec()


func _id() -> String:
	return "%s@%s" % [ids[runs[idx].y], route["name"]] if not route.is_empty() else "?"


## Target-speed schedule capped by the curve ahead; DRS on the fast legs, hard stops with the airbrake.
func _drive_profile(t: float) -> void:
	var cyc: float = fposmod(t, 45.0)
	var target: float = 100.0 if cyc < 8.0 else (200.0 if cyc < 18.0 else (300.0 if cyc < 33.0 else 60.0))
	var curve_cap: float = sqrt(8.0 * _radius_ahead()) * 3.6
	curve_cap = minf(curve_cap, sqrt(9.81 * _crest_radius_ahead()) * 3.6)  # a car is weightless over a crest above v = sqrt(g R)
	curve_cap = minf(curve_cap, ad.junction_cap() * 3.6)  # brake into the turn at the node ahead
	target = minf(target, curve_cap)
	var err: float = target - car.speed_kmh
	car.in_throttle = clampf(err / 15.0, 0.0, 1.0)
	car.in_brake = clampf(-err / 15.0, 0.0, 1.0) if err < -4.0 else 0.0
	car.in_drs = target >= 190.0 and car.in_brake == 0.0


func _radius_ahead() -> float:
	var pts: PackedVector3Array = ad.route_points(64)  # crosses the node ahead: a loop ramp after a junction counts
	var min_r: float = 5000.0
	if pts.size() < 9:
		return min_r
	var prev: Vector3 = pts[1] - pts[0]
	prev.y = 0.0
	prev = prev.normalized()
	for s: int in range(4, pts.size() - 1, 4):
		var tn: Vector3 = pts[s + 1] - pts[s - 1]
		tn.y = 0.0
		if tn.length_squared() < 1e-6:
			continue
		tn = tn.normalized()
		var ang: float = acos(clampf(prev.dot(tn), -1.0, 1.0))
		if ang > 0.01:
			min_r = minf(min_r, Vector2(pts[s].x - pts[s - 4].x, pts[s].z - pts[s - 4].z).length() / ang)
		prev = tn
	return min_r


## Smallest vertical crest radius over the next ~240 m (1e5 when there is none).
func _crest_radius_ahead() -> float:
	var pts: PackedVector3Array = ad.route_points(62)
	var min_r: float = 100000.0
	var prev: float = 0.0
	for s: int in range(0, pts.size() - 2, 2):
		var run: float = maxf(Vector2(pts[s + 2].x - pts[s].x, pts[s + 2].z - pts[s].z).length(), 0.01)
		var slope: float = (pts[s + 2].y - pts[s].y) / run
		if s > 0 and slope < prev:  # slope falling = crest
			min_r = minf(min_r, run / maxf(prev - slope, 1e-4))
		prev = slope
	return min_r


## Which collider of the hit body, and where on the car (car-local), so a failure names its cause.
func _contact_info(hit: Node3D) -> String:
	var st: PhysicsDirectBodyState3D = PhysicsServer3D.body_get_direct_state(car.get_rid())
	if st == null or not hit is CollisionObject3D:
		return "?"
	var co := hit as CollisionObject3D
	for c: int in st.get_contact_count():
		if st.get_contact_collider_id(c) == hit.get_instance_id():
			var owner_node: Object = co.shape_owner_get_owner(co.shape_find_owner(st.get_contact_collider_shape(c)))
			var at: Vector3 = car.global_transform.affine_inverse() * st.get_contact_collider_position(c)
			return "%s at car %s" % [(owner_node as Node).name if owner_node is Node else "?", str(at.snapped(Vector3.ONE * 0.01))]
	return "?"


func _finish(fail: String) -> void:
	set_physics_process(false)
	print("SMOOTHNESS PASS (%s)" % ",".join(ids) if fail == "" else "SMOOTHNESS FAIL: " + fail)
	main.call("quit_game")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fail == "" else 1)

