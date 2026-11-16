shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;
// Fake ground glow quads under streetlights (T18 / PLAN §1).
global uniform float night_factor;

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float g = pow(max(1.0 - r, 0.0), 2.2);
	ALBEDO = COLOR.rgb * g * night_factor * 0.42;
	ALPHA = 1.0;
}
