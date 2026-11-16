class_name DayNight
extends Node
## Medium-baseline day/night sky (L1): gradient procedural sky, sun + moon,
## depth fog, time_skip (T), and night_factor shader global for headlights/streetlights.
## Note: Fable's T21 upgrades this for High preset (HDRI/advanced atmosphere).

const CYCLE_HOURS_PER_SEC: float = 24.0 / (24.0 * 60.0)  # 24 real min per full cycle

static var night_factor: float = 0.0  # 0 day .. 1 night, mirrors the shader global

@export var hour: float = 17.0
@export var cycle_enabled: bool = true

var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var moon: MeshInstance3D
var weather_darkening: float = 0.0
var weather_fog_scale: float = 1.0

var _sky_top_grad: Gradient
var _horizon_grad: Gradient
var _sun_col_grad: Gradient
var _fog_col_grad: Gradient
var _moon_mat: StandardMaterial3D


func _ready() -> void:
	_init_gradients()
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sun_angle_max = 10.0
	sky_mat.sky_curve = 0.14
	sky_mat.ground_curve = 0.08
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.55, 0.58, 0.68)
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	add_child(sun)

	moon = MeshInstance3D.new()
	var ms := SphereMesh.new()
	ms.radius = 12.0
	ms.height = 24.0
	ms.radial_segments = 12
	ms.rings = 6
	moon.mesh = ms
	_moon_mat = StandardMaterial3D.new()
	_moon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_moon_mat.albedo_color = Color(0.90, 0.94, 1.0)
	_moon_mat.disable_fog = true
	moon.material_override = _moon_mat
	moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(moon)

	Settings.settings_changed.connect(_on_settings_changed)
	Settings.apply_graphics_to_world(env, sun)
	_apply_time(true)


func _init_gradients() -> void:
	# Normalized t = hour / 24.0 (0 = midnight, 0.25 = 6h, 0.5 = 12h, 0.75 = 18h)
	_sky_top_grad = _grad([
		[0.0, Color(0.02, 0.03, 0.07)],
		[0.22, Color(0.05, 0.08, 0.16)],
		[0.27, Color(0.18, 0.30, 0.54)],
		[0.50, Color(0.16, 0.42, 0.78)],
		[0.72, Color(0.20, 0.36, 0.62)],
		[0.78, Color(0.12, 0.16, 0.32)],
		[0.85, Color(0.03, 0.04, 0.09)],
		[1.0, Color(0.02, 0.03, 0.07)],
	])
	_horizon_grad = _grad([
		[0.0, Color(0.04, 0.06, 0.11)],
		[0.23, Color(0.32, 0.24, 0.30)],
		[0.27, Color(0.95, 0.58, 0.36)],
		[0.35, Color(0.65, 0.78, 0.92)],
		[0.50, Color(0.60, 0.78, 0.95)],
		[0.71, Color(0.92, 0.66, 0.44)],
		[0.76, Color(0.95, 0.46, 0.28)],
		[0.82, Color(0.16, 0.14, 0.24)],
		[0.88, Color(0.04, 0.06, 0.11)],
		[1.0, Color(0.04, 0.06, 0.11)],
	])
	_sun_col_grad = _grad([
		[0.0, Color(0.45, 0.58, 0.85)],
		[0.25, Color(1.0, 0.68, 0.42)],
		[0.35, Color(1.0, 0.95, 0.88)],
		[0.50, Color(1.0, 0.98, 0.94)],
		[0.70, Color(1.0, 0.84, 0.64)],
		[0.77, Color(1.0, 0.56, 0.34)],
		[0.82, Color(0.45, 0.58, 0.85)],
		[1.0, Color(0.45, 0.58, 0.85)],
	])
	_fog_col_grad = _grad([
		[0.0, Color(0.04, 0.06, 0.11)],
		[0.26, Color(0.75, 0.54, 0.42)],
		[0.45, Color(0.66, 0.78, 0.88)],
		[0.72, Color(0.84, 0.64, 0.48)],
		[0.82, Color(0.10, 0.12, 0.20)],
		[1.0, Color(0.04, 0.06, 0.11)],
	])


