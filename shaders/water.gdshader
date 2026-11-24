shader_type spatial;
// Realistic PBR water shader: 3-octave swell + capillary ripple normals, depth-based coastal turquoise to deep ocean
// absorption, animated shoreline surf foam, sky Fresnel reflection, and crisp sun specular glints.
// UV = world-space XZ in metres; COLOR.r = depth factor (0 shallow .. 1 deep), COLOR.g = river flow mask.

global uniform float night_factor;
global uniform float wetness;

varying vec3 v_world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
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

float wave_h(vec2 p, float flow, float detail_w) {
	// Broad ocean/bay swell + mid cross-waves + fine capillary ripples
	vec2 p1 = p * 0.12 + vec2(TIME * 0.14, -TIME * (0.10 + 0.30 * flow));
	vec2 p2 = vec2(p.x * 0.29 - p.y * 0.18, p.x * 0.18 + p.y * 0.29) + vec2(-TIME * 0.22, -TIME * (0.16 + 0.50 * flow));
	float h = vnoise(p1) * 0.52 + vnoise(p2) * 0.32;
	if (detail_w > 0.02) {
		vec2 p3 = p * 0.85 + vec2(TIME * 0.42, TIME * 0.28);
		h += vnoise(p3) * 0.16 * detail_w;
	}
	return h;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float depth_t = clamp(COLOR.r, 0.0, 1.0);
	float flow = COLOR.g;
	float dist = length(VERTEX);
	float nor_fade = 1.0 - smoothstep(80.0, 520.0, dist);
	float detail_w = 1.0 - smoothstep(25.0, 140.0, dist);

	// Analytical finite-difference multi-octave wave normal in world XZ
	vec2 wp = UV;
	float eps = mix(0.28, 0.55, 1.0 - detail_w);
	float h0 = wave_h(wp, flow, detail_w);
	float hx = wave_h(wp + vec2(eps, 0.0), flow, detail_w);
	float hz = wave_h(wp + vec2(0.0, eps), flow, detail_w);
	float amp = mix(0.55, 0.78, wetness);
	vec3 wn = normalize(vec3((h0 - hx) * amp * nor_fade, 1.0, (h0 - hz) * amp * nor_fade));

	vec3 view_dir = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float ndv = clamp(dot(wn, view_dir), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 4.2);

	// Rich Mediterranean / tropical shallow turquoise transitioning to deep navy sea
	vec3 shallow_col = mix(vec3(0.08, 0.34, 0.36), vec3(0.06, 0.22, 0.20), flow);
	vec3 mid_col = mix(vec3(0.02, 0.16, 0.26), vec3(0.03, 0.14, 0.18), flow);
	vec3 deep_col = mix(vec3(0.012, 0.055, 0.125), vec3(0.02, 0.09, 0.13), flow);
	vec3 water_body = mix(shallow_col, mid_col, smoothstep(0.04, 0.38, depth_t));
	water_body = mix(water_body, deep_col, smoothstep(0.32, 0.90, depth_t));

	vec3 sky_col = mix(vec3(0.42, 0.58, 0.78), vec3(0.04, 0.07, 0.13), night_factor);
	sky_col = mix(sky_col, vec3(0.30, 0.34, 0.39), wetness * 0.60);

	// Animated shoreline foam along shallow edges
	float shore_band = 1.0 - smoothstep(0.01, 0.15, depth_t);
	float foam_wave = smoothstep(0.42, 0.74, h0 + shore_band * 0.38 + sin(TIME * 1.4 - depth_t * 28.0) * 0.12);
	float foam = shore_band * foam_wave * (1.0 - smoothstep(180.0, 520.0, dist));
	vec3 foam_col = mix(vec3(0.84, 0.90, 0.94), vec3(0.22, 0.28, 0.36), night_factor);

	vec3 col = mix(water_body, sky_col, clamp(fresnel * 0.82, 0.0, 0.86));
	col = mix(col, foam_col, foam * 0.78);

	ALBEDO = col;
	ROUGHNESS = mix(mix(0.045, 0.16, wetness * 0.55), 0.65, foam);
	SPECULAR = mix(0.95, 0.35, foam);
	METALLIC = mix(0.10, 0.0, foam);
	ALPHA = clamp(mix(0.58, 0.96, smoothstep(0.01, 0.30, depth_t) + fresnel * 0.38) + foam * 0.35, 0.0, 0.98);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
}
