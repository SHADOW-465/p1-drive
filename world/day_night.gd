class_name DayNight
extends Node
## Realistic HDRI day/night sky + lighting (R1): blends 2K Poly Haven CC0 HDRIs
## (day, sunset, night, overcast) with dynamic sun Mie glow, ACES/Filmic tonemap,
## auto exposure, atmospheric distance haze, volumetric fog (Forward+), and cascades.

const CYCLE_HOURS_PER_SEC: float = 24.0 / (24.0 * 60.0)  # 24 real min per full cycle

const TEX_DAY_PATH: String = "res://assets/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
const TEX_SUNSET_PATH: String = "res://assets/hdri/qwantani_sunset_puresky_2k.hdr"
const TEX_NIGHT_PATH: String = "res://assets/hdri/qwantani_night_puresky_2k.hdr"
const TEX_OVERCAST_PATH: String = "res://assets/hdri/kloofendal_overcast_puresky_2k.hdr"

static var night_factor: float = 0.0  # 0 day .. 1 night, mirrors the shader global

@export var hour: float = 17.0
@export var cycle_enabled: bool = true

var env: Environment
var cam_attrs: CameraAttributesPractical
var sky: Sky
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var moon: MeshInstance3D
var weather_darkening: float = 0.0
var weather_fog_scale: float = 1.0

var _sun_col_grad: Gradient
var _fog_col_grad: Gradient
var _moon_mat: StandardMaterial3D
var _we: WorldEnvironment
var _since_apply: float = 0.0
var _moon_dir: Vector3 = Vector3.UP


func _ready() -> void:
	_init_gradients()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("tex_day", load(TEX_DAY_PATH))
	sky_mat.set_shader_parameter("tex_sunset", load(TEX_SUNSET_PATH))
	sky_mat.set_shader_parameter("tex_night", load(TEX_NIGHT_PATH))
	sky_mat.set_shader_parameter("tex_overcast", load(TEX_OVERCAST_PATH))

	sky = Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.55, 0.58, 0.68)
	env.ambient_light_energy = 0.72
	env.ambient_light_sky_contribution = 0.90
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0

	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_strength = 0.85
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 1.15
	env.glow_hdr_scale = 2.0

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.00038
	env.fog_aerial_perspective = 0.75
	env.fog_sun_scatter = 0.45
	env.fog_sky_affect = 0.12
	env.fog_height = 28.0
	env.fog_height_density = 0.0012

	# Forward+-only enhancements (silently enabled where renderer allows).
	env.ssao_radius = 1.2
	env.ssao_intensity = 1.6
	env.ssao_power = 1.5
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.85
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.35
	env.volumetric_fog_density = 0.0028
	env.volumetric_fog_anisotropy = 0.65
	env.volumetric_fog_length = 240.0
	env.volumetric_fog_sky_affect = 0.22

	cam_attrs = CameraAttributesPractical.new()
	var is_fwd: bool = RenderingServer.get_current_rendering_method() == "forward_plus"
	cam_attrs.auto_exposure_enabled = is_fwd and Settings.preset != "low"
	cam_attrs.auto_exposure_scale = 0.34
	cam_attrs.auto_exposure_speed = 1.6
	cam_attrs.auto_exposure_min_sensitivity = 60.0
	cam_attrs.auto_exposure_max_sensitivity = 220.0

	_we = WorldEnvironment.new()
	_we.environment = env
	_we.camera_attributes = cam_attrs
	add_child(_we)

	sun = DirectionalLight3D.new()
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.4
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	add_child(sun)

	moon = MeshInstance3D.new()
	var ms := SphereMesh.new()
	ms.radius = 11.0
	ms.height = 22.0
	ms.radial_segments = 16
	ms.rings = 8
	moon.mesh = ms
	_moon_mat = StandardMaterial3D.new()
	_moon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_moon_mat.albedo_color = Color(0.92, 0.95, 1.0)
	_moon_mat.disable_fog = true
	moon.material_override = _moon_mat
	moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(moon)

	Settings.settings_changed.connect(_on_settings_changed)
	Settings.apply_graphics_to_world(env, sun)
	_apply_time(true)


