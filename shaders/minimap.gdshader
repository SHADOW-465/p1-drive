shader_type canvas_item;
// H1: circular rotating minimap. Samples the north-up road bake (SubViewport, re-rendered at low Hz)
// with the car heading, masks to a circle and fades the content into the rim. One quad per frame.
uniform sampler2D map_tex : filter_linear;
uniform float heading = 0.0;         // rad; world offset = rot(screen offset, +heading)
uniform vec2 uv_center = vec2(0.5);  // car position inside the bake, uv
uniform float uv_per_px = 0.001;     // bake uv per design px
uniform float box = 210.0;           // quad size, design px
uniform float radius = 96.0;         // circle radius, design px
uniform float pivot_off = 12.0;      // car sits this far below the circle centre
uniform float aa = 0.8;              // 1 / ui scale
uniform float ready = 0.0;
uniform vec4 backdrop : source_color = vec4(0.035, 0.05, 0.075, 0.80);

void fragment() {
	vec2 p = (UV - 0.5) * box;
	float r = length(p) / radius;
	vec2 v = p - vec2(0.0, pivot_off);
	float c = cos(heading);
	float s = sin(heading);
	vec2 w = vec2(v.x * c - v.y * s, v.x * s + v.y * c);
	vec4 m = texture(map_tex, uv_center + w * uv_per_px) * ready;
	// the bake is premultiplied; fade the map content into the rim so the edge feels soft
	float fade = 1.0 - smoothstep(0.70, 1.0, r);
	vec3 col = backdrop.rgb * (1.0 - m.a * fade) + m.rgb * fade;
	float vig = 1.0 - 0.45 * smoothstep(0.5, 1.0, r);
	float a_back = mix(backdrop.a, 0.62, smoothstep(0.55, 1.0, r));
	float a = mix(a_back, 1.0, m.a * fade);
	float edge = 1.0 - smoothstep(1.0 - aa / radius, 1.0, r);
	COLOR = vec4(col * vig, a * edge);
}
