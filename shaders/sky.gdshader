shader_type sky;
// HDRI sky blended with day/sunset/night/overcast cycle, dynamic sun Mie glow + disc,
// moon halo, ground bounce, and atmospheric horizon haze matching scene fog.

uniform sampler2D tex_day : filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_sunset : filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_night : filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_overcast : filter_linear_mipmap, repeat_enable;

uniform float sunset_weight : hint_range(0.0, 1.0) = 0.0;
uniform float night_weight : hint_range(0.0, 1.0) = 0.0;
uniform float overcast_weight : hint_range(0.0, 1.0) = 0.0;
uniform float hdri_yaw = 0.0;
uniform float sky_exposure = 1.0;

uniform vec3 sun_dir = vec3(0.0, 0.5, -0.866);
uniform vec3 sun_color = vec3(1.0, 0.92, 0.80);
uniform float sun_intensity = 1.0;
uniform vec3 moon_dir = vec3(0.0, 0.5, 0.866);

uniform vec3 horizon_haze_color = vec3(0.68, 0.76, 0.86);
uniform float horizon_haze_amount : hint_range(0.0, 1.0) = 0.65;

vec3 soft_clamp_hdr(vec3 c, float limit) {
	float lum = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
	if (lum <= limit) {
		return c;
	}
	float new_lum = limit + (lum - limit) / (1.0 + (lum - limit) * 0.25);
	return c * (new_lum / lum);
}

void sky() {
	float lod = AT_CUBEMAP_PASS ? 1.5 : 0.0;
	vec2 uv = vec2(fract(SKY_COORDS.x + hdri_yaw), clamp(SKY_COORDS.y, 0.003, 0.997));

	vec3 day_col = soft_clamp_hdr(textureLod(tex_day, uv, lod).rgb, 3.5);
	vec3 sunset_col = soft_clamp_hdr(textureLod(tex_sunset, uv, lod).rgb, 4.0);
	vec3 night_col = soft_clamp_hdr(textureLod(tex_night, uv, lod).rgb, 3.0);
	vec3 oc_col = soft_clamp_hdr(textureLod(tex_overcast, uv, lod).rgb, 3.0);

	// Blend clear sky across day -> golden hour/sunset -> night.
	vec3 clear_sky = mix(day_col, sunset_col, sunset_weight);
	clear_sky = mix(clear_sky, night_col * vec3(0.55, 0.65, 0.88), night_weight);

	// Blend overcast/rain sky.
	vec3 oc_sky = mix(oc_col * 0.82, night_col * 0.28, night_weight);
	vec3 col = mix(clear_sky, oc_sky, overcast_weight);

	// Natural ground bounce below horizon so vehicle/road reflections are grounded.
	float ground_fade = smoothstep(0.015, -0.18, EYEDIR.y);
	vec3 ground_col = horizon_haze_color * vec3(0.28, 0.27, 0.25);
	col = mix(col, ground_col, ground_fade);

	// Dynamic sun disc + Mie atmospheric scattering aligned with DirectionalLight3D.
	vec3 s_dir = normalize(sun_dir);
	float sun_cos = max(dot(EYEDIR, s_dir), 0.0);
	float above_hor = smoothstep(-0.04, 0.025, EYEDIR.y);
	float sun_vis = sun_intensity * (1.0 - overcast_weight * 0.88) * (1.0 - night_weight) * above_hor;
	float mie_wide = pow(sun_cos, 6.0) * 0.20;
	float mie_tight = pow(sun_cos, 72.0) * 0.85;
	float sun_corona = pow(sun_cos, 360.0) * 2.2;
	float sun_disc = smoothstep(0.99984, 0.99994, sun_cos) * 24.0;
	col += sun_color * (mie_wide + mie_tight + sun_corona + sun_disc) * sun_vis;

	// Subtle moonlight atmospheric halo at night.
	vec3 m_dir = normalize(moon_dir);
	float moon_cos = max(dot(EYEDIR, m_dir), 0.0);
	float moon_halo = pow(moon_cos, 56.0) * 0.14 * night_weight * (1.0 - overcast_weight * 0.85) * above_hor;
	col += vec3(0.55, 0.68, 0.92) * moon_halo;

	// Atmospheric haze band right at the horizon so far terrain blends seamlessly into sky.
	float hor_band = pow(1.0 - clamp(abs(EYEDIR.y), 0.0, 1.0), 16.0);
	vec3 haze = horizon_haze_color + sun_color * pow(sun_cos, 4.0) * 0.16 * sun_vis;
	col = mix(col, haze, clamp(hor_band * horizon_haze_amount, 0.0, 0.85));

	COLOR = col * sky_exposure;
}
