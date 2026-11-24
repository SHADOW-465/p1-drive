shader_type spatial;
// Realistic City building shader: merged per-block meshes, 2-texture atlas (diffuse sRGB; normal.xy + roughness + AO).
// Features: sky-Fresnel reflective glass, recessed window lintel AO & sill highlights, floor spandrel bands,
// interior curtain/depth shading, architectural mullions, regional terracotta/membrane roofs, and rain wetness.

global uniform float night_factor;
global uniform float wetness;

uniform sampler2D atlas_diff : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D atlas_nra : filter_linear_mipmap, repeat_disable;
uniform float normals_on = 1.0;

varying vec2 m_uv;
varying float b_height;
varying float cam_dist;
varying float v_roof;
varying float v_lit_bias;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x),
		f.y
	);
}

void vertex() {
	m_uv = UV;
	v_roof = step(0.85, NORMAL.y);
	b_height = UV2.x;
	v_lit_bias = UV2.y;
	cam_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

// Sample tile `t` of the 2x2 atlas with a wrapped coordinate; gradients come from unwrapped uv so mips stay seamless.
vec4 atlas(sampler2D s, int t, vec2 uv) {
	vec2 org = vec2(float(t & 1), float(t >> 1)) * 0.5;
	return textureGrad(s, org + (fract(uv) * 0.96 + 0.02) * 0.5, dFdx(uv) * 0.48, dFdy(uv) * 0.48);
}

void fragment() {
	float is_roof = v_roof;
	float nor_fade = normals_on * (1.0 - smoothstep(35.0, 110.0, cam_dist));

	float raw_a = COLOR.a;
	int style = clamp(int(floor(raw_a * 4.0)), 0, 3);
	float seed = fract(raw_a * 4.0) * 97.0 + raw_a * 19.0;

	// style 0: sleek glass curtain-wall tower (Dubai/Tokyo); 1: architectural concrete/limestone;
	// style 2: warm Riviera plaster/stucco (Monaco); 3: modern urban commercial/brick (Tokyo/Shibuya)
	int tile = (style == 0) ? 0 : ((style == 1) ? 1 : ((style == 2) ? 0 : 2));
	vec2 tex_uv = (m_uv / 4.4) * ((style == 0) ? 0.75 : 1.0);
	vec3 wall_diff = atlas(atlas_diff, tile, tex_uv).rgb;
	if (style == 0) {
		wall_diff = mix(wall_diff, vec3(0.42, 0.46, 0.52), 0.55);
	} else if (style == 2) {
		// Warm Riviera limestone & ochre stucco
		wall_diff = mix(wall_diff, vec3(0.86, 0.79, 0.68), 0.48);
	}
	wall_diff *= COLOR.rgb * 1.42;

	// Subtle per-building & architectural facade variation
	float b_var = hash21(vec2(seed * 0.23, 5.9));
	float b_warm = hash21(vec2(seed * 0.41, 9.7));
	float macro_var = vnoise(m_uv * 0.09 + vec2(seed, seed * 0.37));
	wall_diff *= mix(vec3(0.95, 0.97, 1.02), vec3(1.04, 1.00, 0.95), b_warm) * mix(0.86, 1.12, b_var) * mix(0.91, 1.06, macro_var);

	// Street-level ambient occlusion, under-cornice shadow, parapet frieze, and top coping cap
	float top_dist = b_height - m_uv.y;
	float base_ao = mix(0.70, 1.0, smoothstep(0.0, 4.5, m_uv.y));
	float groove = smoothstep(1.52, 1.18, top_dist) * smoothstep(0.94, 1.14, top_dist) * (1.0 - is_roof);
	float frieze = smoothstep(1.22, 0.96, top_dist) * (1.0 - is_roof);
	float coping = smoothstep(0.36, 0.16, top_dist) * (1.0 - is_roof);
	wall_diff *= base_ao * mix(1.0, 0.72, groove);
	wall_diff = mix(wall_diff, wall_diff * 1.14 + vec3(0.025), frieze);
	wall_diff = mix(wall_diff, wall_diff * 1.18 + vec3(0.035), coping * 0.65);

	// Stone plinth below floor level on sloped sites
	float plinth = step(m_uv.y, -0.05) * (1.0 - v_roof);
	if (plinth > 0.5) {
		wall_diff = atlas(atlas_diff, 1, m_uv / 3.0).rgb * vec3(0.48, 0.46, 0.43);
		coping = 0.0;
	}

	vec2 bay = (style == 0) ? vec2(2.4, 3.6) : ((style == 1) ? vec2(2.9, 3.6) : ((style == 2) ? vec2(2.6, 3.4) : vec2(2.8, 3.5)));
	vec2 cell = floor(m_uv / bay);
	vec2 f = fract(m_uv / bay);

	// Subtle per-floor and per-bay panel tone variation + horizontal spandrel ledge shading
	float floor_tone = mix(0.95, 1.05, hash21(vec2(cell.y, seed * 0.17)));
	float bay_tone = mix(0.96, 1.04, hash21(cell + vec2(3.3, seed * 0.29)));
	float slab_shadow = mix(0.84, 1.0, smoothstep(0.0, 0.10, f.y));
	wall_diff *= mix(1.0, slab_shadow * floor_tone * bay_tone, (1.0 - is_roof) * (1.0 - plinth) * (1.0 - frieze));

	float wx0 = (style == 0) ? 0.05 : ((style == 2) ? 0.22 : 0.16);
	float wx1 = 1.0 - wx0;
	float wy0 = (style == 0) ? 0.12 : ((style == 2) ? 0.22 : 0.24);
	float wy1 = (style == 0) ? 0.92 : 0.84;

	float win_x = step(wx0, f.x) * step(f.x, wx1);
	float win_y = step(wy0, f.y) * step(f.y, wy1);
	float is_ground = step(m_uv.y, 4.2);
	float top_parapet = step(top_dist, 1.25);
	float is_win = win_x * win_y * (1.0 - is_roof) * (1.0 - top_parapet) * (1.0 - plinth);

	// Ground-floor glass storefronts with structural piers
	float shop_x = step(0.10, fract(m_uv.x / 4.8)) * step(fract(m_uv.x / 4.8), 0.90);
	float shop_y = step(0.32, m_uv.y) * step(m_uv.y, 3.65);
	float is_shop = shop_x * shop_y * is_ground * (1.0 - is_roof) * (1.0 - plinth);
	if (is_ground > 0.5) {
		is_win = is_shop;
	}

	// Window frame, sill, and subtle mullion cross-bar
	float frame_x = step(wx0 - 0.045, f.x) * step(f.x, wx1 + 0.045);
	float frame_y = step(wy0 - 0.045, f.y) * step(f.y, wy1 + 0.045);
	float mullion = (style != 0) ? step(abs(f.x - 0.5), 0.022) * is_win : step(abs(f.y - 0.52), 0.018) * is_win;
	float is_frame = clamp(max(0.0, frame_x * frame_y - is_win) + mullion, 0.0, 1.0) * (1.0 - is_roof) * (1.0 - is_ground) * (1.0 - top_parapet) * (1.0 - plinth);
	is_win *= (1.0 - mullion);

	// Window sill highlight just under wy0
	float is_sill = step(wx0 - 0.05, f.x) * step(f.x, wx1 + 0.05) * step(wy0 - 0.06, f.y) * step(f.y, wy0) * (1.0 - is_roof) * (1.0 - is_ground) * (1.0 - top_parapet) * (1.0 - plinth);

	float rnd = hash21(cell + vec2(seed, seed * 0.53));
	float room_tone = 0.48 + 0.52 * hash21(cell * 1.7 + vec2(seed * 0.31, 7.1));
	float curtain_h = mix(0.25, 0.85, fract(rnd * 5.7));
	float blinds = mix(0.72, 1.0, step(curtain_h, f.y));

	// Recessed window interior depth gradient (darker at top under lintel, warmer floor bounce below)
	float win_v = clamp((f.y - wy0) / max(wy1 - wy0, 0.01), 0.0, 1.0);
	float lintel_ao = mix(1.0, 0.52, smoothstep(0.72, 1.0, win_v));

	// Sky-Fresnel architectural tinted glass reflection (subtle dark sky sheen, never blown-out white)
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 3.0);
	vec3 sky_day = mix(vec3(0.20, 0.30, 0.42), vec3(0.36, 0.46, 0.58), clamp(win_v * 0.5 + 0.2, 0.0, 1.0));
	vec3 sky_refl = mix(sky_day, vec3(0.05, 0.08, 0.14), night_factor);
	sky_refl = mix(sky_refl, vec3(0.22, 0.25, 0.28), wetness * 0.65);

	vec3 glass_tint = (style == 0) ? vec3(0.05, 0.10, 0.16) : vec3(0.03, 0.05, 0.07);
	vec3 interior = glass_tint * mix(0.70, 1.20, room_tone) * blinds * lintel_ao;
	float refl_w = (style == 0) ? mix(0.16, 0.54, fresnel) : mix(0.08, 0.36, fresnel);
	vec3 glass_day = mix(interior, sky_refl, refl_w);

	float lit_bias = (v_lit_bias > 0.01) ? v_lit_bias : mix(0.24, 0.84, hash21(vec2(seed * 0.37, 13.7)));
	float floor_r = hash21(vec2(cell.y, seed * 0.71 + 3.1));
	float floor_act = mix(0.35, 1.35, step(0.42, floor_r));
	float suite_r = hash21(vec2(floor(cell.x / 3.0), cell.y + seed * 0.29));
	float suite_boost = (style == 0) ? mix(0.65, 1.45, step(0.58, suite_r)) : 1.0;
	float base_rate = (style == 0) ? 0.24 : ((style == 2) ? 0.16 : 0.19);
	float rate = clamp(base_rate * lit_bias * 1.45 * floor_act * suite_boost, 0.03, 0.40);
	if (is_shop > 0.5) {
		rate = clamp(0.32 * mix(0.65, 1.25, lit_bias), 0.14, 0.44);
	}
	float lit = step(1.0 - rate, rnd) * night_factor;

	float rnd_col = hash21(cell * 1.31 + vec2(seed * 0.47, 19.3));
	float rnd_bri = hash21(cell * 2.17 + vec2(7.7, seed * 0.63));
	vec3 w_deep = vec3(1.0, 0.52, 0.18);
	vec3 w_gold = vec3(1.0, 0.68, 0.32);
	vec3 w_soft = vec3(1.0, 0.78, 0.48);
	vec3 win_glow = mix(w_deep, w_gold, smoothstep(0.0, 0.55, rnd_col));
	win_glow = mix(win_glow, w_soft, smoothstep(0.55, 1.0, rnd_col));
	if (style == 0 && is_shop < 0.5) {
		win_glow = mix(win_glow, vec3(0.92, 0.86, 0.74), step(0.88, rnd_col) * 0.65);
	}
	if (is_shop > 0.5) {
		win_glow = mix(w_gold, w_soft, fract(rnd_col * 3.7));
	}
	float depth_v = mix(1.08, 0.48, smoothstep(0.55, 1.0, win_v));
	float jamb_x = clamp((f.x - wx0) / max(wx1 - wx0, 0.01), 0.0, 1.0);
	float jamb_vig = mix(0.82, 1.0, sin(jamb_x * 3.14159));
	win_glow *= mix(0.34, 1.18, rnd_bri * rnd_bri) * mix(0.64, 1.0, blinds) * depth_v * jamb_vig;

	vec3 frame_col = (style == 0) ? vec3(0.20, 0.23, 0.27) : vec3(0.30, 0.29, 0.27);
	vec3 sill_col = wall_diff * 1.18 + vec3(0.05);

	// Architectural rooftops: terracotta clay tiles on Mediterranean style 2, weathered concrete/gravel membrane elsewhere
	vec3 roof_col = vec3(0.30);
	if (is_roof > 0.5) {
		vec3 rtex = atlas(atlas_diff, 1, m_uv / 5.5).rgb;
		if (style == 2) {
			float tile_rib = 0.90 + 0.10 * sin(m_uv.x * 12.0);
			roof_col = mix(vec3(0.54, 0.27, 0.17), vec3(0.66, 0.35, 0.21), fract(seed * 0.13)) * rtex * 1.15 * tile_rib;
		} else {
			float rpatch = 0.88 + 0.22 * hash21(floor(m_uv / 6.0));
			roof_col = rtex * vec3(0.39, 0.40, 0.42) * rpatch;
		}
	}

	// Normal/roughness/AO fetch inside 110 m
	vec4 nra = vec4(0.5, 0.5, 0.8, 0.85);
	if (cam_dist < 110.0) {
		nra = atlas(atlas_nra, (is_roof > 0.5) ? 1 : tile, (is_roof > 0.5) ? m_uv / 5.5 : tex_uv);
	}

	vec3 base = mix(wall_diff, frame_col, is_frame);
	base = mix(base, sill_col, is_sill);
	base = mix(base, glass_day, is_win);
	base = mix(base, roof_col, is_roof);
	base *= mix(1.0, 0.80, wetness * (1.0 - is_win));

	float rough = mix(clamp(nra.b, 0.52, 0.92), 0.28, is_frame);
	rough = mix(rough, 0.24, coping * (1.0 - is_win));
	rough = mix(rough, 0.06, is_win);
	rough = mix(rough, (style == 2) ? 0.78 : 0.86, is_roof);
	rough = mix(rough, max(rough * 0.52, 0.10), wetness);

	float metal = mix(0.02, 0.72, is_frame * float(style == 0));
	metal = mix(metal, (style == 0) ? 0.48 : 0.22, is_win);

	vec3 coping_rim = vec3(0.055, 0.075, 0.12) * (0.45 + 0.55 * fresnel) * coping * night_factor;

	ALBEDO = base * mix(0.72, 1.0, nra.a * (1.0 - is_win) + is_win);
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = mix(mix(0.42, 0.78, coping), 0.95, is_win);
	EMISSION = win_glow * is_win * lit * (is_shop > 0.5 ? 1.25 : 0.95) + coping_rim;

	if (nor_fade > 0.01 && is_win < 0.5) {
		vec2 xy = nra.rg * 2.0 - 1.0;
		NORMAL_MAP = vec3(nra.rg, sqrt(max(1.0 - dot(xy, xy), 0.0)) * 0.5 + 0.5);
		NORMAL_MAP_DEPTH = 0.85 * nor_fade;
	}
}