func _init_gradients() -> void:
	# Normalized t = hour / 24.0 (0 = midnight, 0.25 = 6h, 0.5 = 12h, 0.75 = 18h)
	_sun_col_grad = _grad([
		[0.0, Color(0.45, 0.58, 0.85)],
		[0.25, Color(1.0, 0.65, 0.36)],
		[0.33, Color(1.0, 0.93, 0.84)],
		[0.50, Color(1.0, 0.98, 0.95)],
		[0.69, Color(1.0, 0.86, 0.66)],
		[0.75, Color(1.0, 0.56, 0.30)],
		[0.82, Color(0.45, 0.58, 0.85)],
		[1.0, Color(0.45, 0.58, 0.85)],
	])
	_fog_col_grad = _grad([
		[0.0, Color(0.05, 0.07, 0.13)],
		[0.25, Color(0.76, 0.54, 0.42)],
		[0.36, Color(0.66, 0.78, 0.90)],
		[0.50, Color(0.68, 0.80, 0.93)],
		[0.70, Color(0.86, 0.68, 0.52)],
		[0.77, Color(0.74, 0.46, 0.34)],
		[0.83, Color(0.09, 0.12, 0.20)],
		[1.0, Color(0.05, 0.07, 0.13)],
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
	# The sun moves 0.25 deg/s. Every sky parameter change re-renders the sky radiance (~2 ms GPU on a 610M),
	# so the sky, light and fog follow once a second; only the moon tracks the camera every frame.
	_since_apply += dt
	if _since_apply >= 1.0:
		_since_apply = 0.0
		_apply_time(false)
	else:
		_place_moon()


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
	var sun_col: Color = _sun_col_grad.sample(t)
	if is_night_light:
		sun_elev = maxf(-elev_deg, 12.0)
		sun.rotation_degrees = Vector3(-sun_elev, azim_deg + 180.0, 0.0)
		sun.light_color = Color(0.45, 0.58, 0.86)
		sun.light_energy = 0.30 * (1.0 - 0.5 * weather_darkening)
	else:
		sun.rotation_degrees = Vector3(-maxf(sun_elev, 2.0), azim_deg, 0.0)
		sun.light_color = sun_col.lerp(Color(0.75, 0.80, 0.86), weather_darkening * 0.65)
		var day_e: float = lerpf(0.95, 2.35, smoothstep(0.0, 28.0, elev_deg))
		sun.light_energy = day_e * (1.0 - 0.68 * weather_darkening)
	sun.shadow_enabled = Settings.shadow_quality > 0 and night_factor < 0.85

	var sunset_raw: float = clampf(1.0 - absf(elev_deg - 6.0) / 19.0, 0.0, 1.0)
	var sunset_w: float = smoothstep(0.0, 1.0, sunset_raw) * (1.0 - night_factor)
	var overcast_w: float = clampf(weather_darkening * 1.45, 0.0, 1.0)

	var overcast_col := Color(0.36, 0.40, 0.46)
	var fog_c: Color = _fog_col_grad.sample(t).lerp(overcast_col * (1.0 - 0.68 * night_factor), weather_darkening)

	var sun_dir_v: Vector3 = (Basis.from_euler(Vector3(deg_to_rad(-elev_deg), deg_to_rad(azim_deg), 0.0)) * Vector3.BACK).normalized()
	var moon_dir_v: Vector3 = (Basis.from_euler(Vector3(deg_to_rad(-maxf(-elev_deg, 15.0)), deg_to_rad(azim_deg + 180.0), 0.0)) * Vector3.BACK).normalized()

	sky_mat.set_shader_parameter("sunset_weight", sunset_w)
	sky_mat.set_shader_parameter("night_weight", night_factor)
	sky_mat.set_shader_parameter("overcast_weight", overcast_w)
	sky_mat.set_shader_parameter("sun_dir", sun_dir_v)
	sky_mat.set_shader_parameter("sun_color", Vector3(sun_col.r, sun_col.g, sun_col.b))
	sky_mat.set_shader_parameter("sun_intensity", lerpf(0.65, 1.15, smoothstep(0.0, 20.0, elev_deg)))
	sky_mat.set_shader_parameter("moon_dir", moon_dir_v)
	sky_mat.set_shader_parameter("sky_exposure", lerpf(0.68, 0.36, night_factor) * (1.0 - 0.18 * weather_darkening))
	sky_mat.set_shader_parameter("horizon_haze_color", Vector3(fog_c.r, fog_c.g, fog_c.b))
	sky_mat.set_shader_parameter("horizon_haze_amount", lerpf(0.42, 0.85, overcast_w))

	if not cam_attrs.auto_exposure_enabled:
		env.tonemap_exposure = lerpf(1.02, 1.15, night_factor) * (1.0 + 0.08 * weather_darkening)
	else:
		env.tonemap_exposure = 1.0

	env.fog_light_color = fog_c
	env.fog_light_energy = lerpf(1.0, 0.35, night_factor) * (1.0 - 0.25 * weather_darkening)
	var dist_scale: float = 3600.0 / maxf(Settings.draw_distance, 1200.0)
	env.fog_density = lerpf(0.00036, 0.0022, 1.0 - weather_fog_scale) * dist_scale
	env.fog_aerial_perspective = lerpf(0.75, 0.35, weather_darkening) * (1.0 - 0.55 * night_factor)
	env.fog_sun_scatter = lerpf(0.55, 0.06, weather_darkening) * (1.0 - night_factor)
	env.fog_sky_affect = lerpf(0.10, 0.48, 1.0 - weather_fog_scale)
	env.fog_height_density = lerpf(0.0008, 0.0045, maxf(overcast_w, sunset_w * 0.45))

	if env.volumetric_fog_enabled:
		env.volumetric_fog_albedo = fog_c.lerp(Color.WHITE, 0.35)
		env.volumetric_fog_density = lerpf(0.0022, 0.0095, 1.0 - weather_fog_scale)

	env.ambient_light_energy = lerpf(0.76, 0.26, night_factor) * (1.0 - 0.28 * weather_darkening)

	_moon_dir = moon_dir_v
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		moon.global_position = cam.global_position + moon_dir_v * 480.0
		moon.visible = night_factor > 0.12 and weather_darkening < 0.6
		_moon_mat.albedo_color = Color(0.92, 0.95, 1.0) * clampf(night_factor * 1.2, 0.0, 1.0)


func _place_moon() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		moon.global_position = cam.global_position + _moon_dir * 480.0


func _on_settings_changed() -> void:
	_apply_time(true)
