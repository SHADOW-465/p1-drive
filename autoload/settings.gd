extends Node
## Input map (PLAN §5) and persistent user settings + Low/Medium/High presets (T17b/T29).

signal settings_changed
signal high_preset_hook(enabled: bool, env: Environment, sun: DirectionalLight3D)

const CONFIG_PATH: String = "user://settings.cfg"

const KEYS: Dictionary = {
	"throttle": [KEY_W, KEY_UP], "brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT], "steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE], "drs": [KEY_SHIFT], "camera_toggle": [KEY_C],
	"respawn": [KEY_R], "radio_next": [KEY_N], "radio_prev": [KEY_B], "radio_toggle": [KEY_M],
	"time_skip": [KEY_T], "fps_toggle": [KEY_F3], "pause": [KEY_ESCAPE], "companion_toggle": [KEY_P],
	"drift_toggle": [KEY_G],
}
const PAD_BUTTONS: Dictionary = {
	"handbrake": 0, "drs": 10, "camera_toggle": 3, "respawn": 4, "radio_next": 14,
	"radio_prev": 13, "radio_toggle": 11, "time_skip": 12, "pause": 6, "drift_toggle": 2,
}
# action -> [axis, sign]
const PAD_AXES: Dictionary = {
	"throttle": [5, 1.0], "brake": [4, 1.0], "steer_left": [0, -1.0], "steer_right": [0, 1.0],
}

const PRESET_NAMES: PackedStringArray = ["low", "medium", "high"]
const PRESETS: Dictionary = {
	"low": {
		"resolution_scale": 0.85,
		"shadow_quality": 1,
		"aa_mode": 0,
		"glow": false,
		"ssao": false,
		"ssr": false,
		"reflections": 0,
		"draw_distance": 2400.0,
		"scatter_density": 0.5,
		"scatter_range": 300.0,
		"motion_blur": false,
	},
	"medium": {
		"resolution_scale": 1.0,
		"shadow_quality": 2,
		"aa_mode": 1,
		"glow": true,
		"ssao": false,
		"ssr": false,
		"reflections": 1,
		"draw_distance": 3600.0,
		"scatter_density": 1.0,
		"scatter_range": 450.0,
		"motion_blur": false,
	},
	"high": {
		"resolution_scale": 1.0,
		"shadow_quality": 3,
		"aa_mode": 2,
		"glow": true,
		"ssao": true,
		"ssr": true,
		"reflections": 2,
		"draw_distance": 4500.0,
		"scatter_density": 1.35,
		"scatter_range": 600.0,
		"motion_blur": true,
	},
}

# Graphics
var preset: String = "medium"
var resolution_scale: float = 1.0
var shadow_quality: int = 2  # 0 Off, 1 Low, 2 Med, 3 High
var aa_mode: int = 1  # 0 Off, 1 MSAA 2x, 2 MSAA 4x, 3 FXAA
var glow: bool = true
var ssao: bool = false
var ssr: bool = false
var reflections: int = 1  # 0 Off, 1 Sky, 2 High
var draw_distance: float = 3600.0
var scatter_density: float = 1.0
var scatter_range: float = 450.0
var motion_blur: bool = false

# Display
var fullscreen: bool = false
var vsync: bool = true
var fov_offset: float = 0.0
var fps_visible: bool = false

# Audio
var master_vol: float = 1.0
var sfx_vol: float = 1.0
var music_vol: float = 0.8

# Controls
var steer_sensitivity: float = 1.0
var countersteer_assist: float = 0.5

# Gameplay
var auto_headlights: bool = true
var weather_mode: String = "clear"
var companion_visible: bool = false
var music_dir: String = ""

var _high_handlers: Array[Callable] = []
var _headless: bool = false


func _init() -> void:
	_headless = DisplayServer.get_name() == "headless"
	for action: String in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.15)
		for key: int in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key as Key
			InputMap.action_add_event(action, ev)
	for action: String in PAD_BUTTONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.15)
		var ev := InputEventJoypadButton.new()
		ev.button_index = PAD_BUTTONS[action] as JoyButton
		InputMap.action_add_event(action, ev)
	for action: String in PAD_AXES:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.15)
		var ev := InputEventJoypadMotion.new()
		ev.axis = PAD_AXES[action][0] as JoyAxis
		ev.axis_value = PAD_AXES[action][1]
		InputMap.action_add_event(action, ev)


