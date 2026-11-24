shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;
// Realistic vegetation shader (R3): PBR diff/nor/arm, per-instance tint, gentle wind sway,
// sunlit leaf backlight translucency, rain wetness, and screen-space dither LOD/distance fade.

global uniform float wetness;
global uniform float night_factor;

uniform sampler2D tex_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 albedo_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float uv_scale = 1.0;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float normal_up_bias : hint_range(0.0, 1.0) = 0.0;
uniform float roughness_scale : hint_range(0.1, 2.0) = 1.0;
uniform float backlight_strength : hint_range(0.0, 1.0) = 0.25;
uniform float wind_amp : hint_range(0.0, 0.5) = 0.06;
uniform float wind_height_scale : hint_range(0.1, 20.0) = 1.0;

uniform float fade_in_start = -10.0;
uniform float fade_in_end = -5.0;
uniform float fade_out_start = 420.0;
uniform float fade_out_end = 460.0;

varying vec3 inst_pos;
varying float cam_dist;

float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void vertex() {
	vec3 world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	inst_pos = world_origin;
	float h = clamp(VERTEX.y / wind_height_scale, 0.0, 1.5);
	if (wind_amp > 0.0001 && h > 0.01) {
		float phase = TIME * 1.45 + world_origin.x * 0.23 + world_origin.z * 0.19;
		float sway_x = sin(phase + VERTEX.y * 0.6) * wind_amp * h * h;
		float sway_z = cos(phase * 0.83 + VERTEX.x * 0.5) * wind_amp * 0.65 * h * h;
		VERTEX.x += sway_x;
		VERTEX.z += sway_z;
	}
	if (normal_up_bias > 0.001) {
		NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_up_bias));
	}
	vec3 view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	cam_dist = length(view_pos);
}

void fragment() {
	// Distance fade (dithered screen-door for zero-pop LOD & range fade)
	float vis = 1.0;
	if (fade_in_end > fade_in_start) {
		vis *= smoothstep(fade_in_start, fade_in_end, cam_dist);
	}
	if (fade_out_end > fade_out_start) {
		vis *= 1.0 - smoothstep(fade_out_start, fade_out_end, cam_dist);
	}
	if (vis < 0.999 && vis <= ign(FRAGCOORD.xy)) {
		discard;
	}

	vec2 t_uv = UV * uv_scale;
	vec4 diff = texture(tex_diff, t_uv);
	if (alpha_scissor > 0.001) {
		float alpha_cov = diff.a * (1.0 + clamp(cam_dist / 55.0, 0.0, 0.65));
		if (alpha_cov < alpha_scissor) {
			discard;
		}
	}

	vec3 arm = texture(tex_arm, t_uv).rgb;
	vec3 nor = texture(tex_nor, t_uv).rgb;

	vec3 base_col = diff.rgb * albedo_tint.rgb * COLOR.rgb;
	base_col *= mix(1.0, 0.78, wetness);

	float ao = mix(0.76, 1.0, arm.r);
	float rough = clamp(arm.g * roughness_scale, 0.22, 0.98);
	rough = mix(rough, max(rough * 0.48, 0.16), wetness);

	ALBEDO = base_col * ao;
	ROUGHNESS = rough;
	METALLIC = arm.b * 0.1;
	SPECULAR = mix(0.35, 0.65, wetness);
	if (cam_dist < 140.0) {
		NORMAL_MAP = nor;
		NORMAL_MAP_DEPTH = normal_strength * (1.0 - smoothstep(60.0, 140.0, cam_dist));
	}
	if (backlight_strength > 0.001) {
		BACKLIGHT = base_col * backlight_strength * (1.0 - 0.75 * night_factor);
	}
}
