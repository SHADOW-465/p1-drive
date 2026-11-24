shader_type spatial;
// Realistic far-LOD building shader: cheap sky-Fresnel glass reflection, regional rooftop tint, night window glow.

global uniform float night_factor;
global uniform float wetness;

uniform sampler2D atlas_diff : source_color, filter_linear_mipmap, repeat_disable;

varying vec2 m_uv;
varying float v_roof;
varying float b_height;
varying float v_lit_bias;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	m_uv = UV;
	v_roof = step(0.85, NORMAL.y);
	b_height = UV2.x;
	v_lit_bias = UV2.y;
}

void fragment() {
	float raw_a = COLOR.a;
	int style = clamp(int(floor(raw_a * 4.0)), 0, 3);
	float seed = fract(raw_a * 4.0) * 97.0 + raw_a * 19.0;
	vec2 bay = (style == 0) ? vec2(2.4, 3.6) : ((style == 1) ? vec2(2.9, 3.6) : ((style == 2) ? vec2(2.6, 3.4) : vec2(2.8, 3.5)));
	vec2 cell = floor(m_uv / bay);
	vec2 f = fract(m_uv / bay);
	float plinth = step(m_uv.y, -0.05) * (1.0 - v_roof);
	float top_dist = b_height - m_uv.y;
	float top_parapet = step(top_dist, 1.25);
	float wx0 = (style == 0) ? 0.08 : 0.18;
	float win = step(wx0, f.x) * step(f.x, 1.0 - wx0) * step(0.20, f.y) * step(f.y, 0.86) * (1.0 - v_roof) * (1.0 - plinth) * (1.0 - top_parapet);
	float rnd = hash21(cell + vec2(seed, seed * 0.53));
	float grain = textureLod(atlas_diff, vec2(0.75, 0.25) + fract(m_uv / 16.0) * 0.1, 3.0).r;

	// Subtle per-building & per-floor facade variation + clear architectural roofline
	float b_var = hash21(vec2(seed * 0.23, 5.9));
	float b_warm = hash21(vec2(seed * 0.41, 9.7));
	float floor_tone = mix(0.95, 1.05, hash21(vec2(cell.y, seed * 0.17)));
	vec3 b_tint = mix(vec3(0.95, 0.97, 1.02), vec3(1.04, 1.00, 0.95), b_warm) * mix(0.86, 1.12, b_var);

	vec3 wall = COLOR.rgb * 1.42 * b_tint * floor_tone * mix(0.86, 1.10, grain);
	float groove = smoothstep(1.52, 1.18, top_dist) * smoothstep(0.94, 1.14, top_dist) * (1.0 - v_roof) * (1.0 - plinth);
	float frieze = smoothstep(1.22, 0.96, top_dist) * (1.0 - v_roof) * (1.0 - plinth);
	float coping = smoothstep(0.38, 0.18, top_dist) * (1.0 - v_roof) * (1.0 - plinth);
	wall *= mix(1.0, 0.72, groove);
	wall = mix(wall, wall * 1.14 + vec3(0.025), frieze);
	wall = mix(wall, wall * 1.18 + vec3(0.035), coping * 0.65);
	wall = mix(wall, vec3(0.36, 0.34, 0.32), plinth);

	if (style == 2 && v_roof > 0.5) {
		wall = vec3(0.45, 0.23, 0.14);
	} else if (v_roof > 0.5) {
		wall = vec3(0.28, 0.30, 0.33);
	}

	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 3.0);
	vec3 sky_refl = mix(vec3(0.24, 0.34, 0.46), vec3(0.04, 0.07, 0.12), night_factor);
	sky_refl = mix(sky_refl, vec3(0.22, 0.25, 0.28), wetness * 0.65);
	vec3 glass = mix((style == 0) ? vec3(0.05, 0.10, 0.16) : vec3(0.03, 0.05, 0.08), sky_refl, mix(0.10, 0.44, fresnel));

	// Sparse warm night window lighting matching building.gdshader
	float b_occ = (v_lit_bias > 0.01) ? v_lit_bias : mix(0.24, 0.84, hash21(vec2(seed * 0.37, 13.7)));
	float floor_r = hash21(vec2(cell.y, seed * 0.71 + 3.1));
	float floor_act = mix(0.35, 1.35, step(0.42, floor_r));
	float suite_r = hash21(vec2(floor(cell.x / 3.0), cell.y + seed * 0.29));
	float suite_boost = (style == 0) ? mix(0.65, 1.45, step(0.58, suite_r)) : 1.0;
	float base_rate = (style == 0) ? 0.24 : ((style == 2) ? 0.16 : 0.19);
	float rate = clamp(base_rate * b_occ * 1.45 * floor_act * suite_boost, 0.03, 0.40);
	float lit = step(1.0 - rate, rnd) * night_factor;

	float rnd_col = hash21(cell * 1.31 + vec2(seed * 0.47, 19.3));
	float rnd_bri = hash21(cell * 2.17 + vec2(7.7, seed * 0.63));
	vec3 w_deep = vec3(1.0, 0.52, 0.18);
	vec3 w_gold = vec3(1.0, 0.68, 0.32);
	vec3 w_soft = vec3(1.0, 0.78, 0.48);
	vec3 win_col = mix(w_deep, w_gold, smoothstep(0.0, 0.55, rnd_col));
	win_col = mix(win_col, w_soft, smoothstep(0.55, 1.0, rnd_col));
	if (style == 0) {
		win_col = mix(win_col, vec3(0.92, 0.86, 0.74), step(0.88, rnd_col) * 0.65);
	}
	float bri = mix(0.34, 1.18, rnd_bri * rnd_bri);
	vec3 coping_rim = vec3(0.055, 0.075, 0.12) * (0.45 + 0.55 * fresnel) * coping * night_factor;

	float rough = mix(0.84, 0.10, win);
	rough = mix(rough, 0.24, coping * (1.0 - win));

	ALBEDO = mix(wall, glass, win);
	ROUGHNESS = rough;
	METALLIC = mix(0.02, (style == 0) ? 0.42 : 0.18, win);
	SPECULAR = mix(0.42, 0.78, coping * (1.0 - win));
	EMISSION = win_col * bri * win * lit * 0.90 + coping_rim;
}
