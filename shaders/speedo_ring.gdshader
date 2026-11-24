shader_type canvas_item;
// H1: Forza-style RPM ring. One quad, everything analytic so edges are anti-aliased and glows are free.
// Design units: 252 x 252 quad, ring radius 104, y down. Gauge spans 270 deg opening at the bottom, 0..9000 rpm.
uniform float rpm_t = 0.0;        // needle position, fraction of 9000 rpm (spring-smoothed on the CPU)
uniform float redline_t = 0.8444; // 7600 rpm
uniform float flash = 0.0;        // shift light 0..1
uniform float ers = 0.0;          // boost / ERS 0..1
uniform float ers_on = 0.0;       // 1 for cars that have it
uniform float aa = 0.8;           // pixel width in design units (1 / ui scale)

const float R = 104.0;
const float A0 = -2.35619449;
const float SPAN = 4.71238898;

vec4 over(vec4 d, vec3 c, float a) {
	a = clamp(a, 0.0, 1.0);
	float oa = a + d.a * (1.0 - a);
	vec3 oc = oa > 0.0001 ? (c * a + d.rgb * d.a * (1.0 - a)) / oa : vec3(0.0);
	return vec4(oc, oa);
}

float cov(float d, float hw) {
	return 1.0 - smoothstep(hw - aa * 0.5, hw + aa * 0.5, d);
}

float arc_d(vec2 p, float r0, float a0, float a1) {
	float a = clamp(atan(p.x, -p.y), a0, a1);
	return length(p - r0 * vec2(sin(a), -cos(a)));
}

vec3 heat(float t) {
	vec3 w = vec3(0.95, 0.97, 1.0);
	vec3 pk = vec3(1.0, 0.36, 0.60);
	vec3 rd = vec3(1.0, 0.10, 0.18);
	vec3 c = mix(w, pk, smoothstep(0.60, redline_t, t));
	return mix(c, rd, smoothstep(redline_t, 0.93, t));
}

void fragment() {
	vec2 p = (UV - 0.5) * 252.0;
	float r = length(p);
	float ang = atan(p.x, -p.y);
	float tp = (ang - A0) / SPAN;
	vec4 o = vec4(0.0);

	// soft drop shadow + dark translucent backing
	float sh = (1.0 - smoothstep(R - 18.0, R + 20.0, length(p - vec2(0.0, 7.0)))) * 0.40;
	o = over(o, vec3(0.0), sh);
	float back = 1.0 - smoothstep(R - 3.0, R + 11.0, r);
	o = over(o, vec3(0.015, 0.025, 0.045), back * (0.34 + 0.12 * smoothstep(20.0, R, r)));

	// track
	o = over(o, vec3(1.0), cov(arc_d(p, R, A0, -A0), 1.2) * 0.20);

	// redline zone: red band + glow, stronger as the needle enters it
	float into = smoothstep(redline_t - 0.04, 1.0, rpm_t);
	float rl_d = arc_d(p, R, A0 + SPAN * redline_t, -A0);
	vec3 red = vec3(1.0, 0.12, 0.20);
	o = over(o, red, exp(-rl_d * 0.16) * (0.16 + 0.34 * into));
	o = over(o, red, cov(rl_d, 1.6) * 0.85);

	// fill + glow
	float a_end = A0 + SPAN * clamp(rpm_t, 0.0, 1.0);
	float fd = arc_d(p, R, A0, max(a_end, A0 + 0.01));
	vec3 fc = heat(clamp(tp, 0.0, 1.0));
	float f_on = smoothstep(0.004, 0.02, rpm_t);
	o = over(o, fc, exp(-fd * 0.26) * 0.34 * f_on);
	o = over(o, fc, cov(fd, 1.9) * f_on);

	// ticks: 500 rpm minor, 1000 rpm major
	float k = clamp(round(tp * 18.0), 0.0, 18.0);
	float ta = k / 18.0;
	float off = abs(tp - ta) * SPAN * r;
	bool major = mod(k, 2.0) < 0.5;
	float len = major ? 9.0 : 4.5;
	float hw = major ? 0.9 : 0.5;
	float rout = R - 5.5;
	float rin = rout - len;
	float rm = smoothstep(rin - aa * 0.5, rin + aa * 0.5, r) * (1.0 - smoothstep(rout - aa * 0.5, rout + aa * 0.5, r));
	float tm = cov(off, hw) * rm;
	vec3 tc = vec3(1.0);
	float ta_alpha = major ? 0.80 : 0.45;
	if (ta >= redline_t - 0.002) { tc = red; ta_alpha = 0.95; }
	else if (ta <= rpm_t) { tc = fc; ta_alpha = 1.0; }
	o = over(o, tc, tm * ta_alpha);

	// needle: thin, fades in from the hub side, glow
	vec2 dir = vec2(sin(a_end), -cos(a_end));
	float along = dot(p, dir);
	float perp = abs(p.x * dir.y - p.y * dir.x);
	float n_rng = smoothstep(34.0, 58.0, along) * (1.0 - smoothstep(R + 1.0, R + 4.0, along));
	vec3 nc = mix(vec3(1.0), heat(clamp(rpm_t, 0.0, 1.0)), 0.55);
	o = over(o, nc, exp(-perp * 0.42) * 0.34 * n_rng);
	o = over(o, nc, cov(perp, 0.8 + 0.5 * smoothstep(60.0, R, along)) * n_rng);

	// ERS / boost arc outside the ring
	if (ers_on > 0.5) {
		o = over(o, vec3(1.0), cov(arc_d(p, R + 9.0, A0, -A0), 0.9) * 0.14);
		float e_end = A0 + SPAN * clamp(ers, 0.0, 1.0);
		float ed = arc_d(p, R + 9.0, A0, max(e_end, A0 + 0.01));
		vec3 ec = mix(vec3(0.25, 0.80, 1.0), vec3(0.62, 0.70, 1.0), clamp(ers, 0.0, 1.0));
		float e_on = smoothstep(0.004, 0.02, ers);
		o = over(o, ec, exp(-ed * 0.35) * 0.28 * e_on);
		o = over(o, ec, cov(ed, 1.3) * e_on);
	}

	// shift light: whole gauge pulses pink-white
	float rd = abs(r - R);
	float g_mask = smoothstep(-0.05, 0.0, tp) * (1.0 - smoothstep(1.0, 1.05, tp));
	o = over(o, vec3(1.0, 0.42, 0.62), exp(-rd * 0.14) * flash * 0.55 * g_mask);
	o = over(o, vec3(1.0, 0.9, 0.95), cov(arc_d(p, R, A0, -A0), 1.6) * flash * 0.45);

	COLOR = o;
}
