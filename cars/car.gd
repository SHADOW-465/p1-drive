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
@export var cockpit_cam: Vector3 = Vector3(-0.34, 0.86, 0.02)
@export_group("Drift")
@export var rear_grip_normal: float = 1.6
@export var rear_grip_drift: float = 1.08
@export var rear_grip_handbrake: float = 0.72
@export_group("Aero")
@export var down_max: float = 14000.0

var in_throttle: float = 0.0
var in_brake: float = 0.0
var in_steer: float = 0.0  # -1 left .. +1 right
var in_handbrake: bool = false
var in_drs: bool = false
var drift_mode: bool = false

var drivetrain: Drivetrain = Drivetrain.new()
var speed: float = 0.0  # forward m/s (negative in reverse)
var speed_kmh: float = 0.0
var reversing: bool = false
var k_drag: float = 0.6  # set by active aero
var k_down: float = 0.6
var brake_now: float = 0.0  # effective brake pedal (after the reverse swap)
var slip_angle_deg: float = 0.0
var skid_intensity: float = 0.0
var steer_ratio: float = 0.0

var _steer: float = 0.0
var _shadow: MeshInstance3D
var _tc: float = 1.0
var _rear_grip: float = 1.6
var _wheels: Array[VehicleWheel3D] = []
var _n_traction: int = 0

## The body box floor sat 8 cm above the wheel bottoms, so any grade break, tile-seam step or kerb in the road
## colliders drove the box into the road and Jolt resolved it as a hard kick. Lift it clear of the wheel travel.
const BODY_LIFT: float = 0.2


func set_cockpit_active(on: bool) -> void:
	var cp: Node = get_node_or_null("Cockpit")
	if cp != null and cp.has_method("set_cockpit_active"):
		cp.call("set_cockpit_active", on)


func _ready() -> void:
	drivetrain.gear_tops = gear_tops
	_rear_grip = rear_grip_normal
	Origin.shifted.connect(_on_origin_shift)
	_lift_body_box()
	_add_contact_shadow()
	for c: Node in get_children():
		if c is VehicleWheel3D:
			_wheels.append(c as VehicleWheel3D)
			if (c as VehicleWheel3D).use_as_traction:
				_n_traction += 1


## Soft dark blob on the road under the car: the sun shadow vanishes in overcast/rain, which made the car look afloat.
## A Decal would be nicer but does not render in this project's mobile renderer setup, so it is a flat unshaded quad.
func _add_contact_shadow() -> void:
	var g := Gradient.new()
	g.colors = PackedColorArray([Color(0, 0, 0, 0.8), Color(0, 0, 0, 0)])
	g.offsets = PackedFloat32Array([0.55, 1.0])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = tex
	m.disable_receive_shadows = true
	var pm := PlaneMesh.new()
	pm.size = Vector2(2.7, 5.6)
	pm.material = m
	_shadow = MeshInstance3D.new()
	_shadow.name = "ContactShadow"
	_shadow.mesh = pm
	_shadow.layers = 2  # not part of the reflection-probe capture
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_shadow)


## Raise the collision box and pin the inertia to what the unlifted box gave, so roll/pitch/yaw feel is unchanged.
func _lift_body_box() -> void:
	var cs := get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	var box: BoxShape3D = cs.shape as BoxShape3D if cs != null else null
	if box == null:
		return
	var s: Vector3 = box.size
	var d: Vector3 = cs.position - center_of_mass
	inertia = Vector3(
		mass / 12.0 * (s.y * s.y + s.z * s.z) + mass * (d.y * d.y + d.z * d.z),
		mass / 12.0 * (s.x * s.x + s.z * s.z) + mass * (d.x * d.x + d.z * d.z),
		mass / 12.0 * (s.x * s.x + s.y * s.y) + mass * (d.x * d.x + d.y * d.y))
	cs.position.y += BODY_LIFT


