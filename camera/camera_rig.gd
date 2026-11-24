class_name CameraRig
extends Node3D
## Chase + hood + interior cockpit camera (PLAN 6.5 / R5). Follows car interpolated transform in _process.

enum Mode { CHASE, HOOD, COCKPIT }

const CHASE_BACK: float = 5.6
const CHASE_UP: float = 1.7

var car: Car
var mode: int = Mode.CHASE
var hood: bool = false
var cam: Camera3D
var _yaw: float = 0.0
var _blend_hood: float = 0.0
var _blend_cp: float = 0.0
var _t: float = 0.0
var _noise: FastNoiseLite = FastNoiseLite.new()
# 360 orbit (chase/hood) & driver head look (cockpit)
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.0
var _orbit_idle: float = 0.0
var _look_yaw: float = 0.0
var _lat_lean: float = 0.0
var _zoom: float = 1.0
var _prev_speed: float = 0.0
var _accel_lag: float = 0.0
var _probe: ReflectionProbe
var _probe_age: float = 99.0
var _probe_pos: Vector3 = Vector3(1e9, 0.0, 0.0)
var _probe_dirty: bool = true
var _blur_layer: CanvasLayer
var _blur_rect: ColorRect
var _blur_mat: ShaderMaterial


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_noise.frequency = 1.0
	cam = Camera3D.new()
	cam.far = Settings.draw_distance
	add_child(cam)
	cam.make_current()

	_blur_layer = CanvasLayer.new()
	_blur_layer.name = "MotionBlurLayer"
	_blur_layer.layer = 0
	add_child(_blur_layer)
	_blur_rect = ColorRect.new()
	_blur_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blur_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blur_mat = ShaderMaterial.new()
	_blur_mat.shader = preload("res://shaders/motion_blur.gdshader")
	_blur_rect.material = _blur_mat
	_blur_rect.visible = false
	_blur_layer.add_child(_blur_rect)

	Settings.settings_changed.connect(_apply_settings)
	Origin.shifted.connect(_on_origin_shift)
	_apply_settings()
	snap()


func _ensure_probe(enabled: bool) -> void:
	if enabled and _probe == null:
		_probe = ReflectionProbe.new()
		_probe.name = "CarReflectionProbe"
		_probe.top_level = true
		_probe.size = Vector3(44.0, 24.0, 44.0)
		_probe.blend_distance = 6.0
		_probe.cull_mask = 1  # excludes car visual meshes on layer 2
		_probe.reflection_mask = 3
		_probe.ambient_mode = ReflectionProbe.AMBIENT_DISABLED
		_probe.enable_shadows = false
		_probe.update_mode = ReflectionProbe.UPDATE_ONCE
		add_child(_probe)
		_probe_dirty = true
	elif _probe != null:
		_probe.visible = enabled
		if enabled:
			_probe_dirty = true


func _on_origin_shift(d: Vector3) -> void:
	_probe_pos -= d
	_probe_dirty = true


func _apply_settings() -> void:
	if cam != null:
		cam.far = Settings.draw_distance
	_ensure_probe(Settings.reflections >= 2)
	if _blur_rect != null and not Settings.motion_blur:
		_blur_rect.visible = false


## Jump straight behind the car (spawn, respawn, origin shift).
func snap() -> void:
	if car != null:
		_yaw = _car_yaw(car.global_transform)
		_blend_hood = 1.0 if mode == Mode.HOOD else 0.0
		_blend_cp = 1.0 if mode == Mode.COCKPIT else 0.0
		_look_yaw = 0.0
		_process(0.0)


func set_mode(new_mode: int) -> void:
	mode = clampi(new_mode, Mode.CHASE, Mode.COCKPIT)
	hood = (mode == Mode.HOOD)
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	_look_yaw = 0.0


func _car_yaw(xf: Transform3D) -> float:
	return atan2(xf.basis.z.x, xf.basis.z.z)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		_orbit_yaw -= e.relative.x * 0.006
		_orbit_pitch = clampf(_orbit_pitch + e.relative.y * 0.004, -0.25, 1.2)
		_orbit_idle = 0.0
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom - 0.08, 0.6, 2.2)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom + 0.08, 0.6, 2.2)


