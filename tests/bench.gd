extends Node3D
## Temporary bench (T03): prints the PLAN 6.2 numbers. Folded into the smoke test in T06.

var car: Car
var f: int = 0
var phase: int = 0
var t0: int = 0
var t100: float = -1.0
var t200: float = -1.0
var vmax: float = 0.0
var ymin: float = 9.0
var ymax: float = -9.0
var f300: int = -1
var p100: Vector3 = Vector3.INF


func _ready() -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	body.add_child(cs)
	add_child(body)
	car = (load("res://cars/p1/p1.tscn") as PackedScene).instantiate() as Car
	car.player_controlled = false
	car.position.y = 0.1
	add_child(car)


func _physics_process(_dt: float) -> void:
	f += 1
	var kmh: float = car.speed * 3.6
	match phase:
		0:
			if f == 120:
				print("rest y=%.3f v=%.3f contact=%d" % [car.position.y, car.linear_velocity.length(), car.wheels_in_contact()])
				car.in_throttle = 1.0
				t0 = f
				phase = 1
		1:
			var t: float = (f - t0) / 60.0
			if t100 < 0.0 and kmh >= 100.0:
				t100 = t
			if t200 < 0.0 and kmh >= 200.0:
				t200 = t
			vmax = maxf(vmax, kmh)
			if t > 30.0:
				ymin = minf(ymin, car.position.y)
				ymax = maxf(ymax, car.position.y)
			if t > 45.0:
				print("0-100 %.2fs 0-200 %.2fs top %.1f km/h z=%.0f y[%.3f..%.3f]" % [t100, t200, vmax, car.position.z, ymin, ymax])
				car.in_throttle = 0.0
				car.in_brake = 1.0
				phase = 2
		2:
			if f300 < 0 and kmh <= 300.0:
				f300 = f
			if p100 == Vector3.INF and kmh <= 100.0:
				p100 = car.position
			if kmh < 1.0:
				print("300-0 %.2fs 100-0 %.1fm" % [(f - f300) / 60.0, car.position.distance_to(p100)])
				car.in_brake = 0.0
				car.in_throttle = 1.0
				t0 = f
				phase = 3
		3:
			if kmh > 100.0:
				car.in_steer = -1.0
				if t0 > 0:
					t0 = -f
			if t0 < 0 and f + t0 > 240:
				print("left steer: yaw rate %.2f (expect > 0) up %.2f kmh %.0f" % [car.angular_velocity.y, car.global_basis.y.y, kmh])
				get_tree().quit()
