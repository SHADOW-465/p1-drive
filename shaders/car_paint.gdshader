shader_type spatial;
// Whole car body in one draw. UV.y picks the material:
//   0..12  shell (panels, intakes, lamps and shut lines are masks on the model-space position)
//   20..21 canopy (glass with painted door frame / rear quarter)
//   -1 plain (COLOR.rgb, COLOR.a = roughness), -2 grille, -3 body paint, -4 metal, -5 carbon, -6 glass
// Shapes shared with cars/p1/p1_mesh.gd (_scallop, _lamp_d): keep both in step.
uniform vec3 paint_color : source_color = vec3(1.0, 0.36, 0.02);
uniform float flake : hint_range(0.0, 1.0) = 0.6;
uniform float coat_gloss : hint_range(0.0, 1.0) = 1.0;

varying vec3 mp;
varying vec3 mn;

void vertex() {
	mp = VERTEX;
	mn = NORMAL;
}

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// 1 where d > 0, antialiased
float aa(float d) {
	float w = fwidth(d) + 1e-5;
	return smoothstep(-w, w, d);
}

float line(float d, float half_w) {
	return aa(half_w - abs(d));
}

float scallop_raw(float z, float y) {
	float t = clamp((z + 1.0) / 1.65, 0.0, 1.0);
	float yc = mix(0.40, 0.50, t);
	float hh = mix(0.06, 0.24, t);
	float up = smoothstep(0.0, 1.0, (yc + hh - y) / (0.35 * hh));
	float dn = smoothstep(0.0, 1.0, (y - (yc - hh)) / (1.2 * hh));
	return 0.16 * t * t * (3.0 - 2.0 * t) * up * dn;
}

float lamp_d(vec2 q) {
	vec2 a = vec2(0.50, -2.35);
	vec2 ba = vec2(0.87, -1.96) - a;
	float h = clamp(dot(q - a, ba) / dot(ba, ba), 0.0, 1.0);
	float d_top = length(q - a - ba * h) - (0.025 + 0.048 * sin(PI * pow(h, 0.75)));
	// Lower boomerang hook dipping into front bumper intake corner
	vec2 a2 = vec2(0.66, -2.18);
	vec2 b2 = vec2(0.61, -2.37) - a2;
	float h2 = clamp(dot(q - a2, b2) / dot(b2, b2), 0.0, 1.0);
	float d_hook = length(q - a2 - b2 * h2) - 0.024;
	return min(d_top, d_hook);
}

vec2 proj(vec3 p, vec3 n) {
	vec3 an = abs(n);
	return an.y > 0.6 ? p.xz : (an.x > an.z ? p.zy : p.xy);
}

float weave(vec2 q) {
	q *= 170.0;
	float t = step(2.0, mod(floor(q.x) + floor(q.y), 4.0));
	float fade = clamp(1.0 - max(fwidth(q.x), fwidth(q.y)) * 1.4, 0.0, 1.0);
	return mix(0.82, mix(0.55, 1.45, t), fade);
}

float grille(vec2 q) {
	q *= 70.0;
	float g = step(0.36, max(abs(fract(q.x + q.y) - 0.5), abs(fract(q.x - q.y) - 0.5)));
	float fade = clamp(1.0 - max(fwidth(q.x), fwidth(q.y)) * 1.3, 0.0, 1.0);
	return mix(0.32, g, fade);
}

// prm = roughness, metallic, clearcoat, paintness
void put(inout vec3 alb, inout vec4 prm, float w, vec3 a, vec4 p) {
	alb = mix(alb, a, w);
	prm = mix(prm, p, w);
}

