class_name Cockpit
extends Node3D
## Cockpit view (S2): turning steering wheel, live digital cluster, working mirrors, cabin light.
## Config comes from the car's data/cars.json "cockpit" block. P1 builds its own interior (P1Interior);
## GLB cars (model_interior) keep the model's dash/seats and only lend us their steering wheel meshes.

const ACCENT: Color = Color(1.0, 0.38, 0.04)

var max_wheel_deg: float = 135.0
var model_interior: bool = false

var _car: Car
var _cfg: Dictionary = {}
var _mount: Node3D
var _wheel_pivot: Node3D
var _sv: SubViewport
var _cluster_draw: _ClusterDisplay
var _overlay: Node3D  # cluster, mirrors, cabin light: shown only in the cockpit view
var _mirrors: Array[CarMirror] = []
var _glb: GlbBody
var _speed_cache: int = -1
var _gear_cache: String = ""
var _rpm_cache: int = -1
var _aero_cache: String = ""
var _active: bool = false


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _ready() -> void:
	_car = get_parent() as Car
	_cfg = CarRegistry.get_def(str(_car.get_meta("car_id", "p1"))).get("cockpit", {})
	model_interior = bool(_cfg.get("model_interior", false))
	_glb = _car.get_node_or_null("Body") as GlbBody
	_overlay = Node3D.new()
	_overlay.name = "Overlay"
	add_child(_overlay)
	if model_interior:
		_adopt_model_wheel()
	else:
		_build_p1_interior()
		_build_p1_wheel()
	_build_cluster()
	if not model_interior:
		_build_iris()
	_build_mirrors()
	# Car-layer fill only. GLB cabins already have their own shading; a strong lamp blows the headliner out.
	var cl := OmniLight3D.new()
	cl.position = _v3(_cfg.get("cabin_light", [0.0, 0.7, 0.1]))
	cl.omni_range = 2.2
	cl.omni_attenuation = 1.2
	cl.light_energy = 0.45 if model_interior else 1.5
	cl.light_color = Color(1.0, 0.94, 0.88)
	cl.light_cull_mask = 2
	cl.shadow_enabled = false
	_overlay.add_child(cl)
	if not model_interior:
		var dash := OmniLight3D.new()
		dash.position = _v3(_cfg.get("dash_light", [-0.15, 0.78, -0.35]))
		dash.omni_range = 1.35
		dash.omni_attenuation = 1.5
		dash.light_energy = 1.15
		dash.light_color = Color(1.0, 0.88, 0.75)
		dash.light_cull_mask = 2
		dash.shadow_enabled = false
		_overlay.add_child(dash)
	set_cockpit_active(false)


func set_cockpit_active(on: bool) -> void:
	_active = on
	_overlay.visible = on
	if _sv != null:
		_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	for m: CarMirror in _mirrors:
		m.set_active(on)
	if _glb != null:
		_glb.set_cockpit(on)


func _process(_dt: float) -> void:
	if not _active or _car == null:
		return
	if _wheel_pivot != null:
		_wheel_pivot.rotation.z = -_car.steer_ratio * deg_to_rad(max_wheel_deg)
	if _cluster_draw != null:
		var spd: int = int(roundf(_car.speed_kmh))
		var g_lbl: String = _car.drivetrain.gear_label()
		var rpm_q: int = int(roundf(_car.drivetrain.rpm / 120.0))
		var aero_n: Node = _car.find_child("Aero", true, false)
		var aero_s: String = (aero_n as ActiveAero).state_name() if aero_n is ActiveAero else "SPORT"
		if spd != _speed_cache or g_lbl != _gear_cache or rpm_q != _rpm_cache or aero_s != _aero_cache:
			_speed_cache = spd
			_gear_cache = g_lbl
			_rpm_cache = rpm_q
			_aero_cache = aero_s
			_cluster_draw.update_state(spd, g_lbl, _car.drivetrain.rpm / Drivetrain.REDLINE, aero_s, ACCENT)


