shader_type spatial;
// Medium-quality procedural city building shader (L2): facade + mullion/window grid + night lit windows.
global uniform float night_factor;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	// UV is scaled in metres (set per-face or via UV * building scale in COLOR.a/UV).
	vec2 w_uv = UV;
	float is_roof = step(0.92, NORMAL.y);
	vec2 cell = floor(w_uv / vec2(3.2, 3.6));
	vec2 f = fract(w_uv / vec2(3.2, 3.6));
	// Window pane bounds inside each 3.2m x 3.6m bay; leave ground floor (y < 4m) dark/lobby.
	float win_x = step(0.18, f.x) * step(f.x, 0.82);
	float win_y = step(0.24, f.y) * step(f.y, 0.80);
	float above_ground = step(1.0, cell.y);
	float is_win = win_x * win_y * above_ground * (1.0 - is_roof);

	float seed = COLOR.a * 37.0;
	float rnd = hash21(cell + vec2(seed, seed * 0.53));
	float lit = step(0.45, rnd) * night_factor;
	vec3 warm = vec3(1.0, 0.84, 0.56);
	vec3 cool = vec3(0.74, 0.88, 1.0);
	vec3 win_glow = mix(warm, cool, step(0.76, rnd)) * (0.65 + 0.5 * fract(rnd * 13.7));

	vec3 wall_col = COLOR.rgb * (0.92 + 0.08 * hash21(vec2(floor(w_uv.y / 3.6), seed)));
	vec3 glass_col = vec3(0.08, 0.12, 0.17);
	vec3 roof_col = COLOR.rgb * 0.62;

	vec3 base = mix(wall_col, glass_col, is_win);
	base = mix(base, roof_col, is_roof);
	ALBEDO = base;
	ROUGHNESS = mix(0.84, 0.22, is_win);
	METALLIC = mix(0.05, 0.35, is_win);
	EMISSION = win_glow * is_win * lit * 2.2;
}
