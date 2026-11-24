shader_type spatial;
// Realistic road props shader (M7): sculpted W-beam galvanized guardrails, brushed galvanized streetlight poles,
// cast-in-place weathered concrete Jersey barriers & bridge parapets, retroreflective road signs, and LED luminaires.
// COLOR.a encodes material class:
//   0.00..0.15: corrugated galvanized W-beam guardrail
//   0.15..0.35: brushed galvanized steel pole / post / cobra-head housing
//   0.35..0.55: cast-in-place weathered highway concrete (Jersey median, parapets, piers)
//   0.55..0.78: road sign face (UV samples signs_atlas)
//   0.78..0.89: night-driven LED streetlight lens
//   0.89..1.00: always-lit tunnel luminaire / retroreflective delineator stud

global uniform float night_factor;
global uniform float wetness;

uniform sampler2D tex_rail_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rail_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rail_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_metal_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_metal_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_metal_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_conc_diff : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_conc_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_conc_arm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D tex_sign_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

varying float cam_dist;

void vertex() {
	cam_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	float cls = COLOR.a;
	float nor_fade = 1.0 - smoothstep(45.0, 130.0, cam_dist);

	if (cls > 0.89) {
		// Always-lit tunnel luminaire or bright amber/white retroreflective barrier delineator
		ALBEDO = COLOR.rgb;
		METALLIC = 0.08;
		ROUGHNESS = 0.16;
		EMISSION = COLOR.rgb * mix(1.4, 3.8, night_factor);
	} else if (cls > 0.78) {
		// Warm sodium cobra-head streetlight emissive lens (#ffd29d)
		float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
		ALBEDO = mix(vec3(0.72, 0.74, 0.76), COLOR.rgb, 0.35 + 0.65 * night_factor);
		METALLIC = 0.05;
		ROUGHNESS = 0.14;
		EMISSION = COLOR.rgb * (0.03 + mix(2.1, 3.5, ndv) * night_factor);
	} else if (cls > 0.55) {
		// Road sign face (retroreflective micro-prismatic sheeting)
		vec4 s = texture(tex_sign_atlas, UV);
		ALBEDO = s.rgb;
		METALLIC = 0.12;
		ROUGHNESS = mix(0.24, 0.14, wetness);
		SPECULAR = 0.82;
		EMISSION = s.rgb * night_factor * 0.22;
	} else if (cls > 0.35) {
		// Cast-in-place weathered highway concrete (desaturated cool neutral concrete, subtle base road-spray grime)
		vec2 cuv = UV * 0.16;
		vec3 raw = texture(tex_conc_diff, cuv).rgb;
		float lum = dot(raw, vec3(0.299, 0.587, 0.114));
		vec3 neutral = mix(vec3(lum), raw, 0.12);
		// Subtle concrete form-seam every 4 m along UV.y + base grime near UV.x = 0
		float seam = 1.0 - 0.10 * smoothstep(0.96, 1.0, fract(UV.y * 0.5));
		float grime = mix(0.82, 1.0, smoothstep(0.0, 0.45, UV.x));
		vec3 diff = neutral * COLOR.rgb * vec3(1.50, 1.52, 1.55) * seam * grime;
		vec3 arm = texture(tex_conc_arm, cuv).rgb;
		vec3 nor = texture(tex_conc_nor, cuv).rgb;
		diff *= mix(1.0, 0.72, wetness);
		ALBEDO = diff * mix(0.78, 1.0, arm.r);
		METALLIC = 0.0;
		ROUGHNESS = mix(clamp(arm.g * 0.95, 0.68, 0.94), 0.26, wetness * 0.72);
		SPECULAR = mix(0.32, 0.58, wetness);
		if (nor_fade > 0.01) {
			NORMAL_MAP = nor;
			NORMAL_MAP_DEPTH = 0.28 * nor_fade;
		}
	} else if (cls > 0.15) {
		// Galvanized / anodized streetlight pole, I-beam post, and cobra-head housing
		vec3 raw = texture(tex_metal_diff, UV * 0.6).rgb;
		float lum = dot(raw, vec3(0.299, 0.587, 0.114));
		vec3 diff = mix(vec3(lum), raw, 0.25) * COLOR.rgb * 1.95;
		vec3 arm = texture(tex_metal_arm, UV * 0.6).rgb;
		vec3 nor = texture(tex_metal_nor, UV * 0.6).rgb;
		ALBEDO = diff * mix(0.76, 1.0, arm.r);
		METALLIC = clamp(0.72 + arm.b * 0.20, 0.62, 0.92);
		ROUGHNESS = mix(clamp(arm.g * 0.65, 0.22, 0.52), 0.14, wetness * 0.55);
		SPECULAR = 0.78;
		if (nor_fade > 0.01) {
			NORMAL_MAP = nor;
			NORMAL_MAP_DEPTH = 0.45 * nor_fade;
		}
	} else {
		// Corrugated galvanized W-beam steel guardrail
		vec3 raw = texture(tex_rail_diff, UV * 0.85).rgb;
		float lum = dot(raw, vec3(0.299, 0.587, 0.114));
		vec3 diff = mix(vec3(lum), raw, 0.20) * COLOR.rgb * 1.85;
		vec3 arm = texture(tex_rail_arm, UV * 0.85).rgb;
		vec3 nor = texture(tex_rail_nor, UV * 0.85).rgb;
		ALBEDO = diff * mix(0.75, 1.0, arm.r);
		METALLIC = clamp(0.76 + arm.b * 0.18, 0.65, 0.94);
		ROUGHNESS = mix(clamp(arm.g * 0.62, 0.18, 0.48), 0.12, wetness * 0.60);
		SPECULAR = 0.82;
		if (nor_fade > 0.01) {
			NORMAL_MAP = nor;
			NORMAL_MAP_DEPTH = 0.85 * nor_fade;
		}
	}
}
