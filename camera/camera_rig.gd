class_name CameraRig
extends Node3D
## Chase + hood camera (PLAN 6.5). Follows the car's interpolated transform in _process.

const CHASE_BACK: float = 5.6
const CHASE_UP: float = 1.7

var car: Car
var hood: bool = false
var cam: Camera3D
var _yaw: float = 0.0
var _blend: float = 0.0  # 0 chase .. 1 hood
var _t: float = 0.0
var _noise: FastNoiseLite = FastNoiseLite.new()


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_noise.frequency = 1.0
	cam = Camera3D.new()
	cam.far = 4000.0
	add_child(cam)
	cam.make_current()
	snap()


## Jump straight behind the car (spawn, respawn, origin shift).
func snap() -> void:
	if car != null:
		_yaw = _car_yaw(car.global_transform)
		_process(0.0)


func _car_yaw(xf: Transform3D) -> float:
	return atan2(xf.basis.z.x, xf.basis.z.z)


func _process(dt: float) -> void:
	if car == null:
		return
	if Input.is_action_just_pressed("camera_toggle"):
		hood = not hood
	var xf: Transform3D = car.get_global_transform_interpolated() if is_inside_tree() and dt > 0.0 else car.global_transform
	var s: float = smoothstep(60.0, 330.0, car.speed_kmh)
	_yaw = lerp_angle(_yaw, _car_yaw(xf), 1.0 - exp(-6.0 * dt))
	var pos: Vector3 = xf.origin + Basis(Vector3.UP, _yaw) * Vector3(0.0, CHASE_UP, CHASE_BACK + 0.5 * s)
	var chase: Transform3D = Transform3D(Basis.IDENTITY, pos).looking_at(xf.origin + Vector3(0.0, 1.0, 0.0))
	_blend = move_toward(_blend, 1.0 if hood else 0.0, dt * 4.0)
	var b: float = smoothstep(0.0, 1.0, _blend)
	var out: Transform3D = chase.interpolate_with(xf * Transform3D(Basis.IDENTITY, car.hood_cam), b)
	cam.fov = lerpf(lerpf(65.0, 88.0, s), lerpf(70.0, 82.0, s), b)
	cam.near = 0.05 if b > 0.5 else 0.15
	global_transform = out
	# speed shake
	_t += dt
	var sh: float = clampf((car.speed_kmh - 220.0) / 130.0, 0.0, 1.0)
	cam.position = Vector3(_noise.get_noise_1d(_t * 22.0), _noise.get_noise_1d(_t * 22.0 + 50.0), 0.0) * 0.035 * sh
	cam.rotation.z = deg_to_rad(0.25) * sh * _noise.get_noise_1d(_t * 22.0 + 100.0)