func _make_mount(pos: Vector3, tilt_deg: float) -> void:
	_mount = Node3D.new()
	_mount.name = "SteeringMount"
	_mount.position = pos
	_mount.rotation.x = -deg_to_rad(tilt_deg)
	add_child(_mount)
	_wheel_pivot = Node3D.new()
	_wheel_pivot.name = "SteeringWheel"
	_mount.add_child(_wheel_pivot)


## GLB car: pull the model's steering-wheel meshes under a pivot on the column axis so they turn with the input.
func _adopt_model_wheel() -> void:
	if _glb == null:
		return
	var meshes: Array[MeshInstance3D] = _glb.take_meshes(_cfg.get("steer_match", ["SteeringWheel"]))
	if meshes.is_empty():
		return
	var bb := AABB()
	for i: int in meshes.size():
		var b: AABB = meshes[i].transform * meshes[i].get_aabb()
		bb = b if i == 0 else bb.merge(b)
	_make_mount(bb.get_center(), float(_cfg.get("wheel_tilt", 22.0)))
	var inv: Transform3D = _mount.transform.affine_inverse()
	for m: MeshInstance3D in meshes:
		var xf: Transform3D = inv * m.transform
		_wheel_pivot.add_child(m)
		m.transform = xf


func _build_p1_interior() -> void:
	var ms: Dictionary = P1Interior.meshes()
	for k: String in ms:
		var mi := MeshInstance3D.new()
		mi.name = "Interior_" + k
		mi.mesh = ms[k]
		mi.layers = 2
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


func _build_p1_wheel() -> void:
	_make_mount(_v3(_cfg.get("wheel_pos", [-0.34, 0.76, -0.46])), float(_cfg.get("wheel_tilt", 24.0)))
	var lea := MeshBuilder.new()
	var car := MeshBuilder.new()
	var alu := MeshBuilder.new()
	var acc := MeshBuilder.new()
	var pla := MeshBuilder.new()
	var c_lea := Color(0.07, 0.07, 0.075)
	var c_car := Color(0.22, 0.22, 0.24)
	var c_alu := Color(0.3, 0.3, 0.32)
	var c_pla := Color(0.02, 0.02, 0.022)
	var orange := Color(1.0, 0.38, 0.04)
	# flat-bottom, slightly flattened-top rim, leather with an orange 12 o'clock stripe
	const R: float = 0.172
	var ring := PackedVector3Array()
	var top := PackedVector3Array()
	for i: int in 56:
		var a: float = TAU * i / 56.0
		var p := Vector3(sin(a) * R, clampf(cos(a) * R, -0.138, 0.165), 0.0)
		ring.append(p)
	for i: int in range(-4, 5):
		var a2: float = TAU * i / 56.0
		top.append(Vector3(sin(a2) * R, clampf(cos(a2) * R, -0.138, 0.165), 0.0006))
	P1Interior.tube(lea, ring, 0.0135, c_lea, true, 10)
	P1Interior.tube(acc, top, 0.0145, orange, false, 8)
	# hub, spokes (aluminium) with carbon trim, centre cap, buttons with accent LEDs
	car.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.005)), Vector3(0.115, 0.1, 0.034), c_car)
	alu.box(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.014)), Vector3(0.05, 0.048, 0.006), c_alu)
	acc.ellipsoid(Vector3(0.0, 0.0, 0.019), Vector3(0.012, 0.012, 0.003), orange)
	for sx: float in [-1.0, 1.0]:
		# carbon spoke from the hub out to the rim, thin aluminium edge on the driver side
		car.box(Transform3D(Basis(Vector3.BACK, sx * 0.02), Vector3(sx * 0.092, 0.0, -0.002)), Vector3(0.15, 0.026, 0.012), c_car)
		alu.box(Transform3D(Basis(Vector3.BACK, sx * 0.02), Vector3(sx * 0.092, 0.0, 0.006)), Vector3(0.13, 0.012, 0.004), c_alu)
		for k: int in 3:
			var bp := Vector3(sx * (0.085 + 0.022 * k), 0.012 * (k % 2) - 0.004, 0.013)
			pla.ellipsoid(bp, Vector3(0.008, 0.008, 0.004), c_pla)
			acc.ellipsoid(bp + Vector3(0.0, 0.0, 0.003), Vector3(0.004, 0.004, 0.0015), orange if k != 1 else Color(0.2, 0.8, 1.0))
	alu.box(Transform3D(Basis.IDENTITY, Vector3(0.0, -0.085, -0.004)), Vector3(0.05, 0.075, 0.012), c_alu)
	car.box(Transform3D(Basis.IDENTITY, Vector3(0.0, -0.085, 0.003)), Vector3(0.036, 0.06, 0.004), c_car)
	for pair: Array in [[lea, "lea"], [car, "carbon"], [alu, "alu"], [acc, "accent"], [pla, "plastic"]]:
		var mi := MeshInstance3D.new()
		mi.mesh = (pair[0] as MeshBuilder).mesh(P1Interior.material(pair[1]))
		mi.layers = 2
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_wheel_pivot.add_child(mi)
	# paddle shifters stay on the column
	var pad := MeshBuilder.new()
	for sx: float in [-1.0, 1.0]:
		pad.box(Transform3D(Basis(Vector3.BACK, sx * -0.12), Vector3(sx * 0.118, 0.03, -0.045)), Vector3(0.024, 0.1, 0.005), c_alu)
	var pmi := MeshInstance3D.new()
	pmi.mesh = pad.mesh(P1Interior.material("alu"))
	pmi.layers = 2
	_mount.add_child(pmi)


