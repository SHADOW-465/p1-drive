shader_type spatial;
// PBR Terrain shader (R2): biome-tinted grass with dual-scale anti-tiling, road-cut/slope dirt,
// triplanar cliff rock with Whiteout normal blending, coastal sand, mountain snow, micro detail normals,
// and rain wetness darkening/sheen. Seamless across 1024 m tiles (every UV divides into 1024).
// UV.x = road cut/embankment dirt mask (bw), UV.y = city biome mask.

global uniform float wetness;

uniform sampler2D tex_grass_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_grass_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_grass_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_dirt_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_dirt_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_dirt_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_rock_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rock_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rock_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_sand_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_sand_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_sand_arm : filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 lpos;
varying vec3 wnrm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Tile-periodic value noise (period divides cleanly across 1024 m tile boundaries)
float vnoise(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec2 a = mod(i, period);
	vec2 b = mod(i + 1.0, period);
	return mix(
		mix(hash(a), hash(vec2(b.x, a.y)), f.x),
		mix(hash(vec2(a.x, b.y)), hash(b), f.x),
		f.y
	);
}

vec3 unpack_nor(vec2 rg, float strength) {
	vec2 xy = (rg * 2.0 - 1.0) * strength;
	float nz = sqrt(max(1.0 - dot(xy, xy), 0.0));
	return vec3(xy, nz);
}

void vertex() {
	lpos = VERTEX;
	wnrm = normalize(NORMAL);
}

