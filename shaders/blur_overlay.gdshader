shader_type canvas_item;
// Lightweight frosted blur + dark tint for the live-preview pause/settings overlay.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_lod : hint_range(0.0, 5.0) = 2.4;
uniform vec4 tint : source_color = vec4(0.04, 0.05, 0.07, 0.58);

void fragment() {
	vec4 bg = textureLod(screen_tex, SCREEN_UV, blur_lod);
	COLOR = vec4(mix(bg.rgb, tint.rgb, tint.a), 1.0);
}
