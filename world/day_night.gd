class_name DayNight
extends Node
## Sky, sun, fog (PLAN 2.7). Static late afternoon for now; the cycle arrives in T21.

static var night_factor: float = 0.0  # 0 day .. 1 night, mirrors the shader global

var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D


func _ready() -> void:
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.38, 0.62)
	sky_mat.sky_horizon_color = Color(0.95, 0.68, 0.45)
	sky_mat.ground_bottom_color = Color(0.12, 0.13, 0.12)
	sky_mat.ground_horizon_color = Color(0.95, 0.68, 0.45)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.68)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 400.0
	env.fog_depth_end = 3600.0
	env.fog_light_color = Color(0.85, 0.66, 0.5)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-24.0, -125.0, 0.0)
	sun.light_color = Color(1.0, 0.86, 0.68)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 70.0
	add_child(sun)
