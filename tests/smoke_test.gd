extends Node3D
## Gate 2 (PLAN 8.2): drives the car through the aero states on an infinite plane.
## Prints SMOKE PASS / SMOKE FAIL: <reason>; then prints (not asserts) the 6.2 bench numbers.

@export var car_scene: PackedScene = preload("res://cars/p1/p1.tscn")
@export var check_aero: bool = true

var car: Car
var aero: ActiveAero
var phase: int = 0
var f: int = 0  # frames in the current phase
var t_run: int = 0
var t100: float = -1.0
var t200: float = -1.0
var drag_high: float = 0.0
var prev_kmh: float = 0.0
var vmax: float = 0.0
var vmax_drs: float = 0.0
var f300: int = -1
var p100: Vector3 = Vector3.INF


func _ready() -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	body.add_child(cs)
	add_child(body)
	car = car_scene.instantiate() as Car
	car.player_controlled = false
	car.position.y = 0.1
	add_child(car)
	aero = car.get_node_or_null("Aero") as ActiveAero
	if aero == null:
		check_aero = false


func _next() -> void:
	phase += 1
	f = 0


func _fail(why: String) -> void:
	print("SMOKE FAIL: phase %d: %s" % [phase, why])
	set_physics_process(false)
	get_tree().quit(1)


func _physics_process(_dt: float) -> void:
	f += 1
	var kmh: float = car.speed * 3.6
	if is_nan(car.position.x + car.linear_velocity.x) or car.global_basis.y.y < 0.9:
		_fail("NaN or not upright")
		return
	match phase:
		0:  # settle
			if f == 60:
				if car.wheels_in_contact() < 4 or car.linear_velocity.length() > 0.5:
					_fail("not settled")
				elif check_aero and absf(aero.wing_angle_deg - 2.0) > 1.0:
					_fail("wing not at rest")
				else:
					car.in_throttle = 1.0
					_next()
		1:  # to 200 km/h
			if t100 < 0.0 and kmh >= 100.0:
				t100 = f / 60.0
			if kmh >= 200.0:
				t200 = f / 60.0
				if check_aero and (aero.state != ActiveAero.State.HIGH or absf(aero.wing_angle_deg - 14.0) > 2.0 or aero.wing_height < 0.15):
					_fail("HIGH pose wrong: %s %.1f deg %.2f m" % [aero.state_name(), aero.wing_angle_deg, aero.wing_height])
				else:
					drag_high = car.k_drag
					car.in_drs = true
					_next()
			elif f > 900:
				_fail("200 km/h not reached")
		2:  # DRS
			if f == 90:
				if check_aero and (aero.state != ActiveAero.State.DRS or aero.wing_angle_deg > 3.0 or car.k_drag >= drag_high):
					_fail("DRS pose wrong")
				else:
					car.in_drs = false
					car.in_throttle = 0.0
					car.in_brake = 1.0
					prev_kmh = kmh
					_next()
		3:  # airbrake
			if f == 45:
				if check_aero and (aero.state != ActiveAero.State.AIRBRAKE or aero.wing_angle_deg < 45.0):
					_fail("no airbrake: %s %.1f deg" % [aero.state_name(), aero.wing_angle_deg])
				elif kmh >= prev_kmh:
					_fail("not slowing")
				else:
					_next()
		4:  # stop
			if kmh < 5.0:
				car.in_brake = 0.0
				_next()
			elif f > 600:
				_fail("did not stop")
		5:  # wing settles
			if f == 180:
				if check_aero and aero.wing_angle_deg > 5.0:
					_fail("wing did not settle")
				else:
					print("SMOKE PASS")
					car.in_throttle = 1.0
					_next()
		6:  # bench: top speed
			vmax = maxf(vmax, kmh)
			if f == 2400:
				car.in_drs = true
				_next()
		7:
			vmax_drs = maxf(vmax_drs, kmh)
			if f == 900:
				car.in_drs = false
				car.in_throttle = 0.0
				car.in_brake = 1.0
				_next()
		8:
			if f300 < 0 and kmh <= 300.0:
				f300 = f
			if p100 == Vector3.INF and kmh <= 100.0:
				p100 = car.position
			if kmh < 1.0:
				print("BENCH 0-100 %.2fs 0-200 %.2fs top %.0f drs %.0f km/h 300-0 %.2fs 100-0 %.1fm" % [
					t100, t200, vmax, vmax_drs, (f - f300) / 60.0, car.position.distance_to(p100)])
				get_tree().quit(0)
