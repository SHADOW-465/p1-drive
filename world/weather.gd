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
var _rain_mat: ShaderMaterial
var _last_rain_alpha: float = -1.0


func _ready() -> void:
	if not day_night_path.is_empty():
		_day_night = get_node_or_null(day_night_path) as DayNight
	_particles = CPUParticles3D.new()
	_particles.name = "RainParticles"
	_particles.amount = clampi(Settings.rain_particle_count(), 600, 1000)
	_last_count = _particles.amount
	_particles.lifetime = 0.72
	_particles.local_coords = true
	_particles.top_level = true
	_particles.particle_flag_align_y = true
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.emitting = false
	_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_particles.emission_box_extents = Vector3(12.5, 2.5, 12.5)
	_particles.direction = Vector3(0.05, -1.0, 0.03).normalized()
	_particles.spread = 3.5
	_particles.initial_velocity_min = 20.0
	_particles.initial_velocity_max = 25.0
	_particles.gravity = Vector3.ZERO
	_particles.scale_amount_min = 0.75
	_particles.scale_amount_max = 1.25
	var qm := QuadMesh.new()
	qm.size = Vector2(0.008, 0.60)
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, skip_vertex_transform;
global uniform float night_factor;
uniform vec4 tint : source_color = vec4(0.74, 0.83, 0.93, 0.18);
uniform float alpha_scale = 1.0;
varying float v_dist;
void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	float sy = max(length(MODEL_MATRIX[1].xyz), 0.01);
	vec3 axis = MODEL_MATRIX[1].xyz / sy;
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - pos;
	v_dist = length(to_cam);
	vec3 right = cross(axis, to_cam);
	float rlen = length(right);
	right = (rlen > 1e-4) ? (right / rlen) : normalize(MODEL_MATRIX[0].xyz);
	vec3 world_v = pos + right * VERTEX.x + axis * (VERTEX.y * sy);
	VERTEX = (VIEW_MATRIX * vec4(world_v, 1.0)).xyz;
}
void fragment() {
	float fade_y = smoothstep(0.0, 0.28, UV.y) * smoothstep(1.0, 0.72, UV.y);
	float fade_x = smoothstep(0.0, 0.35, 1.0 - abs(UV.x * 2.0 - 1.0));
	float near_fade = smoothstep(1.8, 4.5, v_dist);
	float far_fade = 1.0 - smoothstep(16.0, 24.0, v_dist);
	ALBEDO = tint.rgb * mix(1.0, 0.58, night_factor);
	ALPHA = tint.a * alpha_scale * fade_y * fade_x * near_fade * far_fade;
}
"""
	_rain_mat = ShaderMaterial.new()
	_rain_mat.shader = sh
	qm.material = _rain_mat
	_particles.mesh = qm
	add_child(_particles)
	Settings.settings_changed.connect(_on_settings_changed)


func _on_settings_changed() -> void:
	var target_cnt: int = clampi(Settings.rain_particle_count(), 600, 1000)
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
		var parent_node: Node = get_parent()
		var car: Car = parent_node.get_node_or_null(^"P1") as Car if parent_node != null else null
		var cam_fwd_h := Vector3(-cam.global_basis.z.x, 0.0, -cam.global_basis.z.z)
		cam_fwd_h = cam_fwd_h.normalized() if cam_fwd_h.length_squared() > 1e-4 else Vector3.FORWARD
		var fwd_h: Vector3 = cam_fwd_h
		var fwd_speed: float = 0.0
		if car != null:
			var car_fwd := Vector3(-car.global_basis.z.x, 0.0, -car.global_basis.z.z)
			if car_fwd.length_squared() > 1e-4:
				fwd_h = car_fwd.normalized()
			fwd_speed = maxf(car.speed, 0.0)
		var back_spd: float = clampf(fwd_speed * 0.50, 0.0, 28.0)
		var rel_vel: Vector3 = Vector3(1.2, -22.0, 0.8) - fwd_h * back_spd
		var spd: float = rel_vel.length()
		_particles.direction = rel_vel / spd
		_particles.initial_velocity_min = spd * 0.90
		_particles.initial_velocity_max = spd * 1.12
		var lead: float = clampf(back_spd * 0.28, 0.0, 7.5)
		_particles.global_transform = Transform3D(Basis.IDENTITY, cam.global_position + Vector3(0.0, 9.5, 0.0) + cam_fwd_h * 3.5 + fwd_h * lead)
		var a_sc: float = clampf(rain, 0.0, 1.0)
		if absf(a_sc - _last_rain_alpha) > 0.005 or (a_sc == 0.0 and _last_rain_alpha > 0.0) or (a_sc == 1.0 and _last_rain_alpha < 1.0):
			_last_rain_alpha = a_sc
			_rain_mat.set_shader_parameter("alpha_scale", a_sc)
		_particles.emitting = rain > 0.08
	else:
		_particles.emitting = false