static func _grad(stops: Array) -> Gradient:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	var cols := PackedColorArray()
	for s: Array in stops:
		offs.append(s[0])
		cols.append(s[1])
	g.offsets = offs
	g.colors = cols
	return g


func set_time(new_hour: float) -> void:
	hour = fposmod(new_hour, 24.0)
	_apply_time(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("time_skip"):
		set_time(hour + 1.0)


func _process(dt: float) -> void:
	if cycle_enabled:
		hour = fposmod(hour + dt * CYCLE_HOURS_PER_SEC, 24.0)
	_apply_time(false)


func _apply_time(force_global: bool) -> void:
	var t: float = fposmod(hour, 24.0) / 24.0
	var elev_deg: float = sin((hour - 6.0) / 24.0 * TAU) * 68.0
	var azim_deg: float = (hour - 6.0) / 12.0 * 180.0 - 90.0
	var prev_night: float = night_factor
	night_factor = 1.0 - smoothstep(-6.0, 4.0, elev_deg)
	if force_global or absf(night_factor - prev_night) > 0.001:
		RenderingServer.global_shader_parameter_set("night_factor", night_factor)

	# Directional light: sun above horizon, cool moonlight below horizon.
	var sun_elev: float = elev_deg
	var is_night_light: bool = elev_deg <= -2.0
	if is_night_light:
		sun_elev = maxf(-elev_deg, 12.0)
		sun.rotation_degrees = Vector3(-sun_elev, azim_deg + 180.0, 0.0)
		sun.light_color = Color(0.45, 0.58, 0.85)
		sun.light_energy = 0.26 * (1.0 - 0.5 * weather_darkening)
	else:
		sun.rotation_degrees = Vector3(-maxf(sun_elev, 2.0), azim_deg, 0.0)
		sun.light_color = _sun_col_grad.sample(t)
		var day_e: float = lerpf(0.55, 1.45, smoothstep(0.0, 28.0, elev_deg))
		sun.light_energy = day_e * (1.0 - 0.65 * weather_darkening)
	sun.shadow_enabled = Settings.shadow_quality > 0 and night_factor < 0.85

	var overcast_col := Color(0.36, 0.40, 0.45)
	var top_c: Color = _sky_top_grad.sample(t).lerp(overcast_col * (1.0 - 0.7 * night_factor), weather_darkening)
	var hor_c: Color = _horizon_grad.sample(t).lerp(overcast_col * (1.0 - 0.7 * night_factor), weather_darkening)
	var fog_c: Color = _fog_col_grad.sample(t).lerp(overcast_col * (1.0 - 0.7 * night_factor), weather_darkening)

	sky_mat.sky_top_color = top_c
	sky_mat.sky_horizon_color = hor_c
	sky_mat.ground_horizon_color = hor_c
	sky_mat.ground_bottom_color = top_c * 0.25
	sky_mat.sun_curve = lerpf(0.08, 0.4, weather_darkening)

	env.fog_light_color = fog_c
	var base_end: float = clampf(Settings.draw_distance * 0.9, 1200.0, 4200.0)
	env.fog_depth_end = base_end * weather_fog_scale
	env.fog_depth_begin = env.fog_depth_end * lerpf(0.11, 0.04, 1.0 - weather_fog_scale)
	env.ambient_light_energy = lerpf(0.68, 0.30, night_factor) * (1.0 - 0.25 * weather_darkening)

	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var moon_dir: Vector3 = (Basis.from_euler(Vector3(deg_to_rad(-maxf(-elev_deg, 15.0)), deg_to_rad(azim_deg + 180.0), 0.0)) * Vector3.BACK).normalized()
		moon.global_position = cam.global_position + moon_dir * 480.0
		moon.visible = night_factor > 0.12 and weather_darkening < 0.6
		_moon_mat.albedo_color = Color(0.90, 0.94, 1.0) * clampf(night_factor * 1.2, 0.0, 1.0)


func _on_settings_changed() -> void:
	_apply_time(true)
