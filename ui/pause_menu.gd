class_name PauseMenu
extends Control
## Polished tabbed Pause + Settings menu (T17b/T29): live 3D preview behind blurred overlay,
## Low/Medium/High presets + per-item overrides, Apply/Revert, gamepad navigable.

signal respawn_requested
signal quit_requested
signal time_set_requested(hour: float)

const ACCENT: Color = Color(1.0, 0.502, 0.0)
const BG_PANEL: Color = Color(0.08, 0.095, 0.125, 0.90)
const BG_CARD: Color = Color(0.115, 0.135, 0.175, 0.92)
const BG_BTN: Color = Color(0.16, 0.185, 0.24, 0.95)
const TEXT_DIM: Color = Color(0.70, 0.74, 0.80)

var _snap: Dictionary = {}
var _syncing: bool = false
var _tabs: TabContainer
var _status_lbl: Label
var _resume_btn: Button
var _preset_opt: OptionButton
var _ctrls: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	_build_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if visible:
			close_menu()
		else:
			open_menu()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()
	elif visible and event is InputEventJoypadButton and event.pressed:
		var jb := event as InputEventJoypadButton
		if jb.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_cycle_tab(-1)
			get_viewport().set_input_as_handled()
		elif jb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_cycle_tab(1)
			get_viewport().set_input_as_handled()


func _cycle_tab(dir: int) -> void:
	if _tabs == null or _tabs.get_tab_count() == 0:
		return
	var n: int = _tabs.get_tab_count()
	_tabs.current_tab = (_tabs.current_tab + dir + n) % n


func open_menu() -> void:
	_snap = Settings.snapshot()
	_sync_from_settings()
	_status_lbl.text = "Live preview active"
	visible = true
	get_tree().paused = true
	if _resume_btn != null:
		_resume_btn.grab_focus()


func close_menu() -> void:
	visible = false
	get_tree().paused = false


func _apply_and_save() -> void:
	Settings.save_settings()
	_snap = Settings.snapshot()
	_status_lbl.text = "Saved to user://settings.cfg"


func _revert() -> void:
	Settings.restore(_snap)
	Settings.apply_all()
	_sync_from_settings()
	_status_lbl.text = "Reverted changes"


func _on_preset_selected(idx: int) -> void:
	if _syncing:
		return
	Settings.apply_preset(Settings.PRESET_NAMES[idx])
	Settings.apply_all()
	_sync_from_settings()
	_status_lbl.text = "Preset: %s (unsaved)" % Settings.preset.capitalize()


func _set_setting(key: String, val: Variant) -> void:
	if _syncing:
		return
	Settings.set(key, val)
	Settings.apply_all()
	_status_lbl.text = "Modified (unsaved)"


func _sync_from_settings() -> void:
	_syncing = true
	var pidx: int = Settings.PRESET_NAMES.find(Settings.preset)
	if _preset_opt != null and pidx >= 0:
		_preset_opt.selected = pidx
	for k: String in _ctrls:
		var ctrl: Control = _ctrls[k]
		var v: Variant = Settings.get(k)
		if ctrl is CheckButton:
			(ctrl as CheckButton).button_pressed = bool(v)
		elif ctrl is HSlider:
			(ctrl as HSlider).value = float(v)
			var val_lbl: Label = ctrl.get_meta("val_lbl", null) as Label
			if val_lbl != null:
				val_lbl.text = str(ctrl.get_meta("fmt", "%.2f")) % float(v)
		elif ctrl is OptionButton:
			if k == "weather_mode":
				var modes: PackedStringArray = ["clear", "overcast", "rain"]
				var mi: int = modes.find(str(v))
				(ctrl as OptionButton).selected = maxi(mi, 0)
			else:
				(ctrl as OptionButton).selected = int(v)
	_syncing = false


