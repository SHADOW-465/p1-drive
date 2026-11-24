shader_type spatial;
// PBR Rock shader (R3): Poly Haven rock diff/nor/arm, per-instance tint, rain wetness,
// and screen-space dither LOD/distance fade.

global uniform float wetness;

uniform sampler2D tex_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform float fade_in_start = -10.0;
uniform float fade_in_end = -5.0;
uniform float fade_out_start = 420.0;
uniform float fade_out_end = 460.0;

varying float cam_dist;

float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void vertex() {
	cam_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
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

	vec3 diff = texture(tex_diff, UV).rgb * COLOR.rgb;
	vec3 arm = texture(tex_arm, UV).rgb;
	vec3 nor = texture(tex_nor, UV).rgb;

	diff *= mix(1.0, 0.65, wetness);
	float ao = mix(0.58, 1.0, arm.r);
	float rough = clamp(arm.g, 0.35, 0.98);
	rough = mix(rough, max(rough * 0.42, 0.14), wetness);

	ALBEDO = diff * ao;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	SPECULAR = mix(0.35, 0.72, wetness);
	if (cam_dist < 140.0) {
		NORMAL_MAP = nor;
		NORMAL_MAP_DEPTH = 1.15 * (1.0 - smoothstep(60.0, 140.0, cam_dist));
	}
}