void fragment() {
	float dist = length(VERTEX);
	float nor_fade = 1.0 - smoothstep(55.0, 165.0, dist);
	float detail_fade = 1.0 - smoothstep(14.0, 52.0, dist);

	float road_cut = UV.x;
	float city = UV.y;
	float forest = UV2.x;
	float desert = COLOR.a;
	float nat = 1.0 - city;
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0); // 0 flat .. 1 vertical

	// Tile-periodic macro variation for natural splat breakup (1024 / 16 = 64, 1024 / 64 = 16)
	float macro_a = vnoise(lpos.xz / 16.0, 64.0);
	float macro_b = vnoise(lpos.xz / 64.0, 16.0);

	// Splat weights: rock on steep slopes, sand near sea level or desert plain, snow on high peaks, subtle dirt only tight to road cuts
	float w_rock = smoothstep(0.12, 0.27, slope + (macro_a - 0.5) * 0.08) * nat;
	float w_sand = max(smoothstep(5.0, 1.2, lpos.y), desert * (0.72 + 0.24 * macro_b)) * nat * (1.0 - w_rock * 0.68);
	float w_snow = smoothstep(300.0, 365.0, lpos.y + (macro_b - 0.5) * 35.0) * smoothstep(0.58, 0.82, wnrm.y);
	float road_edge_dirt = smoothstep(0.90, 0.995, road_cut) * 0.42;
	float slope_dirt = smoothstep(0.09, 0.21, slope) * 0.28 * nat * (1.0 - forest * 0.65);
	float patch_dirt = max(smoothstep(0.74, 0.92, macro_a) * 0.14 * (1.0 - forest * 0.88), desert * 0.28) * nat;
	float w_dirt = clamp(max(road_edge_dirt, slope_dirt) + patch_dirt, 0.0, 1.0);
	w_dirt *= (1.0 - w_rock) * (1.0 - w_sand) * (1.0 - w_snow);
	float w_grass = max(1.0 - w_rock - w_sand - w_snow - w_dirt, 0.0) * (1.0 - desert * 0.94);

	// Re-normalize weights cleanly
	float w_sum = max(w_grass + w_dirt + w_rock + w_sand + w_snow, 1e-5);
	w_grass /= w_sum;
	w_dirt /= w_sum;
	w_rock /= w_sum;
	w_sand /= w_sum;
	w_snow /= w_sum;

	vec3 col = vec3(0.0);
	float rough = 0.0;
	float ao = 0.0;
	vec3 world_n = wnrm;

	// Orthonormal tangent frame on the terrain surface for horizontal layers
	vec3 t_hor = normalize(vec3(wnrm.y, -wnrm.x, 0.0) + vec3(0.0001, 0.0, 0.0));
	vec3 b_hor = normalize(cross(wnrm, t_hor));

	// 1. Grass (dual-scale rotated anti-tiling, modulated gently by biome vertex colour)
	if (w_grass > 0.01) {
		vec2 uv_g1 = lpos.xz / 4.0;
		vec2 uv_g2 = vec2(-lpos.z, lpos.x) / 8.0 + vec2(0.37, 0.71);
		float blend_g = macro_a * 0.65 + macro_b * 0.35;
		vec3 g_diff = mix(texture(tex_grass_diff, uv_g1).rgb, texture(tex_grass_diff, uv_g2).rgb, blend_g * 0.55);
		vec3 g_arm = texture(tex_grass_arm, uv_g1).rgb;
		// Preserve biome tint (countryside natural green, forest deep redwood moss, mountain alpine, city urban)
		vec3 grass_tint = mix(vec3(0.46, 0.68, 0.30), clamp(COLOR.rgb * 2.8, vec3(0.18, 0.38, 0.12), vec3(0.85, 0.96, 0.62)), 0.55);
		vec3 forest_col = vec3(g_diff.g * 0.72, g_diff.g * 1.15, g_diff.g * 0.58) * vec3(0.18, 0.36, 0.13);
		g_diff = mix(g_diff * grass_tint, forest_col, clamp(forest * 1.45, 0.0, 1.0));
		g_diff = mix(g_diff, g_diff * vec3(0.55, 0.58, 0.54), city * 0.65);
		g_diff *= mix(0.84, 1.16, macro_b);
		col += g_diff * w_grass;
		ao += mix(0.65, 1.0, g_arm.r) * w_grass;
		rough += clamp(g_arm.g, 0.78, 0.96) * w_grass;
		if (nor_fade > 0.01) {
			vec3 gn1 = unpack_nor(texture(tex_grass_nor, uv_g1).xy, 0.85 * nor_fade);
			vec3 gn2 = unpack_nor(texture(tex_grass_nor, uv_g2).xy, 0.65 * nor_fade);
			vec3 gn = normalize(mix(gn1, gn2, blend_g * 0.45));
			world_n += (t_hor * gn.x + b_hor * gn.y + wnrm * (gn.z - 1.0)) * w_grass;
		}
	}

	// 2. Dirt (road cuts, embankments, transition slopes)
	if (w_dirt > 0.01) {
		vec2 uv_d = lpos.xz / 4.0;
		vec3 d_diff = texture(tex_dirt_diff, uv_d).rgb * mix(0.85, 1.14, macro_a);
		vec3 d_arm = texture(tex_dirt_arm, uv_d).rgb;
		col += d_diff * w_dirt;
		ao += mix(0.62, 1.0, d_arm.r) * w_dirt;
		rough += clamp(d_arm.g, 0.78, 0.96) * w_dirt;
		if (nor_fade > 0.01) {
			vec3 dn = unpack_nor(texture(tex_dirt_nor, uv_d).xy, 0.95 * nor_fade);
			world_n += (t_hor * dn.x + b_hor * dn.y + wnrm * (dn.z - 1.0)) * w_dirt;
		}
	}

	// 3. Rock (dual-scale anti-tiled triplanar projection on slopes + cool alpine granite grading)
	if (w_rock > 0.01) {
		vec3 tri_w = pow(abs(wnrm), vec3(4.0));
		tri_w /= max(tri_w.x + tri_w.y + tri_w.z, 1e-5);
		vec2 uv_xy = lpos.xy / 16.0;
		vec2 uv_zy = lpos.zy / 16.0;
		vec2 uv_xz = lpos.xz / 16.0;
		vec3 r_near = texture(tex_rock_diff, uv_zy).rgb * tri_w.x
			+ texture(tex_rock_diff, uv_xz).rgb * tri_w.y
			+ texture(tex_rock_diff, uv_xy).rgb * tri_w.z;
		vec3 r_far = texture(tex_rock_diff, uv_zy * 0.27 + vec2(0.31, 0.17)).rgb * tri_w.x
			+ texture(tex_rock_diff, uv_xz * 0.27 + vec2(0.19, 0.43)).rgb * tri_w.y
			+ texture(tex_rock_diff, uv_xy * 0.27 + vec2(0.47, 0.11)).rgb * tri_w.z;
		vec3 r_diff = mix(r_near, r_far, 0.48);
		// Desaturate warm clay cast into realistic cool alpine granite / Mediterranean limestone
		float r_lum = dot(r_diff, vec3(0.299, 0.587, 0.114));
		vec3 cool_rock = mix(vec3(r_lum) * vec3(0.84, 0.86, 0.88), r_diff, 0.35);
		vec3 desert_rock = r_diff * vec3(1.04, 0.86, 0.68);
		r_diff = mix(cool_rock, desert_rock, desert);
		vec3 r_arm = texture(tex_rock_arm, uv_zy).rgb * tri_w.x
			+ texture(tex_rock_arm, uv_xz).rgb * tri_w.y
			+ texture(tex_rock_arm, uv_xy).rgb * tri_w.z;
		col += r_diff * mix(0.78, 1.18, macro_b) * w_rock;
		ao += mix(0.56, 1.0, r_arm.r) * w_rock;
		rough += clamp(r_arm.g, 0.72, 0.95) * w_rock;
		if (nor_fade > 0.01) {
			float rs = 0.95 * nor_fade;
			vec3 t_xy = unpack_nor(texture(tex_rock_nor, uv_xy).xy, rs);
			vec3 t_zy = unpack_nor(texture(tex_rock_nor, uv_zy).xy, rs);
			vec3 t_xz = unpack_nor(texture(tex_rock_nor, uv_xz).xy, rs);
			vec3 n_xy = vec3(t_xy.x + wnrm.x, t_xy.y + wnrm.y, abs(t_xy.z) * wnrm.z);
			vec3 n_zy = vec3(abs(t_zy.z) * wnrm.x, t_zy.y + wnrm.y, t_zy.x + wnrm.z);
			vec3 n_xz = vec3(t_xz.x + wnrm.x, abs(t_xz.z) * wnrm.y, t_xz.y + wnrm.z);
			vec3 rock_wn = normalize(n_zy * tri_w.x + n_xz * tri_w.y + n_xy * tri_w.z);
			world_n += (rock_wn - wnrm) * w_rock;
		}
	}

	// 4. Coastal / desert sand (warm golden dunes + wind-rippled micro normals)
	if (w_sand > 0.01) {
		vec2 uv_s = lpos.xz / 4.0;
		vec3 s_diff = texture(tex_sand_diff, uv_s).rgb;
		vec3 s_arm = texture(tex_sand_arm, uv_s).rgb;
		vec3 desert_tint = vec3(0.94, 0.71, 0.48) * mix(0.86, 1.14, macro_a);
		s_diff *= mix(vec3(1.04, 1.00, 0.92), desert_tint, desert);
		col += s_diff * w_sand;
		ao += mix(0.76, 1.0, s_arm.r) * w_sand;
		rough += clamp(s_arm.g, 0.74, 0.92) * w_sand;
		if (nor_fade > 0.01) {
			vec3 sn = unpack_nor(texture(tex_sand_nor, uv_s).xy, 0.80 * nor_fade);
			// Crisp wind-blown dune ripples across desert sand
			float rip = cos((lpos.x * 0.7 + lpos.z * 0.45) * 4.5 + macro_a * 4.0) * 0.14 * desert * nor_fade;
			world_n += (t_hor * (sn.x + rip) + b_hor * (sn.y + rip * 0.5) + wnrm * (sn.z - 1.0)) * w_sand;
		}
	}

	// 5. High-altitude alpine snow (crisp sunlit powder with subtle wind-drift normal & micro sparkle)
	if (w_snow > 0.01) {
		float drift = vnoise(lpos.xz / 6.0, 128.0);
		vec3 snow_col = mix(vec3(0.80, 0.86, 0.94), vec3(0.95, 0.97, 1.0), drift * 0.65 + macro_a * 0.35);
		col += snow_col * w_snow;
		ao += mix(0.88, 1.0, drift) * w_snow;
		rough += mix(0.52, 0.74, drift) * w_snow;
		if (nor_fade > 0.01) {
			vec3 swn = unpack_nor(texture(tex_sand_nor, lpos.xz / 5.0).xy, 0.32 * nor_fade);
			world_n += (t_hor * swn.x + b_hor * swn.y + wnrm * (swn.z - 1.0)) * w_snow;
		}
	}

	// Close-range micro detail normal (1 m tile, seamless across 1024 m)
	if (detail_fade > 0.01) {
		vec3 det = unpack_nor(texture(tex_dirt_nor, lpos.xz).xy, 0.32 * detail_fade * (1.0 - w_snow * 0.7));
		world_n += t_hor * det.x + b_hor * det.y;
	}

	world_n = normalize(world_n);

	// Rain wetness: damp soil/rock darkens and gets glossy sheen
	if (wetness > 0.001) {
		float soil_mask = clamp(w_dirt + w_rock + w_sand, 0.0, 1.0);
		col *= mix(1.0, mix(0.76, 0.56, soil_mask), wetness);
		rough = mix(rough, mix(0.55, 0.34, soil_mask), wetness);
	}

	ALBEDO = col;
	AO = clamp(ao, 0.35, 1.0);
	ROUGHNESS = clamp(rough, 0.15, 0.98);
	SPECULAR = mix(0.22, 0.45, wetness);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
}