func _build_ui() -> void:
	theme = _make_theme()
	var blur := ColorRect.new()
	blur.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/blur_overlay.gdshader")
	blur.material = mat
	add_child(blur)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 56)
	margin.add_theme_constant_override("margin_right", 56)
	margin.add_theme_constant_override("margin_top", 36)
	margin.add_theme_constant_override("margin_bottom", 36)
	add_child(margin)

	var panel := PanelContainer.new()
	margin.add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	panel.add_child(root)

	# Header
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	root.add_child(hdr)
	var title := Label.new()
	title.text = "P1 DRIVE  //  SETTINGS & PAUSE"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", ACCENT)
	hdr.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = SIZE_EXPAND_FILL
	hdr.add_child(sp)
	_status_lbl = Label.new()
	_status_lbl.add_theme_color_override("font_color", TEXT_DIM)
	hdr.add_child(_status_lbl)
	_resume_btn = _btn("Resume", close_menu)
	hdr.add_child(_resume_btn)
	hdr.add_child(_btn("Respawn (R)", func() -> void:
		close_menu()
		respawn_requested.emit()
	))
	hdr.add_child(_btn("Quit", func() -> void: quit_requested.emit()))

	# Tabbed content
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(_tabs)

	_build_graphics_tab()
	_build_display_tab()
	_build_audio_tab()
	_build_controls_tab()
	_build_gameplay_tab()

	# Footer Apply / Revert
	var ftr := HBoxContainer.new()
	ftr.add_theme_constant_override("separation", 12)
	root.add_child(ftr)
	var hint := Label.new()
	hint.text = "Esc / Start: Close   •   Preset applies live; Apply persists to disk"
	hint.add_theme_color_override("font_color", TEXT_DIM)
	hint.size_flags_horizontal = SIZE_EXPAND_FILL
	ftr.add_child(hint)
	ftr.add_child(_btn("Revert", _revert))
	var apply_b: Button = _btn("Apply & Save", _apply_and_save)
	apply_b.add_theme_color_override("font_color", ACCENT)
	ftr.add_child(apply_b)


func _tab_page(tab_name: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = tab_name
	sc.follow_focus = true
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(sc)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_left", 18)
	pad.add_theme_constant_override("margin_right", 18)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 14)
	sc.add_child(pad)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 10)
	pad.add_child(vb)
	return vb


func _build_graphics_tab() -> void:
	var vb: VBoxContainer = _tab_page("Graphics")
	var row := _row(vb, "Quality Preset", "Low = lean 60 FPS  |  Medium = default balanced  |  High = realism hook")
	_preset_opt = OptionButton.new()
	for p: String in ["Low", "Medium", "High"]:
		_preset_opt.add_item(p)
	_preset_opt.custom_minimum_size.x = 220.0
	_preset_opt.item_selected.connect(_on_preset_selected)
	row.add_child(_preset_opt)

	_add_slider(vb, "Resolution Scale", "resolution_scale", 0.65, 1.0, 0.05, "%.2fx")
	_add_option(vb, "Shadows", "shadow_quality", ["Off", "Low (1024 / 40m)", "Medium (2048 / 70m)", "High (4096 / 120m)"])
	_add_option(vb, "Anti-Aliasing", "aa_mode", ["Off", "MSAA 2x", "MSAA 4x", "FXAA"])
	_add_check(vb, "Glow / Bloom", "glow")
	_add_check(vb, "SSAO (High / Forward+ hook)", "ssao")
	_add_check(vb, "SSR (High / Forward+ hook)", "ssr")
	_add_option(vb, "Reflections", "reflections", ["Off", "Sky Ambient", "Full Reflections"])
	_add_slider(vb, "Draw Distance", "draw_distance", 1600.0, 4500.0, 100.0, "%.0f m")
	_add_slider(vb, "Scatter Density", "scatter_density", 0.3, 1.5, 0.1, "%.1fx")
	_add_slider(vb, "Scatter Range", "scatter_range", 200.0, 650.0, 25.0, "%.0f m")
	_add_check(vb, "Motion Blur", "motion_blur")


