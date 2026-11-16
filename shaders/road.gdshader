shader_type spatial;
// UV.x = signed metres from centreline, UV.y = metres along.
// COLOR.r = type id / 4 (0 highway, 1 country, 2 mountain, 3 city), COLOR.g = half paved width / 16,
// COLOR.b = 0 road, 0.5 sidewalk/concrete, 1 verge.
global uniform float wetness;
global uniform float night_factor;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float band(float x, float c, float w) {
	float aa = fwidth(x) + 0.001;
	return 1.0 - smoothstep(w - aa, w + aa, abs(x - c));
}

void fragment() {
	float ax = abs(UV.x);
	float hw = COLOR.g * 16.0;
	int type = int(COLOR.r * 4.0 + 0.5);
	float dash = step(fract(UV.y / 12.0), 0.4);
	float line = 0.0;
	if (type == 0) {
		line = max(band(ax, 0.9, 0.08), band(ax, 8.3, 0.08));
		line = max(line, band(ax, 4.6, 0.07) * dash);
	} else if (type == 1) {
		line = max(band(ax, hw - 0.25, 0.06), band(ax, 0.0, 0.06) * dash);
	} else if (type == 2) {
		line = max(band(ax, hw - 0.25, 0.06), band(ax, 0.0, 0.06));
	} else {
		line = band(ax, 0.0, 0.06) * dash;
	}
	// markings fade out with distance to stop shimmer
	line *= clamp(1.0 - fwidth(UV.y) * 0.25, 0.0, 1.0);
	float n = vnoise(UV * 5.0) * 0.5 + vnoise(UV * 0.6) * 0.5;
	vec3 asphalt = vec3(0.07, 0.07, 0.078) * (0.86 + 0.28 * n);
	vec3 col = mix(asphalt, vec3(0.8), line * 0.9);
	float wet = wetness;
	if (COLOR.b > 0.75) {
		col = vec3(0.17, 0.155, 0.105) * (0.8 + 0.4 * n);
		wet *= 0.3;
	} else if (COLOR.b > 0.25) {
		col = vec3(0.42, 0.42, 0.40) * (0.92 + 0.08 * n);
	}
	ALBEDO = col * (1.0 - 0.35 * wet);
	ROUGHNESS = mix(0.9, 0.15, wet);
	SPECULAR = mix(0.3, 0.8, wet);
}
