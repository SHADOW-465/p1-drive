shader_type spatial;
// PBR Road shader (R2): asphalt with normal/roughness/AO, wheel-track wear, painted lane decals,
// concrete/kerb shoulders, sidewalk pavers, gravel verges, and rain wetness + reflective puddles.
// UV.x = signed metres from centreline (or local m on junction pads), UV.y = metres along.
// COLOR.r = type id / 4 (0 highway, 1 country, 2 mountain, 3 city), COLOR.g = half paved width / 16,
// COLOR.b = surface class (0 road, 0.30 shoulder/kerb, 0.55 sidewalk, 1.0 verge),
// COLOR.a = >0.5 draw lane markings (0.0 on junction pads).

global uniform float wetness;
global uniform float night_factor;

uniform sampler2D tex_asphalt_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_asphalt_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_asphalt_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_concrete_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_concrete_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_concrete_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_verge_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_verge_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_verge_arm : filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 v_world_n;

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

float band(float x, float c, float w) {
	float aa = fwidth(x) + 0.001;
	return 1.0 - smoothstep(w - aa, w + aa, abs(x - c));
}

vec3 perturb_normal(vec3 N, vec3 vpos, vec2 uv, vec2 n_xy, float strength) {
	if (strength <= 0.001) {
		return N;
	}
	vec3 dp1 = dFdx(vpos);
	vec3 dp2 = dFdy(vpos);
	vec2 duv1 = dFdx(uv);
	vec2 duv2 = dFdy(uv);
	vec3 dp2perp = cross(dp2, N);
	vec3 dp1perp = cross(N, dp1);
	vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
	vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
	float max_tb = max(dot(T, T), dot(B, B));
	if (max_tb < 1e-10) {
		return N;
	}
	float invmax = inversesqrt(max_tb);
	vec2 xy = (n_xy * 2.0 - 1.0) * strength;
	float nz = sqrt(max(1.0 - dot(xy, xy), 0.0));
	return normalize(T * (invmax * xy.x) + B * (invmax * xy.y) + N * nz);
}

void vertex() {
	v_world_n = NORMAL;
}