func _ready() -> void:
	if music_dir == "":
		music_dir = _default_music_dir()
	load_settings()
	call_deferred("apply_all")


func _default_music_dir() -> String:
	var home: String = OS.get_environment("USERPROFILE")
	if home == "":
		home = OS.get_environment("HOME")
	return home.path_join("Music").path_join("P1Drive") if home != "" else ""


func is_high() -> bool:
	return preset == "high"


func register_high_handler(cb: Callable) -> void:
	if not _high_handlers.has(cb):
		_high_handlers.append(cb)


func apply_preset(preset_name: String) -> void:
	var key: String = preset_name.to_lower()
	if not PRESETS.has(key):
		return
	preset = key
	var p: Dictionary = PRESETS[key]
	resolution_scale = p["resolution_scale"]
	shadow_quality = p["shadow_quality"]
	aa_mode = p["aa_mode"]
	glow = p["glow"]
	ssao = p["ssao"]
	ssr = p["ssr"]
	reflections = p["reflections"]
	draw_distance = p["draw_distance"]
	scatter_density = p["scatter_density"]
	scatter_range = p["scatter_range"]
	motion_blur = p["motion_blur"]


func snapshot() -> Dictionary:
	return {
		"preset": preset, "resolution_scale": resolution_scale, "shadow_quality": shadow_quality,
		"aa_mode": aa_mode, "glow": glow, "ssao": ssao, "ssr": ssr, "reflections": reflections,
		"draw_distance": draw_distance, "scatter_density": scatter_density, "scatter_range": scatter_range,
		"motion_blur": motion_blur, "fullscreen": fullscreen, "vsync": vsync,
		"fov_offset": fov_offset, "fps_visible": fps_visible, "master_vol": master_vol,
		"sfx_vol": sfx_vol, "music_vol": music_vol, "steer_sensitivity": steer_sensitivity,
		"countersteer_assist": countersteer_assist, "auto_headlights": auto_headlights,
		"weather_mode": weather_mode, "companion_visible": companion_visible, "music_dir": music_dir,
	}


func restore(d: Dictionary) -> void:
	for k: String in d:
		set(k, d[k])


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		apply_preset("medium")
		return
	var saved_preset: String = str(cfg.get_value("graphics", "preset", "medium"))
	apply_preset(saved_preset if PRESETS.has(saved_preset) else "medium")
	for k: String in ["resolution_scale", "shadow_quality", "aa_mode", "glow", "ssao", "ssr", "reflections", "draw_distance", "scatter_density", "scatter_range", "motion_blur"]:
		if cfg.has_section_key("graphics", k):
			set(k, cfg.get_value("graphics", k))
	for k: String in ["fullscreen", "vsync", "fov_offset", "fps_visible"]:
		if cfg.has_section_key("display", k):
			set(k, cfg.get_value("display", k))
	for k: String in ["master_vol", "sfx_vol", "music_vol"]:
		if cfg.has_section_key("audio", k):
			set(k, cfg.get_value("audio", k))
	for k: String in ["steer_sensitivity", "countersteer_assist"]:
		if cfg.has_section_key("controls", k):
			set(k, cfg.get_value("controls", k))
	for k: String in ["auto_headlights", "weather_mode", "companion_visible", "music_dir"]:
		if cfg.has_section_key("gameplay", k):
			set(k, cfg.get_value("gameplay", k))
	if music_dir == "":
		music_dir = _default_music_dir()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k: String in ["preset", "resolution_scale", "shadow_quality", "aa_mode", "glow", "ssao", "ssr", "reflections", "draw_distance", "scatter_density", "scatter_range", "motion_blur"]:
		cfg.set_value("graphics", k, get(k))
	for k: String in ["fullscreen", "vsync", "fov_offset", "fps_visible"]:
		cfg.set_value("display", k, get(k))
	for k: String in ["master_vol", "sfx_vol", "music_vol"]:
		cfg.set_value("audio", k, get(k))
	for k: String in ["steer_sensitivity", "countersteer_assist"]:
		cfg.set_value("controls", k, get(k))
	for k: String in ["auto_headlights", "weather_mode", "companion_visible", "music_dir"]:
		cfg.set_value("gameplay", k, get(k))
	cfg.save(CONFIG_PATH)


