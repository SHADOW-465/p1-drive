shader_type spatial;
// Car body/glass/trim in one draw: COLOR.rgb = albedo (linear), COLOR.a = roughness.
// Saturated colours are treated as metallic paint.
uniform float metallic = 0.55;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = COLOR.a;
	float sat = max(COLOR.r, max(COLOR.g, COLOR.b)) - min(COLOR.r, min(COLOR.g, COLOR.b));
	METALLIC = metallic * step(0.1, sat);
	SPECULAR = 0.6;
}