func _build_display_tab() -> void:
	var vb: VBoxContainer = _tab_page("Display")
	_add_check(vb, "Fullscreen", "fullscreen")
	_add_check(vb, "VSync", "vsync")
	_add_slider(vb, "Camera FOV Offset", "fov_offset", -10.0, 15.0, 1.0, "%+.0f deg")
	_add_check(vb, "Show FPS in HUD (F3)", "fps_visible")


func _build_audio_tab() -> void:
	var vb: VBoxContainer = _tab_page("Audio")
	_add_slider(vb, "Master Volume", "master_vol", 0.0, 1.0, 0.05, "%.2f")
	_add_slider(vb, "SFX Volume", "sfx_vol", 0.0, 1.0, 0.05, "%.2f")
	_add_slider(vb, "Radio / Music Volume", "music_vol", 0.0, 1.0, 0.05, "%.2f")


func _build_controls_tab() -> void:
	var vb: VBoxContainer = _tab_page("Controls")
	_add_slider(vb, "Steering Sensitivity", "steer_sensitivity", 0.5, 1.5, 0.05, "%.2fx")
	_add_slider(vb, "Drift Countersteer Assist", "countersteer_assist", 0.0, 1.0, 0.05, "%.2f")
	var info := Label.new()
	info.text = "Keys: WASD/Arrows Drive  •  Space Handbrake  •  G Drift Mode  •  Shift DRS  •  C Camera  •  T +1h  •  R Respawn  •  N/B/M Radio"
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", TEXT_DIM)
	vb.add_child(info)


func _build_gameplay_tab() -> void:
	var vb: VBoxContainer = _tab_page("Gameplay")
	_add_check(vb, "Auto Headlights at Night", "auto_headlights")
	var wrow := _row(vb, "Weather", "Clear / Overcast / Rain (Medium particles + wet road)")
	var wopt := OptionButton.new()
	for w: String in ["Clear", "Overcast", "Rain"]:
		wopt.add_item(w)
	wopt.custom_minimum_size.x = 220.0
	wopt.item_selected.connect(func(idx: int) -> void:
		var modes: PackedStringArray = ["clear", "overcast", "rain"]
		_set_setting("weather_mode", modes[idx])
	)
	wrow.add_child(wopt)
	_ctrls["weather_mode"] = wopt

	var trow := _row(vb, "Time of Day", "Jump sky time immediately")
	var thbox := HBoxContainer.new()
	thbox.add_theme_constant_override("separation", 8)
	trow.add_child(thbox)
	for pair: Array in [["Morning (8h)", 8.0], ["Afternoon (17h)", 17.0], ["Dusk (19h)", 19.2], ["Night (23h)", 23.0]]:
		thbox.add_child(_btn(pair[0], _on_time_btn.bind(float(pair[1]))))
	_add_check(vb, "Companion Stub (P)", "companion_visible")


func _on_time_btn(hour: float) -> void:
	time_set_requested.emit(hour)


func _row(parent: Control, label_text: String, sub_text: String = "") -> HBoxContainer:
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_CARD
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", sb)
	parent.add_child(card)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	card.add_child(hb)
	var lv := VBoxContainer.new()
	lv.size_flags_horizontal = SIZE_EXPAND_FILL
	hb.add_child(lv)
	var l := Label.new()
	l.text = label_text
	lv.add_child(l)
	if sub_text != "":
		var s := Label.new()
		s.text = sub_text
		s.add_theme_font_size_override("font_size", 12)
		s.add_theme_color_override("font_color", TEXT_DIM)
		lv.add_child(s)
	return hb


func _add_check(parent: Control, label_text: String, key: String) -> void:
	var hb: HBoxContainer = _row(parent, label_text)
	var cb := CheckButton.new()
	cb.toggled.connect(func(on: bool) -> void: _set_setting(key, on))
	hb.add_child(cb)
	_ctrls[key] = cb


