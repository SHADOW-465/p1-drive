shader_type spatial;
// Brushed cross-drilled carbon/steel brake rotor with cherry-orange thermal glow under braking.

uniform float heat : hint_range(0.0, 1.0) = 0.0;

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float r = length(lp.yz);
	float ang = atan(lp.y, lp.z);
	// Radial brushed lathe grooves on the friction ring (0.105 .. 0.195 m)
	float in_ring = smoothstep(0.095, 0.110, r) * (1.0 - smoothstep(0.188, 0.202, r));
	float lathe = 0.5 + 0.5 * sin(r * 420.0);
	// Subtle cross-drilled ventilation pattern
	float dr = sin((r - 0.115) * 95.0);
	float da = sin(ang * 12.0 + floor((r - 0.115) * 30.0) * 0.6);
	float hole = smoothstep(0.86, 0.94, dr * da) * in_ring;

	vec3 hat_col = vec3(0.09, 0.095, 0.105);
	vec3 rotor_col = mix(vec3(0.32, 0.34, 0.37), vec3(0.42, 0.44, 0.48), lathe) * (1.0 - hole * 0.72);
	ALBEDO = mix(hat_col, rotor_col, in_ring);
	METALLIC = mix(0.45, 0.90, in_ring);
	ROUGHNESS = mix(0.48, mix(0.22, 0.36, lathe), in_ring);
	SPECULAR = 0.75;

	float glow = heat * heat * in_ring * (1.0 - hole * 0.4);
	vec3 ember = mix(vec3(1.0, 0.22, 0.02), vec3(1.0, 0.56, 0.14), clamp(heat, 0.0, 1.0));
	EMISSION = ember * glow * 5.8;
}