void fragment() {
	float s = UV.y;
	float ax = abs(mp.x);
	float ndotv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndotv, 4.0);
	vec2 pq = proj(mp, mn);
	vec3 carbon = vec3(0.022) * weave(pq);
	vec3 paint_flop = mix(paint_color * 0.72, paint_color * 1.24, fresnel);
	const vec4 P_PAINT = vec4(0.24, 0.80, 1.0, 1.0);
	const vec4 P_CARBON = vec4(0.30, 0.16, 0.85, 0.0);
	const vec4 P_GLASS = vec4(0.02, 0.14, 1.0, 0.0);
	const vec4 P_GRILLE = vec4(0.58, 0.12, 0.0, 0.0);
	vec3 glass = mix(vec3(0.008, 0.011, 0.015), vec3(0.036, 0.050, 0.068), fresnel);
	vec3 mesh = vec3(0.05) * grille(pq);
	vec3 alb = paint_flop;
	vec4 prm = P_PAINT;
	float seam = 0.0;
	if (s >= 19.0) {  // canopy: continuous black teardrop glass + swept painted C/B-pillar arch
		float af = s - 20.0;
		// Smooth teardrop belt/roof-edge curve along side window (-0.82 .. +1.05)
		float tz = clamp((mp.z + 0.82) / 1.85, 0.0, 1.0);
		float arch_hi = 0.56 - 0.36 * pow(tz, 1.8) - 0.24 * pow(1.0 - tz, 2.2);
		float arch_w = 0.11 + 0.05 * sin(PI * tz);
		float frame = aa(af - (arch_hi - arch_w)) * aa(arch_hi - af) * step(-0.84, mp.z) * step(mp.z, 1.05) * aa(ax - 0.38);
		float carbon_trim = aa(arch_hi + 0.025 - af) * aa(af - (arch_hi - arch_w - 0.015)) * step(-0.88, mp.z) * step(mp.z, 1.12);
		alb = glass;
		prm = P_GLASS;
		put(alb, prm, carbon_trim * 0.85, vec3(0.015), P_CARBON);
		put(alb, prm, frame, paint_flop, P_PAINT);
		put(alb, prm, line(mp.z - 0.22, 0.013) * aa(arch_hi - 0.02 - af), vec3(0.015), P_CARBON);
		// Rear engine deck louvered glass vents behind cabin (z > 0.72)
		float eng_mesh = aa(mp.z - 0.72) * aa(1.42 - mp.z) * aa(0.38 - ax);
		put(alb, prm, eng_mesh * 0.72, mesh, P_GRILLE);
		seam = max(line(af - arch_hi, 0.004), line(af - (arch_hi - arch_w), 0.004)) * step(-0.80, mp.z) * step(mp.z, 0.95) * aa(ax - 0.38);
	} else if (s >= 0.0) {  // shell
		float lower = max(aa(3.2 - s), aa(mp.z - 1.48) * aa(0.41 - mp.y) * aa(8.0 - s));
		put(alb, prm, lower, carbon, P_CARBON);
		// Sculpted front P1 bumper mouth + diagonal carbon fang intakes flanking central radiator
		float nose_jaw = aa(-1.92 - mp.z) * aa(0.35 + 0.16 * smoothstep(0.38, 0.70, ax) - mp.y) * aa(0.74 - ax) * aa(7.8 - s);
		float cheek_fang = aa(-1.98 - mp.z) * aa(-lamp_d(vec2(ax, mp.z)) + 0.03) * aa(0.48 - mp.y) * aa(ax - 0.48);
		put(alb, prm, nose_jaw, mesh, P_GRILLE);
		put(alb, prm, clamp(cheek_fang, 0.0, 1.0) * aa(8.2 - s), carbon, P_CARBON);
		// Smoked polycarbonate boomerang headlight bucket
		put(alb, prm, aa(-lamp_d(vec2(ax, mp.z))) * aa(s - 5.6), vec3(0.012, 0.014, 0.018), P_GLASS);
		// Side intake scoop carbon surround + internal grille
		float sc = scallop_raw(mp.z, mp.y);
		put(alb, prm, aa(sc - 0.032) * aa(8.8 - s), carbon, P_CARBON);
		put(alb, prm, aa(sc - 0.032) * aa(mp.z - 0.50) * aa(8.8 - s), mesh, P_GRILLE);
		// Rear engine deck vents
		put(alb, prm, aa(mp.z - 1.46) * aa(0.70 - ax) * aa(s - 9.2), mesh, P_GRILLE);
		// Hood & door shutlines
		float hx = 0.56 + 0.10 * smoothstep(-2.45, -1.5, mp.z);
		seam = line(ax - hx, 0.003) * step(-2.46, mp.z) * step(mp.z, -1.13) * aa(s - 8.2);
		seam = max(seam, max(line(mp.z + 0.86, 0.003), line(mp.z - 0.20, 0.003)) * aa(s - 3.3) * aa(10.6 - s));
	} else {
		int id = int(round(-s));
		if (id == 1) {
			if (COLOR.a > 0.72) {
				// Rubber tyre tread & sidewall shoulder differentiation
				float r_w = length(mp.yz);
				float is_tread = smoothstep(0.27, 0.305, r_w);
				float tread = smoothstep(0.25, 0.82, sin(atan(mp.y, mp.z) * 44.0) * sin(mp.x * 55.0));
				alb = COLOR.rgb * mix(1.05, 0.72 + 0.36 * tread, is_tread);
				prm = vec4(mix(0.68, 0.89, is_tread), 0.0, mix(0.06, 0.0, is_tread), 0.0);
			} else {
				alb = COLOR.rgb;
				prm = vec4(COLOR.a, 0.0, 0.15, 0.0);
			}
		} else if (id == 2) {
			alb = mesh;
			prm = P_GRILLE;
		} else if (id == 4) {
			alb = COLOR.rgb;
			prm = vec4(COLOR.a, 0.92, 0.28, 0.0);
		} else if (id == 5) {
			alb = carbon;
			prm = P_CARBON;
		} else if (id == 6) {
			alb = glass;
			prm = P_GLASS;
		}
	}
	// Dual-scale metallic flake: sharp micro sparkle up close, smooth metallic sheen from afar
	float fw = clamp(1.0 - length(fwidth(mp)) * 220.0, 0.0, 1.0);
	float spark = step(0.86, hash(floor(mp * 880.0))) * fw;
	float micro_sheen = hash(floor(mp * 220.0)) * 0.14;
	alb += paint_color * prm.w * flake * (0.04 + micro_sheen + 0.85 * spark);
	alb *= 1.0 - 0.92 * seam;
	ALBEDO = alb;
	ROUGHNESS = mix(prm.x, 0.72, seam);
	METALLIC = prm.y;
	CLEARCOAT = prm.z * coat_gloss;
	CLEARCOAT_ROUGHNESS = mix(0.035, 0.08, 1.0 - prm.w);
	SPECULAR = mix(0.55, 0.72, prm.z);
}
