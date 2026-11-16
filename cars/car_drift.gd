class_name CarDrift
extends Node3D
## Drift visual and audio FX (T17c): rear tyre smoke particles, skid mark ribbons,
## and slip-driven tyre squeal audio. Keeps draw calls minimal (1 ribbon mesh + 2 emitters).

const MAX_SKID_SEGS: int = 140
const SKID_WIDTH: float = 0.28
const SKID_MIN_STEP: float = 0.45

static var _puff_tex: ImageTexture

var _emitters: Array[CPUParticles3D] = []
var _wheels: Array[VehicleWheel3D] = []
var _skids: Array[Array] = [[], []]  # per rear wheel: Array of [p_left, p_right, alpha]
var _last_pos: Array[Vector3] = [Vector3.INF, Vector3.INF]
var _skid_mi: MeshInstance3D
var _im: ImmediateMesh = ImmediateMesh.new()
var _squeal: AudioStreamPlayer
var _audible: bool = DisplayServer.get_name() != "headless"
@onready var car: Car = get_parent() as Car


func _ready() -> void:
	if _puff_tex == null:
		_puff_tex = _make_puff_tex()
	for w_name: String in ["WheelRL", "WheelRR"]:
		var w := car.get_node_or_null(w_name) as VehicleWheel3D
		if w == null:
			continue
		_wheels.append(w)
		var cp := CPUParticles3D.new()
		cp.name = w_name + "_Smoke"
		cp.position = w.position + Vector3(0.0, -w.wheel_radius + 0.05, 0.0)
		cp.amount = 24
		cp.lifetime = 0.75
		cp.explosiveness = 0.0
		cp.randomness = 0.35
		cp.local_coords = false
		cp.emitting = false
		cp.direction = Vector3(0.0, 0.6, 0.5)
		cp.spread = 32.0
		cp.initial_velocity_min = 0.8
		cp.initial_velocity_max = 2.4
		cp.gravity = Vector3(0.0, 1.4, 0.0)
		cp.scale_amount_min = 0.45
		cp.scale_amount_max = 1.35
		var grad := Gradient.new()
		grad.colors = PackedColorArray([Color(0.86, 0.87, 0.89, 0.38), Color(0.82, 0.83, 0.85, 0.0)])
		cp.color_ramp = grad
		var qm := QuadMesh.new()
		qm.size = Vector2(0.85, 0.85)
		var sm := StandardMaterial3D.new()
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		sm.vertex_color_use_as_albedo = true
		sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		sm.albedo_texture = _puff_tex
		qm.material = sm
		cp.mesh = qm
		add_child(cp)
		_emitters.append(cp)

	_skid_mi = MeshInstance3D.new()
	_skid_mi.top_level = true
	_skid_mi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_skid_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_skid_mi.mesh = _im
	var skid_mat := StandardMaterial3D.new()
	skid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	skid_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	skid_mat.vertex_color_use_as_albedo = true
	skid_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	skid_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_skid_mi.material_override = skid_mat
	add_child(_skid_mi)
	_skid_mi.global_transform = Transform3D.IDENTITY

	_squeal = AudioStreamPlayer.new()
	_squeal.stream = AudioBake.squeal()
	_squeal.bus = &"SFX"
	_squeal.volume_linear = 0.0
	add_child(_squeal)
	if _audible:
		_squeal.play()


static func _make_puff_tex() -> ImageTexture:
	var sz: int = 32
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var half: float = (sz - 1) * 0.5
	for y: int in sz:
		for x: int in sz:
			var dx: float = (x - half) / half
			var dy: float = (y - half) / half
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = clampf(1.0 - smoothstep(0.15, 1.0, d), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	return ImageTexture.create_from_image(img)


func _process(_dt: float) -> void:
	var slip: float = car.skid_intensity
	var smoke_on: bool = slip > 0.22 and car.speed_kmh > 14.0
	var max_amt: int = 14 if Settings.preset == "low" else 24
	for i: int in _emitters.size():
		var cp: CPUParticles3D = _emitters[i]
		var w: VehicleWheel3D = _wheels[i]
		var on: bool = smoke_on and w.is_in_contact()
		if cp.amount != max_amt:
			cp.amount = max_amt
		cp.emitting = on

	if _audible:
		var target_vol: float = clampf((slip - 0.12) / 0.88, 0.0, 1.0) * 0.38 if car.speed_kmh > 10.0 else 0.0
		_squeal.volume_linear = lerpf(_squeal.volume_linear, target_vol, 0.25)
		_squeal.pitch_scale = lerpf(0.88, 1.18, clampf(car.speed_kmh / 140.0, 0.0, 1.0))

	_update_skids(slip)


func _update_skids(slip: float) -> void:
	var dirty: bool = false
	var right: Vector3 = car.global_basis.x * (SKID_WIDTH * 0.5)
	var up_off: Vector3 = car.global_basis.y * 0.03
	for i: int in _wheels.size():
		var w: VehicleWheel3D = _wheels[i]
		if not w.is_in_contact() or slip < 0.18 or car.speed_kmh < 10.0:
			_last_pos[i] = Vector3.INF
			continue
		var contact: Vector3 = w.global_position - car.global_basis.y * w.wheel_radius + up_off
		var prev: Vector3 = _last_pos[i]
		if prev == Vector3.INF:
			_last_pos[i] = contact
			continue
		if prev.distance_to(contact) >= SKID_MIN_STEP:
			var a: float = clampf(slip * 0.72, 0.12, 0.68)
			_skids[i].append([prev - right, prev + right, contact - right, contact + right, a])
			if _skids[i].size() > MAX_SKID_SEGS:
				_skids[i].pop_front()
			_last_pos[i] = contact
			dirty = true
	if dirty:
		_rebuild_skids()


func _rebuild_skids() -> void:
	_im.clear_surfaces()
	var any: bool = false
	for arr: Array in _skids:
		if not arr.is_empty():
			any = true
			break
	if not any:
		return
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for arr: Array in _skids:
		var n: int = arr.size()
		for k: int in n:
			var seg: Array = arr[k]
			var fade: float = clampf(float(k + 1) / float(maxi(n / 4, 1)), 0.0, 1.0)
			var c := Color(0.04, 0.04, 0.045, float(seg[4]) * fade)
			var p0: Vector3 = seg[0]
			var p1: Vector3 = seg[1]
			var p2: Vector3 = seg[2]
			var p3: Vector3 = seg[3]
			for v: Vector3 in [p0, p2, p1, p1, p2, p3]:
				_im.surface_set_color(c)
				_im.surface_add_vertex(v)
	_im.surface_end()


## Floating-origin shift: keep skid ribbons aligned with the world.
func shift(d: Vector3) -> void:
	for i: int in _skids.size():
		if _last_pos[i] != Vector3.INF:
			_last_pos[i] -= d
		for seg: Array in _skids[i]:
			for k: int in 4:
				seg[k] = (seg[k] as Vector3) - d
	_rebuild_skids()


func _exit_tree() -> void:
	if _squeal != null:
		_squeal.stop()
