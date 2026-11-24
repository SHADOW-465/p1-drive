extends Node
## Gate (kick): drives each car along the road graph at 100-300 km/h (straights, curves, tile boundaries,
## DRS, hard airbrake stops) and fails on a sudden sideways kick: the body box touching anything, a per-tick
## lateral-velocity or yaw/roll-rate jump, or a lift-off the road does not explain. Prints KICK PASS / KICK FAIL: <reason>.

const DV_LAT: float = 0.6  # m/s change of car-frame sideways speed in one 1/60 s tick (~3.5 g); real cornering is < 0.2
const DW: float = 0.6  # rad/s change of yaw or roll rate in one tick; a wheel-hop on a rough road is ~0.45
const AIR_TICKS: int = 45  # no wheel contact this long = launched
const LAND_GRACE: int = 20  # ticks after a crest launch in which roll/yaw settle without it being a kick
const SECONDS: float = 75.0

var main: Node3D
var car: Car
var ids: PackedStringArray = []
var idx: int = -1
var k: int = 0
var booted: bool = false
var ad: Autodrive
var prev_v: Vector3
var prev_w: Vector3
var air: int = 0
var since_air: int = 999
var max_dv: float = 0.0
var max_dw: float = 0.0
var max_kmh: float = 0.0
var states: Dictionary = {}
var tiles: Dictionary = {}


func _ready() -> void:
	for id: String in ["mclaren_p1_vecarz", "mclaren_600lt"]:
		if CarRegistry.is_available(id):
			ids.append(id)
	if ids.is_empty():
		ids.append("p1")  # fresh clone without assets_nc
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _physics_process(_dt: float) -> void:
	if not booted:
		booted = not car.freeze
		return
	if k == 0:
		idx += 1
		if idx >= ids.size():
			_finish("")
			return
		main.call("_swap_car", ids[idx])
		car = main.get_node("P1") as Car
		car.player_controlled = false
		ad = Autodrive.new()
		ad.sync_to_world(Origin.to_world(car.position), -car.global_basis.z)
		max_dv = 0.0
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
		var dw: float = maxf(absf(w.y - prev_w.y), absf(w.z - prev_w.z)) if since_air > LAND_GRACE else 0.0
		max_dv = maxf(max_dv, dv)
		max_dw = maxf(max_dw, dw)
		if (dv > DV_LAT or dw > DW):
			_finish("%s sideways kick at t=%.1fs %.0f km/h: dv_lat %.2f m/s, dw %.2f rad/s, wheels %d, v_lat %.2f, yaw rate %.2f, roll rate %.2f, world %s" % [ids[idx], t, car.speed_kmh, dv, dw, car.wheels_in_contact(), v.x, w.y, w.z, str(Origin.to_world(car.position).snapped(Vector3.ONE))])
			return
	if t > 1.5 and not car.get_colliding_bodies().is_empty():  # the root cause: the body box drove into the road colliders
		var hit: Node3D = car.get_colliding_bodies()[0] as Node3D
		_finish("%s body box touched %s/%s (%s) at t=%.1fs %.0f km/h, world %s" % [ids[idx], hit.get_parent().name, hit.name, _contact_info(hit), t, car.speed_kmh, str(Origin.to_world(car.position).snapped(Vector3.ONE))])
		return
	air = air + 1 if car.wheels_in_contact() == 0 else 0
	if air > AIR_TICKS or car.global_basis.y.y < 0.5 or int(main.get("fall_count")) > 0:
		_finish("%s left the ground at t=%.1fs %.0f km/h (air ticks %d, up %.2f, falls %d)" % [ids[idx], t, car.speed_kmh, air, car.global_basis.y.y, int(main.get("fall_count"))])
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
		print("%s t=%.0fs %.0f km/h tiles %d wheels %d" % [ids[idx], t, car.speed_kmh, tiles.size(), car.wheels_in_contact()])
	if t >= SECONDS:
		print("%s: max %.0f km/h, tiles %d, aero %s, max dv_lat %.2f, max dw %.2f" % [ids[idx], max_kmh, tiles.size(), ",".join(states.keys()), max_dv, max_dw])
		if max_kmh < 250.0 or tiles.size() < 3:
			_finish("%s run too short: max %.0f km/h, %d tiles" % [ids[idx], max_kmh, tiles.size()])
			return
		k = 0


## Target-speed schedule capped by the curve ahead; DRS on the fast legs, hard stops with the airbrake.
func _drive_profile(t: float) -> void:
	var cyc: float = fposmod(t, 45.0)
	var target: float = 100.0 if cyc < 8.0 else (200.0 if cyc < 18.0 else (300.0 if cyc < 33.0 else 60.0))
	var curve_cap: float = sqrt(8.0 * _radius_ahead()) * 3.6
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
	print("KICK PASS (%s)" % ",".join(ids) if fail == "" else "KICK FAIL: " + fail)
	main.call("quit_game")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fail == "" else 1)