func _process(dt: float) -> void:
	if car == null:
		return
	if Input.is_action_just_pressed("camera_toggle"):
		set_mode((mode + 1) % 3)
	var xf: Transform3D = car.get_global_transform_interpolated() if is_inside_tree() and dt > 0.0 else car.global_transform
	var s: float = smoothstep(60.0, 330.0, car.speed_kmh)
	_yaw = lerp_angle(_yaw, _car_yaw(xf), 1.0 - exp(-6.0 * dt) if dt > 0.0 else 1.0)
	var rs := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if rs.length() > 0.2:
		_orbit_yaw -= rs.x * 2.5 * dt
		_orbit_pitch = clampf(_orbit_pitch + rs.y * 1.5 * dt, -0.25, 1.2)
		_orbit_idle = 0.0
	_orbit_idle += dt
	if _orbit_idle > 2.5 and car.speed_kmh > 8.0:
		_orbit_yaw = lerp_angle(_orbit_yaw, 0.0, 1.0 - exp(-3.0 * dt))
		_orbit_pitch = lerpf(_orbit_pitch, 0.0, 1.0 - exp(-3.0 * dt))

	# Look Left/Right in cockpit (Q/E or mouse/stick orbit)
	var look_cmd: float = Input.get_axis("look_right", "look_left") * deg_to_rad(68.0)
	var target_look: float = look_cmd if absf(look_cmd) > 0.05 else clampf(_orbit_yaw, -2.0, 2.0)
	if mode != Mode.COCKPIT:
		target_look = 0.0
	_look_yaw = lerpf(_look_yaw, target_look, 1.0 - exp(-12.0 * dt) if dt > 0.0 else 1.0)

	var accel: float = ((car.speed - _prev_speed) / maxf(dt, 1e-4)) if dt > 1e-4 else 0.0
	_prev_speed = car.speed
	_accel_lag = lerpf(_accel_lag, clampf(accel * 0.014, -0.18, 0.24), 1.0 - exp(-7.0 * dt) if dt > 0.0 else 1.0)
	var lat_g_target: float = clampf(-car.angular_velocity.y * car.speed * 0.0022, -0.042, 0.042)
	_lat_lean = lerpf(_lat_lean, lat_g_target, 1.0 - exp(-8.0 * dt) if dt > 0.0 else 1.0)

	var dist: float = (CHASE_BACK + 0.55 * s + _accel_lag) * _zoom
	var arm: Vector3 = Basis(Vector3.UP, _yaw + _orbit_yaw) * Basis(Vector3.RIGHT, -_orbit_pitch) * Vector3(0.0, 0.0, dist)
	var pos: Vector3 = xf.origin + Vector3(0.0, CHASE_UP * _zoom, 0.0) + arm
	var chase: Transform3D = Transform3D(Basis.IDENTITY, pos).looking_at(xf.origin + Vector3(0.0, 1.0, 0.0))

	if dt > 0.0:
		_blend_hood = move_toward(_blend_hood, 1.0 if mode == Mode.HOOD else 0.0, dt * 4.5)
		_blend_cp = move_toward(_blend_cp, 1.0 if mode == Mode.COCKPIT else 0.0, dt * 4.5)
	var bh: float = smoothstep(0.0, 1.0, _blend_hood)
	var bc: float = smoothstep(0.0, 1.0, _blend_cp)
	car.set_cockpit_active(bc > 0.04)

	var cp_local_pos: Vector3 = car.cockpit_cam + Vector3(_lat_lean, absf(_lat_lean) * -0.15, clampf(_accel_lag * 0.14, -0.03, 0.035))
	var cp_pitch: float = clampf(-_accel_lag * 0.06 - _orbit_pitch * 0.35, -0.45, 0.35)
	var cp_roll: float = clampf(_lat_lean * 0.55, -0.032, 0.032)
	var cp_basis: Basis = Basis(Vector3.UP, _look_yaw) * Basis(Vector3.RIGHT, cp_pitch) * Basis(Vector3.BACK, cp_roll)
	var cp_xf: Transform3D = xf * Transform3D(cp_basis, cp_local_pos)
	var hood_xf: Transform3D = xf * Transform3D(Basis.IDENTITY, car.hood_cam)

	var ext_xf: Transform3D = chase.interpolate_with(hood_xf, bh)
	var out: Transform3D = ext_xf.interpolate_with(cp_xf, bc)
	var base_fov: float = lerpf(lerpf(65.0, 90.0, s), lerpf(70.0, 84.0, s), bh)
	cam.fov = lerpf(base_fov, lerpf(74.0, 84.0, s), bc) + Settings.fov_offset
	cam.near = 0.035 if bc > 0.3 else (0.05 if bh > 0.5 else 0.15)
	global_transform = out
	# speed shake + cockpit suspension head-bob
	_t += dt
	var sh: float = clampf((car.speed_kmh - 140.0) / 180.0, 0.0, 1.0)
	sh = sh * (0.4 + 0.6 * sh)
	var bob_amp: float = lerpf(0.036, 0.016, bc) * sh + bc * clampf(car.speed_kmh / 180.0, 0.0, 1.0) * 0.006
	cam.position = Vector3(_noise.get_noise_1d(_t * 24.0), _noise.get_noise_1d(_t * 24.0 + 50.0), 0.0) * bob_amp
	cam.rotation.z = deg_to_rad(0.28) * sh * (1.0 - 0.5 * bc) * _noise.get_noise_1d(_t * 20.0 + 100.0)

	# Car-following ReflectionProbe (axis-aligned, throttled 1-frame refresh)
	if _probe != null and _probe.visible:
		var p_target: Vector3 = xf.origin + Vector3(0.0, 1.4, 0.0)
		_probe.global_transform = Transform3D(Basis.IDENTITY, p_target)
		_probe_age += dt
		var dist_thr: float = 12.0 if Settings.reflections >= 2 else 85.0
		var time_thr: float = 0.25 if Settings.reflections >= 2 else 2.5
		if _probe_dirty:
			_probe_dirty = false
			_probe_age = 0.0
			_probe_pos = p_target
			_probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
		elif _probe.update_mode == ReflectionProbe.UPDATE_ALWAYS:
			_probe.update_mode = ReflectionProbe.UPDATE_ONCE
		elif _probe_age >= time_thr or p_target.distance_squared_to(_probe_pos) > dist_thr * dist_thr:
			_probe_age = 0.0
			_probe_pos = p_target
			_probe.update_mode = ReflectionProbe.UPDATE_ALWAYS

	# Optional speed radial motion blur
	if _blur_rect != null:
		var mb_on: bool = Settings.motion_blur and car.speed_kmh > 75.0
		_blur_rect.visible = mb_on
		if mb_on:
			var str_v: float = smoothstep(75.0, 325.0, car.speed_kmh) * (0.55 if (bh > 0.5 or bc > 0.5) else 0.85)
			_blur_mat.set_shader_parameter("strength", str_v)
