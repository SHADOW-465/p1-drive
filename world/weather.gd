class_name Weather
extends Node3D
## Medium-baseline weather + rain (L1): clear / overcast / rain states,
## wet-road shader global (wetness), camera-following rain particles, sky darkening.
## Note: Fable's T32/T33 expand this with droplets shader, hill mist, and SSR wet look on High.

@export var day_night_path: NodePath

var overcast: float = 0.0
var rain: float = 0.0
var wetness: float = 0.0

var _particles: CPUParticles3D
var _day_night: DayNight
var _last_count: int = -1


func _ready() -> void:
	if not day_night_path.is_empty():
		_day_night = get_node_or_null(day_night_path) as DayNight
	_particles = CPUParticles3D.new()
	_particles.name = "RainParticles"
	_particles.amount = Settings.rain_particle_count()
	_last_count = _particles.amount
	_particles.lifetime = 0.75
	_particles.local_coords = false
	_particles.emitting = false
	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_particles.emission_box_extents = Vector3(16.0, 1.5, 16.0)
	_particles.direction = Vector3(0.08, -1.0, 0.05)
	_particles.spread = 4.0
	_particles.initial_velocity_min = 20.0
	_particles.initial_velocity_max = 26.0
	_particles.gravity = Vector3.ZERO
	var qm := QuadMesh.new()
	qm.size = Vector2(0.028, 0.72)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.albedo_color = Color(0.75, 0.83, 0.94, 0.40)
	sm.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	qm.material = sm
	_particles.mesh = qm
	add_child(_particles)
	Settings.settings_changed.connect(_on_settings_changed)


func _on_settings_changed() -> void:
	var target_cnt: int = Settings.rain_particle_count()
	if _particles != null and target_cnt != _last_count:
		_last_count = target_cnt
		_particles.amount = target_cnt


func _process(dt: float) -> void:
	var mode: String = Settings.weather_mode
	var tgt_overcast: float = 1.0 if (mode == "overcast" or mode == "rain") else 0.0
	var tgt_rain: float = 1.0 if mode == "rain" else 0.0
	var tgt_wet: float = 1.0 if mode == "rain" else 0.0
	overcast = move_toward(overcast, tgt_overcast, dt * 0.4)
	rain = move_toward(rain, tgt_rain, dt * 0.45)
	var wet_rate: float = 0.35 if tgt_wet > wetness else 0.14
	var prev_wet: float = wetness
	wetness = move_toward(wetness, tgt_wet, dt * wet_rate)
	if absf(wetness - prev_wet) > 0.002 or (wetness == 0.0 and prev_wet > 0.0) or (wetness == 1.0 and prev_wet < 1.0):
		RenderingServer.global_shader_parameter_set("wetness", wetness)

	if _day_night != null:
		_day_night.weather_darkening = maxf(overcast * 0.42, rain * 0.62)
		_day_night.weather_fog_scale = lerpf(1.0, 0.42, maxf(overcast * 0.55, rain))

	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null and DisplayServer.get_name() != "headless":
		_particles.global_position = cam.global_position + Vector3(0.0, 12.0, 0.0) - cam.global_basis.z * 8.0
		_particles.emitting = rain > 0.08
	else:
		_particles.emitting = false