void fragment() {
	float dist = length(VERTEX);
	float nor_fade = 1.0 - smoothstep(40.0, 120.0, dist);
	float ax = abs(UV.x);
	float hw = COLOR.g * 16.0;
	int type = int(COLOR.r * 6.0 + 0.5);
	float cls = COLOR.b;
	bool draw_lines = COLOR.a > 0.5;

	vec3 col = vec3(0.1);
	float rough = 0.85;
	float ao = 1.0;
	float spec = 0.4;
	float metal = 0.0;
	float cc = 0.0;
	float cc_rough = 0.30;
	float wet_road = 0.0;
	float puddle_m = 0.0;
	float wet = wetness;
	vec2 tex_uv = UV / 3.2;
	vec2 nor_xy = vec2(0.5);
	float nor_str = 0.0;

	if (cls > 0.75) {
		// Dirt / gravel road verge (or landscaped green turf on roundabout central islands when COLOR.a ~ 0.4)
		tex_uv = UV / 2.4;
		vec3 v_diff = texture(tex_verge_diff, tex_uv).rgb;
		vec3 v_arm = texture(tex_verge_arm, tex_uv).rgb;
		nor_xy = texture(tex_verge_nor, tex_uv).xy;
		float macro = vnoise(UV * 0.12);
		float is_turf = step(0.25, COLOR.a) * (1.0 - step(0.65, COLOR.a));
		vec3 dirt_tint = mix(vec3(0.84, 0.86, 0.74), vec3(1.06, 1.02, 0.92), macro);
		vec3 turf_tint = mix(vec3(0.42, 0.72, 0.28), vec3(0.56, 0.84, 0.34), macro);
		col = v_diff * mix(dirt_tint, turf_tint, is_turf);
		ao = mix(0.65, 1.0, v_arm.r);
		rough = clamp(v_arm.g, 0.75, 0.98);
		spec = 0.25;
		nor_str = 0.85 * nor_fade;
		wet *= 0.45;
	} else if (cls > 0.42) {
		// City sidewalk pavers
		tex_uv = UV / 2.2;
		vec3 c_diff = texture(tex_concrete_diff, tex_uv).rgb;
		vec3 c_arm = texture(tex_concrete_arm, tex_uv).rgb;
		nor_xy = texture(tex_concrete_nor, tex_uv).xy;
		col = c_diff * vec3(0.96, 0.95, 0.92);
		ao = mix(0.65, 1.0, c_arm.r);
		rough = clamp(c_arm.g, 0.62, 0.94);
		spec = 0.35;
		nor_str = 0.8 * nor_fade;
		wet *= 0.8;
	} else if (cls > 0.20) {
		// Highway/country/mountain road shoulders & city kerbstones
		tex_uv = UV / 2.0;
		vec3 c_diff = texture(tex_concrete_diff, tex_uv).rgb;
		vec3 c_arm = texture(tex_concrete_arm, tex_uv).rgb;
		nor_xy = texture(tex_concrete_nor, tex_uv).xy;
		if (type == 3) {
			// Granite/concrete kerb with 1 m block joints and gutter shadow
			float joint = smoothstep(0.035, 0.0, abs(fract(UV.y) - 0.5) - 0.475);
			float is_vert = 1.0 - smoothstep(0.3, 0.7, v_world_n.y);
			col = c_diff * mix(vec3(0.82, 0.82, 0.80), vec3(0.65, 0.65, 0.63), is_vert * 0.5);
			col *= 1.0 - joint * 0.35;
			rough = mix(0.75, 0.88, is_vert);
			wet *= (1.0 - 0.65 * is_vert);
			ao = mix(0.68, 1.0, c_arm.r);
		} else {
			// Weathered paved asphalt-gravel shoulder (seamless with carriageway, no brick seams)
			tex_uv = UV / 3.4;
			vec3 a_sh = texture(tex_asphalt_diff, tex_uv).rgb;
			vec3 v_sh = texture(tex_verge_diff, UV / 2.6).rgb;
			vec3 sh_arm = texture(tex_asphalt_arm, tex_uv).rgb;
			nor_xy = texture(tex_asphalt_nor, tex_uv).xy;
			float grv = vnoise(UV * 0.35);
			col = mix(a_sh * vec3(0.64, 0.65, 0.66), v_sh * vec3(0.72, 0.70, 0.64), 0.18 + 0.16 * grv);
			rough = clamp(sh_arm.g + 0.14, 0.76, 0.96);
			ao = mix(0.66, 1.0, sh_arm.r);
		}
		spec = 0.32;
		nor_str = 0.75 * nor_fade;
	} else {
		// Main roadway asphalt (dual-scale blend eliminates repeating crack seams)
		tex_uv = UV / 3.8;
		vec2 tex_uv2 = UV / 6.1 + vec2(0.41, 0.29);
		float var_mix = smoothstep(0.25, 0.75, vnoise(UV * 0.11));
		vec3 a_diff = mix(texture(tex_asphalt_diff, tex_uv).rgb, texture(tex_asphalt_diff, tex_uv2).rgb, var_mix * 0.65);
		vec3 a_arm = mix(texture(tex_asphalt_arm, tex_uv).rgb, texture(tex_asphalt_arm, tex_uv2).rgb, var_mix * 0.65);
		nor_xy = mix(texture(tex_asphalt_nor, tex_uv).xy, texture(tex_asphalt_nor, tex_uv2).xy, var_mix * 0.65);

		float macro_a = vnoise(UV * 0.045);
		float macro_b = vnoise(UV * 0.19 + 11.7);
		float patch_tone = mix(0.82, 1.15, macro_a * 0.65 + macro_b * 0.35);

		// Wheel-track polish & rubber wear along lane centres
		float wear = 0.0;
		if (draw_lines) {
			if (type == 0) {
				float d1 = min(abs(ax - 1.90), abs(ax - 3.60));
				float d2 = min(abs(ax - 5.60), abs(ax - 7.30));
				wear = exp(-pow(min(d1, d2) / 0.55, 2.0));
			} else if (type == 4) {
				float d_trk = min(abs(ax - 0.75), abs(ax - 0.75));
				wear = exp(-pow(d_trk / 0.65, 2.0));
			} else {
				float lane_c = hw * 0.5;
				float d_trk = min(abs(ax - (lane_c - 0.72)), abs(ax - (lane_c + 0.72)));
				wear = exp(-pow(d_trk / 0.45, 2.0));
			}
		}

		// Slight gutter / edge dirt darkening near the road edge (wider on rural backroads)
		float dirt_w = (type == 5) ? 1.35 : 0.85;
		float edge_dirt = smoothstep(hw - dirt_w, hw, ax) * (draw_lines ? 1.0 : 0.0);
		vec3 asphalt_col = a_diff * patch_tone * mix(vec3(0.82, 0.83, 0.86), vec3(0.70, 0.71, 0.74), wear * 0.7);
		asphalt_col = mix(asphalt_col, asphalt_col * vec3(0.95, 0.90, 0.82) * 0.85, edge_dirt * (type == 5 ? 0.68 : 0.5));

		// Highway rumble strip indentation just outside the outer edge line (ax ~ 8.55..8.85 m)
		float rumble = 0.0;
		if (draw_lines && type == 0) {
			float in_r = smoothstep(8.42, 8.48, ax) * (1.0 - smoothstep(8.84, 8.90, ax));
			rumble = in_r * step(0.45, fract(UV.y * 2.5));
			asphalt_col *= 1.0 - rumble * 0.18;
		}

		ao = mix(0.58, 1.0, a_arm.r) * (1.0 - rumble * 0.25);
		rough = clamp(mix(0.76, 0.94, a_arm.g) - wear * 0.14, 0.55, 0.96);
		nor_str = mix(0.95, 0.70, wear * 0.5) * nor_fade;

		// Painted lane-line decals
		float white_line = 0.0;
		float yellow_line = 0.0;
		if (draw_lines) {
			float dash = step(fract(UV.y / 12.0), 0.38);
			float fade = clamp(1.0 - fwidth(UV.y) * 0.25, 0.0, 1.0);
			if (type == 0) {
				yellow_line = max(band(ax, 0.82, 0.065), band(ax, 1.00, 0.065));
				white_line = max(band(ax, 8.30, 0.08), band(ax, 4.60, 0.075) * dash);
			} else if (type == 1) {
				white_line = band(ax, hw - 0.25, 0.065);
				yellow_line = band(ax, 0.0, 0.065) * dash;
			} else if (type == 2) {
				white_line = band(ax, hw - 0.25, 0.065);
				yellow_line = band(ax, 0.11, 0.055);
			} else if (type == 3) {
				white_line = band(ax, 0.0, 0.065) * dash;
			} else if (type == 4) {
				yellow_line = band(UV.x, -(hw - 0.35), 0.065);
				white_line = band(UV.x, hw - 0.35, 0.065);
			} else {
				white_line = band(ax, 0.0, 0.055) * step(fract(UV.y / 16.0), 0.25) * 0.55;
			}
			float paint_chip = smoothstep(0.24, 0.62, a_arm.r + vnoise(UV * 3.8) * 0.28);
			float paint_mask = mix(0.68, 0.96, paint_chip) * fade;
			white_line *= paint_mask;
			yellow_line *= paint_mask;
		}

		vec3 white_paint = vec3(0.84, 0.83, 0.78);
		vec3 yellow_paint = vec3(0.86, 0.62, 0.15);
		float line_m = clamp(max(white_line, yellow_line), 0.0, 1.0);
		vec3 line_col = mix(white_paint, yellow_paint, step(white_line, yellow_line));

		col = mix(asphalt_col, line_col, line_m);
		rough = mix(rough, 0.44, line_m);
		nor_str = mix(nor_str, nor_str * 0.42, line_m);
		spec = mix(0.42, 0.52, line_m);

		// Standing puddles when raining (concentrated slightly in wheel ruts)
		if (wet > 0.01) {
			float p_n = vnoise(UV * 0.13) * 0.62 + vnoise(UV * 0.38 + vec2(17.3, 9.1)) * 0.38;
			float puddle = smoothstep(0.64 - 0.24 * wet, 0.74 - 0.20 * wet, p_n + wear * 0.10);
			puddle *= smoothstep(0.10, 0.40, wet) * (1.0 - edge_dirt * 0.65);
			wet_road = wet;
			puddle_m = puddle;
			col *= mix(1.0, 0.36, wet);
			col *= mix(1.0, 0.68, puddle);
			// Soft broad sky sheen on damp asphalt; mirror-sharp highlights on standing puddles
			float damp_rough = clamp(0.28 + a_arm.g * 0.18, 0.28, 0.44);
			rough = mix(rough, damp_rough, wet);
			rough = mix(rough, 0.025, puddle);
			spec = mix(spec, 0.65, wet);
			spec = mix(spec, 1.0, puddle);
			metal = mix(0.0, 0.12, puddle * wet);
			cc = mix(wet * 0.42, 1.0, puddle);
			cc_rough = mix(0.28, 0.02, puddle);
			nor_str *= mix(1.0, 0.60, wet);
			nor_str *= (1.0 - puddle * 0.96);
			// Sporadic, subtle raindrop micro-ripples on nearby puddles
			if (puddle > 0.15 && dist < 30.0) {
				float rip_fade = (1.0 - smoothstep(10.0, 30.0, dist)) * puddle * wet;
				vec2 rp1 = UV * 4.5;
				vec2 c1 = floor(rp1);
				float h1 = hash(c1);
				float t1 = fract(TIME * 1.35 + h1 * 7.13);
				vec2 f1 = fract(rp1) - (0.25 + 0.5 * vec2(h1, hash(c1 + 3.7)));
				float d1 = length(f1);
				float w1 = exp(-pow((d1 - t1 * 0.42) * 18.0, 2.0)) * sin(t1 * 3.14159) * step(0.68, h1);
				vec2 dir1 = (d1 > 0.001) ? (f1 / d1) * w1 : vec2(0.0);

				vec2 rp2 = UV * 7.2 + vec2(3.7, 8.1);
				vec2 c2 = floor(rp2);
				float h2 = hash(c2);
				float t2 = fract(TIME * 1.65 + h2 * 5.91);
				vec2 f2 = fract(rp2) - (0.25 + 0.5 * vec2(h2, hash(c2 + 9.2)));
				float d2 = length(f2);
				float w2 = exp(-pow((d2 - t2 * 0.40) * 18.0, 2.0)) * sin(t2 * 3.14159) * step(0.72, h2);
				vec2 dir2 = (d2 > 0.001) ? (f2 / d2) * w2 : vec2(0.0);

				vec2 rip = (dir1 + dir2) * 0.055 * rip_fade;
				nor_xy = mix(nor_xy, vec2(0.5) + rip, clamp(rip_fade, 0.0, 0.85));
				nor_str = max(nor_str, rip_fade * 0.24);
			}
			wet = 0.0; // already applied above
		}
	}

	if (wet > 0.001) {
		col *= mix(1.0, 0.54, wet);
		rough = mix(rough, 0.28, wet);
		spec = mix(spec, 0.72, wet);
		cc = wet * 0.26;
		cc_rough = 0.34;
	}

	vec3 pn = perturb_normal(NORMAL, VERTEX, tex_uv, nor_xy, nor_str);
	vec3 wet_emit = vec3(0.0);
	if (wet_road > 0.01) {
		float ndv = clamp(dot(pn, normalize(VIEW)), 0.0, 1.0);
		float fresnel = pow(1.0 - ndv, 4.0);
		vec3 sky_wet = mix(vec3(0.32, 0.37, 0.44), vec3(0.04, 0.06, 0.11), night_factor);
		wet_emit = sky_wet * fresnel * wet_road * mix(0.11, 0.22, puddle_m);
	}
	ALBEDO = col;
	AO = ao;
	ROUGHNESS = rough;
	SPECULAR = spec;
	METALLIC = metal;
	CLEARCOAT = cc;
	CLEARCOAT_ROUGHNESS = cc_rough;
	EMISSION = wet_emit;
	NORMAL = pn;
}