func _build_cluster() -> void:
	var cp: Vector3 = _v3(_cfg.get("cluster_pos", [-0.34, 0.836, -0.578]))
	var csz: Array = _cfg.get("cluster_size", [0.20, 0.085])
	_sv = SubViewport.new()
	_sv.size = Vector2i(280, 118)
	_sv.transparent_bg = false
	_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sv)
	_cluster_draw = _ClusterDisplay.new()
	_cluster_draw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sv.add_child(_cluster_draw)
	var quad := QuadMesh.new()
	quad.size = Vector2(float(csz[0]), float(csz[1]))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _sv.get_texture()
	var scr := MeshInstance3D.new()
	scr.name = "DigitalCluster"
	scr.layers = 2
	scr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tilt := deg_to_rad(float(_cfg.get("cluster_tilt", -14.0)))
	var basis := Basis(Vector3.RIGHT, tilt)
	# QuadMesh faces +Z. Sit it 2 cm proud of the binnacle, toward the driver, so it is not buried in the dash.
	scr.transform = Transform3D(basis, cp + basis * Vector3(0.0, 0.0, 0.02))
	scr.mesh = quad
	scr.material_override = mat
	mat.render_priority = 1
	_overlay.add_child(scr)


## Portrait infotainment screen on the P1 fascia: drawn once, no per-frame cost.
func _build_iris() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(150, 210)
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(sv)
	var disp := _IrisDisplay.new()
	disp.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(disp)
	var qm := QuadMesh.new()
	qm.size = P1Interior.IRIS_SIZE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = sv.get_texture()
	var mi := MeshInstance3D.new()
	mi.name = "IrisScreen"
	mi.mesh = qm
	mi.material_override = mat
	mi.layers = 2
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis.looking_at(-P1Interior.IRIS_N, Vector3.UP), P1Interior.IRIS_POS + P1Interior.IRIS_N * 0.004)
	add_child(mi)


func _build_mirrors() -> void:
	for md: Dictionary in _cfg.get("mirrors", []):
		if Settings.preset != "high" and str(md.get("name", "")) != "rear":
			continue  # side mirrors only on High: each is a second full scene render (PLAN 6.3)
		var mir := CarMirror.new()
		mir.name = "Mirror_" + str(md.get("name", "m"))
		_overlay.add_child(mir)
		var sz: Array = md["size"]
		var res: Array = md.get("res", [256, 80])
		mir.setup(_car, _v3(md["pos"]), _v3(md["normal"]).normalized(), Vector2(float(sz[0]), float(sz[1])), _v3(md["cam"]), float(md["cam_yaw"]), Vector2i(int(res[0]), int(res[1])), float(md.get("fov", 40.0)), maxi(int(md.get("every", 2)), 2 if Settings.preset == "high" else 4))
		_mirrors.append(mir)


