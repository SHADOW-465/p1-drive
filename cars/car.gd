class_name Car
extends VehicleBody3D
## Vehicle controller (PLAN 2.8, 6). Faces -Z. Inputs are read from Input when
## player_controlled, otherwise set by tests/autodrive.

@export var player_controlled: bool = true
@export_group("Drivetrain")
@export var max_force: float = 13900.0  ## N, total over traction wheels
@export var max_power: float = 560000.0  ## W
@export var gear_tops: PackedFloat32Array = PackedFloat32Array([78, 124, 170, 220, 270, 315, 360])
@export var limiter_kmh: float = 350.0
@export var engine_brake_g: float = 0.08
@export_group("Brakes")
@export var brake_front: float = 5550.0  ## N per wheel at full pedal
@export var brake_rear: float = 3700.0
@export var handbrake_force: float = 6000.0
@export_group("Steering")
@export var steer_deg: Vector3 = Vector3(32.0, 14.0, 6.0)  ## max angle at 0 / 100 / 300 km/h
@export var hood_cam: Vector3 = Vector3(0.0, 0.95, -0.55)
@export_group("Aero")
@export var down_max: float = 14000.0

var in_throttle: float = 0.0
var in_brake: float = 0.0
var in_steer: float = 0.0  # -1 left .. +1 right
var in_handbrake: bool = false
var in_drs: bool = false

var drivetrain: Drivetrain = Drivetrain.new()
var speed: float = 0.0  # forward m/s (negative in reverse)
var speed_kmh: float = 0.0
var reversing: bool = false
var k_drag: float = 0.6  # set by active aero
var k_down: float = 0.6
var brake_now: float = 0.0  # effective brake pedal (after the reverse swap)

var _steer: float = 0.0
var _tc: float = 1.0
var _wheels: Array[VehicleWheel3D] = []
var _n_traction: int = 0


func _ready() -> void:
	drivetrain.gear_tops = gear_tops
	Origin.shifted.connect(_on_origin_shift)
	for c: Node in get_children():
		if c is VehicleWheel3D:
			_wheels.append(c as VehicleWheel3D)
			if (c as VehicleWheel3D).use_as_traction:
				_n_traction += 1


func _physics_process(dt: float) -> void:
	if player_controlled:
		in_throttle = Input.get_action_strength("throttle")
		in_brake = Input.get_action_strength("brake")
		in_steer = Input.get_axis("steer_left", "steer_right")
		in_handbrake = Input.is_action_pressed("handbrake")
		in_drs = Input.is_action_pressed("drs")
	speed = linear_velocity.dot(-global_basis.z)
	speed_kmh = absf(speed) * 3.6

	# brake pedal becomes reverse when stopped
	if reversing:
		if in_brake < 0.05 or speed > 1.0:
			reversing = false
	elif in_brake > 0.1 and in_throttle < 0.1 and speed < 0.5:
		reversing = true
	var throttle: float = in_brake if reversing else in_throttle
	var brake: float = in_throttle if reversing else in_brake
	brake_now = brake
	drivetrain.update(dt, speed_kmh, throttle, reversing)

	var rate: float = 9.0 if absf(in_steer) < absf(_steer) else 6.0
	_steer = move_toward(_steer, in_steer, rate * dt)
	steering = -_steer * deg_to_rad(_max_steer_deg(speed_kmh))

	var force: float
	if reversing:
		force = -0.4 * throttle * max_force * clampf((40.0 - speed_kmh) / 5.0, 0.0, 1.0)
	else:
		force = throttle * minf(max_force, max_power / maxf(absf(speed), 1.0)) * drivetrain.force_scale()
		force *= clampf((limiter_kmh - speed_kmh) / 5.0, 0.0, 1.0)
	var slipping: bool = false
	for w: VehicleWheel3D in _wheels:
		if w.use_as_traction and w.is_in_contact() and w.get_skidinfo() < 0.6:
			slipping = true
	_tc = move_toward(_tc, 0.6 if slipping else 1.0, 4.0 * dt)
	force *= _tc
	if throttle < 0.02 and brake < 0.02 and speed > 2.0:
		force = -engine_brake_g * 9.81 * mass
	var tick: float = Engine.physics_ticks_per_second
	for w: VehicleWheel3D in _wheels:
		var b: float = brake * (brake_front if w.use_as_steering else brake_rear)
		if in_handbrake and not w.use_as_steering:
			b = maxf(b, handbrake_force)
		w.brake = b / tick
		w.engine_force = -force / _n_traction if w.use_as_traction and b <= 0.0 else 0.0

	var v2: float = linear_velocity.length_squared()
	if v2 > 1.0:
		apply_central_force(-linear_velocity.normalized() * k_drag * v2)
		var down: Vector3 = -global_basis.y * minf(k_down * v2, down_max)
		apply_force(down * 0.4, global_basis * Vector3(0.0, 0.3, -1.3))
		apply_force(down * 0.6, global_basis * Vector3(0.0, 0.3, 1.3))


func _max_steer_deg(kmh: float) -> float:
	if kmh < 100.0:
		return lerpf(steer_deg.x, steer_deg.y, kmh / 100.0)
	return lerpf(steer_deg.y, steer_deg.z, clampf((kmh - 100.0) / 200.0, 0.0, 1.0))


## Put the car at rest at xf (local coords). Call from a physics frame.
func teleport(xf: Transform3D) -> void:
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	drivetrain.gear = 1
	reversing = false
	_steer = 0.0


## Floating origin (PLAN 2.1): move with the world, velocities untouched.
func _on_origin_shift(d: Vector3) -> void:
	global_position -= d
	reset_physics_interpolation()
	($Lights as CarLights).shift(d)


func wheels_in_contact() -> int:
	var n: int = 0
	for w: VehicleWheel3D in _wheels:
		if w.is_in_contact():
			n += 1
	return n
