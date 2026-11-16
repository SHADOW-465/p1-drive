shader_type spatial;
// Road props (T18): guardrails, poles, emissive lamp heads (COLOR.a > 0.5).
global uniform float night_factor;

void fragment() {
	float emis = step(0.5, COLOR.a);
	ALBEDO = COLOR.rgb;
	METALLIC = mix(0.35, 0.0, emis);
	ROUGHNESS = mix(0.55, 0.25, emis);
	EMISSION = COLOR.rgb * emis * (0.15 + 4.5 * night_factor);
}
