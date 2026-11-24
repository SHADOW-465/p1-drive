shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;
// Ground light pools under streetlights & canopies (T18 / PLAN §1).
global uniform float night_factor;
global uniform float wetness;

varying vec3 v_local_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	v_local_pos = VERTEX;
}

void fragment() {
	if (night_factor < 0.005) {
		discard;
	}
	vec2 p = UV * 2.0 - 1.0;
	vec2 pe = vec2(p.x * 1.15, p.y);
	float r2 = dot(pe, pe);
	float r = sqrt(r2);
	float edge = smoothstep(1.0, 0.18, r);
	float pool = (1.0 / pow(1.0 + r2 * 4.5, 1.35)) * edge * edge;

	// Subtle asphalt texture breakup so pools read as illumination on textured road, not flat decals
	float grain = vnoise(v_local_pos.xz * 0.85) * 0.6 + vnoise(v_local_pos.xz * 2.4) * 0.4;
	float tex_mod = mix(0.80, 1.16, grain);

	// Warm sodium core shifting subtly deeper amber toward outer rim
	vec3 warm_core = mix(COLOR.rgb, vec3(1.0, 0.64, 0.34), 0.35);
	vec3 rim_col = warm_core * vec3(1.0, 0.84, 0.62);
	vec3 col = mix(rim_col, warm_core, clamp(pool * 1.3, 0.0, 1.0));
	vec3 light_out = col * pool * tex_mod * 0.22;

	// Wet-road sheen and sharper specular reflections inside puddles
	if (wetness > 0.01) {
		float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		float fresnel = pow(1.0 - ndv, 3.0);
		float p_n = vnoise(v_local_pos.xz * 0.13) * 0.62 + vnoise(v_local_pos.xz * 0.38 + vec2(17.3, 9.1)) * 0.38;
		float puddle = smoothstep(0.64 - 0.24 * wetness, 0.74 - 0.20 * wetness, p_n);
		puddle *= smoothstep(0.10, 0.40, wetness);
		float shimmer = mix(0.88, 1.12, vnoise(v_local_pos.xz * 3.8 + vec2(TIME * 0.6, -TIME * 0.4)));
		float sheen = (1.0 / pow(1.0 + r2 * 6.5, 1.45)) * edge * edge * (0.30 + 0.70 * fresnel);
		float pud_refl = (1.0 / pow(1.0 + r2 * 13.0, 1.65)) * smoothstep(0.85, 0.08, r) * puddle * (0.45 + 0.85 * fresnel) * shimmer;
		light_out += warm_core * (sheen * 0.12 + pud_refl * 0.42) * wetness;
	}

	ALBEDO = light_out * night_factor;
	ALPHA = 1.0;
}