func _add_option(parent: Control, label_text: String, key: String, items: Array[String]) -> void:
	var hb: HBoxContainer = _row(parent, label_text)
	var opt := OptionButton.new()
	opt.custom_minimum_size.x = 220.0
	for it: String in items:
		opt.add_item(it)
	opt.item_selected.connect(func(idx: int) -> void: _set_setting(key, idx))
	hb.add_child(opt)
	_ctrls[key] = opt


func _add_slider(parent: Control, label_text: String, key: String, lo: float, hi: float, stp: float, fmt: String) -> void:
	var hb: HBoxContainer = _row(parent, label_text)
	var val_lbl := Label.new()
	val_lbl.custom_minimum_size.x = 74.0
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = stp
	sl.custom_minimum_size = Vector2(210.0, 24.0)
	sl.set_meta("val_lbl", val_lbl)
	sl.set_meta("fmt", fmt)
	sl.value_changed.connect(func(v: float) -> void:
		val_lbl.text = fmt % v
		_set_setting(key, v)
	)
	hb.add_child(sl)
	hb.add_child(val_lbl)
	_ctrls[key] = sl


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(96.0, 34.0)
	b.pressed.connect(cb)
	return b


func _make_theme() -> Theme:
	var t := Theme.new()
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = BG_PANEL
	panel_sb.border_color = Color(0.28, 0.32, 0.40, 0.7)
	panel_sb.set_border_width_all(1)
	panel_sb.set_corner_radius_all(10)
	panel_sb.set_content_margin_all(18)
	t.set_stylebox("panel", "PanelContainer", panel_sb)

	var btn_n := StyleBoxFlat.new()
	btn_n.bg_color = BG_BTN
	btn_n.set_corner_radius_all(6)
	btn_n.set_content_margin_all(8)
	var btn_h := btn_n.duplicate() as StyleBoxFlat
	btn_h.bg_color = Color(0.24, 0.27, 0.34, 0.98)
	var btn_f := btn_h.duplicate() as StyleBoxFlat
	btn_f.border_color = ACCENT
	btn_f.set_border_width_all(2)
	for cls: String in ["Button", "OptionButton", "CheckButton"]:
		t.set_stylebox("normal", cls, btn_n)
		t.set_stylebox("hover", cls, btn_h)
		t.set_stylebox("pressed", cls, btn_h)
		t.set_stylebox("focus", cls, btn_f)

	var tab_u := StyleBoxFlat.new()
	tab_u.bg_color = Color(0.10, 0.12, 0.16, 0.9)
	tab_u.set_corner_radius_all(4)
	tab_u.content_margin_left = 14
	tab_u.content_margin_right = 14
	tab_u.content_margin_top = 7
	tab_u.content_margin_bottom = 7
	var tab_s := tab_u.duplicate() as StyleBoxFlat
	tab_s.bg_color = Color(0.18, 0.21, 0.27, 0.98)
	tab_s.border_color = ACCENT
	tab_s.border_width_bottom = 2
	t.set_stylebox("tab_unselected", "TabContainer", tab_u)
	t.set_stylebox("tab_hovered", "TabContainer", tab_u)
	t.set_stylebox("tab_selected", "TabContainer", tab_s)
	var tab_p := StyleBoxFlat.new()
	tab_p.bg_color = Color(0.06, 0.075, 0.10, 0.65)
	tab_p.set_corner_radius_all(6)
	t.set_stylebox("panel", "TabContainer", tab_p)

	var sl_bg := StyleBoxFlat.new()
	sl_bg.bg_color = Color(0.20, 0.23, 0.30, 0.9)
	sl_bg.set_corner_radius_all(3)
	sl_bg.content_margin_top = 4
	sl_bg.content_margin_bottom = 4
	var sl_fill := StyleBoxFlat.new()
	sl_fill.bg_color = ACCENT
	sl_fill.set_corner_radius_all(3)
	t.set_stylebox("slider", "HSlider", sl_bg)
	t.set_stylebox("grabber_area", "HSlider", sl_fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", sl_fill)
	return t
