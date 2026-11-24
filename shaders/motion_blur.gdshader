shader_type canvas_item;
// Lightweight radial velocity blur (High preset / Settings.motion_blur toggle), masked clear at screen center.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	if (strength <= 0.005) {
		discard;
	}
	vec2 d = SCREEN_UV - vec2(0.5, 0.52);
	float dist = length(d * vec2(1.4, 1.0));
	float mask = smoothstep(0.18, 0.78, dist);
	vec2 dir = d * (strength * 0.032 * mask);
	vec3 acc = vec3(0.0);
	acc += texture(screen_tex, SCREEN_UV).rgb * 0.22;
	acc += texture(screen_tex, SCREEN_UV - dir * 0.35).rgb * 0.24;
	acc += texture(screen_tex, SCREEN_UV - dir * 0.70).rgb * 0.22;
	acc += texture(screen_tex, SCREEN_UV - dir * 1.10).rgb * 0.18;
	acc += texture(screen_tex, SCREEN_UV - dir * 1.55).rgb * 0.14;
	COLOR = vec4(acc, clamp(mask * strength * 0.85, 0.0, 0.85));
}
