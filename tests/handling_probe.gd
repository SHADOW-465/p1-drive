extends Node3D
## Dev probe (not a gate): full-lock stability at 100 km/h, then pure-pursuit laps of the oval
## at rising target speeds. Prints slip angles and the lateral error.

var car: Car
var pts: PackedVector3Array
var f: int = 0
var phase: int = 0
var target_kmh: float = 150.0
var idx: int = 0
var max_err: float = 0.0
var max_slip: float = 0.0
var laps_f: int = 0


func _ready() -> void:
	var track: Node3D = (load("res://tests/test_track.tscn") as PackedScene).instantiate() as Node3D
	add_child(track)
	pts = track.call("_centreline")
	car = (load("res://cars/p1/p1.tscn") as PackedScene).instantiate() as Car
	car.player_controlled = false
	car.position.y = 0.1
	add_child(car)


func _slip_deg() -> float:
	var v: Vector3 = car.linear_velocity
	if v.length() < 5.0:
		return 0.0
	return rad_to_deg(absf((-car.global_basis.z).signed_angle_to(v, Vector3.UP)))


func _physics_process(_dt: float) -> void:
	f += 1
	match phase:
		0:
			car.in_throttle = 1.0
			if car.speed_kmh >= 100.0:
				car.in_steer = 1.0
				phase = 1
				f = 0
		1:
			max_slip = maxf(max_slip, _slip_deg())
			if f == 300:
				print("full lock @100: max slip %.1f deg, now %.0f km/h, yaw rate %.2f, up %.2f" % [max_slip, car.speed_kmh, car.angular_velocity.y, car.global_basis.y.y])
				car.teleport(Transform3D(Basis.IDENTITY, Vector3(0, 0.1, 0)))
				phase = 2
				f = 0
				max_slip = 0.0
		2:
			# pure pursuit on the centreline
			var n: int = pts.size()
			while pts[idx % n].distance_to(car.position) < 12.0 + car.speed * 0.35:
				idx += 1
			var to: Vector3 = car.global_transform.affine_inverse() * pts[idx % n]
			car.in_steer = clampf(atan2(to.x, -to.z) * 3.0 / deg_to_rad(car._max_steer_deg(car.speed_kmh)) * 0.35, -1.0, 1.0)
			car.in_throttle = 1.0 if car.speed_kmh < target_kmh else 0.0
			car.in_brake = 1.0 if car.speed_kmh > target_kmh + 15.0 else 0.0
			var best: float = 1e9
			for k: int in range(idx - 40, idx + 1):
				best = minf(best, pts[posmod(k, n)].distance_to(car.position))
			if f > 600:
				max_err = maxf(max_err, best)
				max_slip = maxf(max_slip, _slip_deg())
			if idx >= n * (laps_f + 1) + 30:
				print("lap @%d km/h: max centreline err %.1f m, max slip %.1f deg, up %.2f" % [target_kmh, max_err, max_slip, car.global_basis.y.y])
				laps_f += 1
				target_kmh += 50.0
				max_err = 0.0
				max_slip = 0.0
				if target_kmh > 250.0:  # acceptance is one clean lap at 250
					get_tree().quit()