class _IrisDisplay extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.06), true)
		var font: Font = ThemeDB.fallback_font
		draw_rect(Rect2(0, 0, size.x, 22), Color(0.07, 0.09, 0.12), true)
		if font != null:
			draw_string(font, Vector2(8, 16), "P1", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.38, 0.04))
			draw_string(font, Vector2(size.x - 52, 16), "21 C", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.76, 0.84))
		# nav map: road, route and position arrow
		draw_rect(Rect2(6, 28, size.x - 12, 104), Color(0.07, 0.11, 0.09), true)
		for k: int in 6:
			draw_line(Vector2(6, 40 + k * 18), Vector2(size.x - 6, 52 + k * 14), Color(0.16, 0.2, 0.19), 2.0)
		draw_polyline(PackedVector2Array([Vector2(20, 124), Vector2(52, 92), Vector2(80, 86), Vector2(104, 52), Vector2(128, 40)]), Color(1.0, 0.38, 0.04), 3.0)
		draw_colored_polygon(PackedVector2Array([Vector2(52, 82), Vector2(60, 100), Vector2(52, 96), Vector2(44, 100)]), Color(0.9, 0.95, 1.0))
		for k: int in 3:
			draw_rect(Rect2(8 + k * 46, 142, 42, 28), Color(0.1, 0.13, 0.18), true)
			draw_rect(Rect2(8 + k * 46, 142, 42, 28), Color(0.2, 0.26, 0.34), false, 1.0)
		for k: int in 5:
			draw_rect(Rect2(10 + k * 27, 182, 22, 18), Color(1.0, 0.38, 0.04) if k == 1 else Color(0.12, 0.16, 0.22), true)


class _ClusterDisplay extends Control:
	var speed_val: int = 0
	var gear_str: String = "1"
	var rpm_frac: float = 0.1
	var aero_str: String = "LOW"
	var accent: Color = Color(1.0, 0.38, 0.04)

	func update_state(spd: int, gear: String, rpm_f: float, aero: String, ac: Color) -> void:
		speed_val = spd
		gear_str = gear
		rpm_frac = clampf(rpm_f, 0.0, 1.0)
		aero_str = aero
		accent = ac
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.045, 0.065, 1.0), true)
		draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), Color(0.18, 0.22, 0.28, 0.9), false, 2.0)

		# 14-segment McLaren F1-style shift LED bar across the top
		var n_seg: int = 14
		var pad_x: float = 22.0
		var sw: float = (size.x - pad_x * 2.0) / float(n_seg) - 2.5
		for i: int in n_seg:
			var frac: float = float(i + 1) / float(n_seg)
			var lit: bool = rpm_frac >= frac * 0.94
			var col: Color = Color(0.14, 0.85, 0.42) if i < 6 else (Color(1.0, 0.56, 0.08) if i < 11 else Color(1.0, 0.15, 0.12))
			if not lit:
				col = Color(0.10, 0.12, 0.16, 1.0)
			draw_rect(Rect2(pad_x + float(i) * (sw + 2.5), 10.0, sw, 10.0), col, true)

		var font: Font = ThemeDB.fallback_font
		if font == null:
			return
		draw_string(font, Vector2(22.0, 46.0), aero_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, accent)
		draw_string(font, Vector2(22.0, 100.0), "%.1fk" % (rpm_frac * 8.25), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.70, 0.76, 0.84))

		var gear_box := Rect2(size.x * 0.5 - 23.0, 30.0, 46.0, 56.0)
		draw_rect(gear_box, Color(0.08, 0.10, 0.14), true)
		draw_rect(gear_box, accent, false, 2.0)
		draw_string(font, Vector2(gear_box.position.x + 13.0, 74.0), gear_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 36, Color(1.0, 0.96, 0.92))

		var sp_txt: String = "%3d" % speed_val
		draw_string(font, Vector2(size.x - 98.0, 72.0), sp_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 38, Color(0.95, 0.97, 1.0))
		draw_string(font, Vector2(size.x - 66.0, 100.0), "km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.62, 0.68, 0.76))