func _physics_process(dt: float) -> void:
	if _shadow != null and not _wheels.is_empty():  # flat on the road under the tyres, follows the body's pitch/roll
		var y: float = 0.0
		for w: VehicleWheel3D in _wheels:
			y += w.position.y - w.wheel_radius + GlbBody.CONTACT_SLOP
		_shadow.position.y = y / _wheels.size() + 0.02
	if player_controlled:
		in_throttle = Input.get_action_strength("throttle")
		in_brake = Input.get_action_strength("brake")
		in_steer = clampf(Input.get_axis("steer_left", "steer_right") * Settings.steer_sensitivity, -1.0, 1.0)
		in_handbrake = Input.is_action_pressed("handbrake")
		in_drs = Input.is_action_pressed("drs")
		if Input.is_action_just_pressed("drift_toggle"):
			drift_mode = not drift_mode
	var v_loc: Vector3 = global_basis.inverse() * linear_velocity
	speed = -v_loc.z
	speed_kmh = absf(speed) * 3.6
	slip_angle_deg = rad_to_deg(atan2(absf(v_loc.x), maxf(absf(speed), 1.0))) if linear_velocity.length() > 3.5 and wheels_in_contact() >= 2 else 0.0

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

	var drifting: bool = drift_mode or in_handbrake
	var steer_cmd: float = in_steer
	if drifting and speed > 5.0 and slip_angle_deg > 6.0 and Settings.countersteer_assist > 0.01:
		var cs_amt: float = clampf((slip_angle_deg - 6.0) / 36.0, 0.0, 1.0) * Settings.countersteer_assist * 0.55
		steer_cmd = clampf(in_steer + signf(v_loc.x) * cs_amt * (1.0 - 0.5 * absf(in_steer)), -1.0, 1.0)
	var rate: float = 9.0 if absf(steer_cmd) < absf(_steer) else 6.0
	_steer = move_toward(_steer, steer_cmd, rate * dt)
	steer_ratio = _steer
	steering = -_steer * deg_to_rad(_max_steer_deg(speed_kmh))

	# Rear grip: keep normal grip driving unchanged when drift_mode and handbrake are off.
	var target_grip: float = rear_grip_normal
	if in_handbrake:
		target_grip = rear_grip_handbrake
	elif drift_mode:
		var slip_t: float = clampf((slip_angle_deg - 6.0) / 34.0, 0.0, 1.0)
		target_grip = lerpf(rear_grip_drift, 0.88, slip_t)
	_rear_grip = move_toward(_rear_grip, target_grip, 6.0 * dt)
	for w: VehicleWheel3D in _wheels:
		if not w.use_as_steering:
			w.wheel_friction_slip = _rear_grip

	var force: float
	if reversing:
		force = -0.4 * throttle * max_force * clampf((40.0 - speed_kmh) / 5.0, 0.0, 1.0)
	else:
		force = throttle * minf(max_force, max_power / maxf(absf(speed), 1.0)) * drivetrain.force_scale()
		force *= clampf((limiter_kmh - speed_kmh) / 5.0, 0.0, 1.0)
	var slipping: bool = false
	var min_skid: float = 1.0
	for w: VehicleWheel3D in _wheels:
		if w.use_as_traction and w.is_in_contact():
			var sk: float = w.get_skidinfo()
			min_skid = minf(min_skid, sk)
			if sk < 0.6:
				slipping = true
	_tc = 1.0 if drifting else move_toward(_tc, 0.6 if slipping else 1.0, 4.0 * dt)
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

	if drifting and wheels_in_contact() >= 2 and speed > 6.0:
		if drift_mode and not in_handbrake and throttle > 0.35 and absf(in_steer) > 0.2:
			var kick: float = 1.0 - clampf(slip_angle_deg / 38.0, 0.0, 1.0)
			apply_torque(global_basis.y * (-in_steer * throttle * 650.0 * kick))
		if slip_angle_deg > 6.0 and Settings.countersteer_assist > 0.01:
			apply_torque(global_basis.y * (-angular_velocity.y * 420.0 * Settings.countersteer_assist * clampf(slip_angle_deg / 25.0, 0.0, 1.0)))

	var angle_slip: float = clampf((slip_angle_deg - 7.0) / 28.0, 0.0, 1.0)
	var wheel_slip: float = clampf((0.85 - min_skid) / 0.65, 0.0, 1.0)
	var hb_slip: float = 0.85 if in_handbrake and speed_kmh > 12.0 else 0.0
	var spd_gate: float = clampf((speed_kmh - 8.0) / 20.0, 0.0, 1.0)
	skid_intensity = clampf(maxf(angle_slip, maxf(wheel_slip, hb_slip)) * spd_gate, 0.0, 1.0)

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


## Put the car at rest at xf (floating-origin local coords). Call from a physics frame.
## A frozen body does not copy the physics transform back onto the node, so set both.
func teleport(xf: Transform3D) -> void:
	global_transform = xf
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	reset_physics_interpolation()
	drivetrain.gear = 1
	reversing = false
	_steer = 0.0


## Floating origin (PLAN 2.1): move with the world, velocities untouched.
func _on_origin_shift(d: Vector3) -> void:
	if not is_inside_tree():
		return  # swapped out this frame, freed at its end
	global_position -= d
	reset_physics_interpolation()
	($Lights as CarLights).shift(d)
	var drift_fx := get_node_or_null("Drift") as CarDrift
	if drift_fx != null:
		drift_fx.shift(d)


func wheels_in_contact() -> int:
	var n: int = 0
	for w: VehicleWheel3D in _wheels:
		if w.is_in_contact():
			n += 1
	return n