func apply_all(root: Node = null) -> void:
	_apply_audio()
	_apply_display_and_viewport()
	var scene_root: Node = root if root != null else (get_tree().current_scene if is_inside_tree() else null)
	if scene_root != null:
		var env: Environment = null
		var sun: DirectionalLight3D = null
		for n: Node in scene_root.find_children("*", "WorldEnvironment", true, false):
			env = (n as WorldEnvironment).environment
			break
		for n: Node in scene_root.find_children("*", "DirectionalLight3D", true, false):
			sun = n as DirectionalLight3D
			break
		var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
		apply_graphics_to_world(env, sun, cam)
	settings_changed.emit()


func apply_graphics_to_world(env: Environment, sun: DirectionalLight3D, cam: Camera3D = null) -> void:
	var is_fwd: bool = RenderingServer.get_current_rendering_method() == "forward_plus"
	if env != null:
		env.glow_enabled = glow
		env.fog_depth_end = clampf(draw_distance * 0.9, 1200.0, 4200.0)
		env.fog_depth_begin = env.fog_depth_end * 0.11
		if reflections == 0:
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_sky_contribution = 0.0
			env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		else:
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_sky_contribution = 0.65 if reflections == 1 else 1.0
			env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
		if is_fwd:
			env.ssao_enabled = ssao
			env.ssr_enabled = ssr
	if sun != null:
		sun.shadow_enabled = shadow_quality > 0
		var sizes: PackedInt32Array = [512, 1024, 2048, 4096]
		if not _headless:
			RenderingServer.directional_shadow_atlas_set_size(sizes[clampi(shadow_quality, 0, 3)], true)
		var dists: PackedFloat32Array = [0.0, 40.0, 70.0, 120.0]
		sun.directional_shadow_max_distance = dists[clampi(shadow_quality, 0, 3)]
		if shadow_quality <= 1:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		elif shadow_quality == 2:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		else:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	if cam != null:
		cam.far = draw_distance
	var high_on: bool = is_high()
	for cb: Callable in _high_handlers:
		if cb.is_valid():
			cb.call(high_on, env, sun)
	high_preset_hook.emit(high_on, env, sun)


func _apply_audio() -> void:
	_set_bus_vol("Master", master_vol)
	_set_bus_vol("SFX", sfx_vol)
	_set_bus_vol("Music", music_vol)


func _set_bus_vol(bus_name: String, lin: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_mute(idx, lin <= 0.001)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.001)))


func _apply_display_and_viewport() -> void:
	if _headless or not is_inside_tree():
		return
	var vp: Viewport = get_viewport()
	if vp != null:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = clampf(resolution_scale, 0.5, 1.0)
		match aa_mode:
			0:
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			1:
				vp.msaa_3d = Viewport.MSAA_2X
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			2:
				vp.msaa_3d = Viewport.MSAA_4X
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			3:
				vp.msaa_3d = Viewport.MSAA_DISABLED
				vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	var target_mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != target_mode:
		DisplayServer.window_set_mode(target_mode)
	var target_vsync: DisplayServer.VSyncMode = DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	if DisplayServer.window_get_vsync_mode() != target_vsync:
		DisplayServer.window_set_vsync_mode(target_vsync)


func rain_particle_count() -> int:
	if preset == "low":
		return 300
	if preset == "high":
		return 1000
	return 600


## True if the flag was passed either as a user arg (after --) or a plain arg.
func has_arg(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag) or OS.get_cmdline_args().has(flag)


## Value of "--name=value" from the command line, or def.
func arg_value(flag: String, def: String) -> String:
	for a: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def
