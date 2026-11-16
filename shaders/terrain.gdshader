shader_type spatial;
// Terrain: vertex colour + cheap tile-periodic value noise for ground detail (no textures).

global uniform float wetness;
varying vec3 lpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// value noise; period wraps so the pattern is seamless across 1024 m tiles
float vnoise(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec2 a = mod(i, period);
	vec2 b = mod(i + 1.0, period);
	return mix(mix(hash(a), hash(vec2(b.x, a.y)), f.x), mix(hash(vec2(a.x, b.y)), hash(b), f.x), f.y);
}

void vertex() {
	lpos = VERTEX;
}

void fragment() {
	float dist = length(VERTEX);
	float fine = vnoise(lpos.xz * 0.75, 768.0) - 0.5;
	float coarse = vnoise(lpos.xz * 0.0625, 64.0) - 0.5;
	float k = 1.0 + coarse * 0.22 + fine * 0.2 * (1.0 - smoothstep(40.0, 160.0, dist));
	ALBEDO = COLOR.rgb * k * mix(1.0, 0.72, wetness);
	ROUGHNESS = mix(0.95, 0.6, wetness);
	SPECULAR = 0.15;
}
