class_name HUD
extends Control
## Driving HUD (T28 / PLAN §10): speed, gear, RPM bar with redline + boost,
## aero/drift state, radio track, time, FPS (F3). <= 5 draw calls.

var car: Car
var sky: DayNight

var _speed_lbl: Label
var _meta_lbl: Label
var _radio_lbl: Label
var _fps_lbl: Label
var _tach: _TachPanel
var _radio_text: String = "No music"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build_ui()
	_fps_lbl.visible = Settings.fps_visible
	Settings.settings_changed.connect(func() -> void:
		if _fps_lbl != null:
			_fps_lbl.visible = Settings.fps_visible
	)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("fps_toggle"):
		Settings.fps_visible = not Settings.fps_visible
		_fps_lbl.visible = Settings.fps_visible
		get_viewport().set_input_as_handled()


func set_radio_text(txt: String) -> void:
	_radio_text = txt
	if _radio_lbl != null:
		_radio_lbl.text = _format_top_left()


func _format_top_left() -> String:
	var h: float = sky.hour if sky != null else 17.0
	var hh: int = int(floorf(h)) % 24
	var mm: int = int(floorf((h - floorf(h)) * 60.0)) % 60
	return "%02d:%02d  •  Radio: %s" % [hh, mm, _radio_text]


func _process(_dt: float) -> void:
	if _fps_lbl.visible:
		_fps_lbl.text = "FPS %d" % Engine.get_frames_per_second()
	_radio_lbl.text = _format_top_left()
	if car == null:
		return
	_speed_lbl.text = "%d" % roundi(car.speed_kmh)
	var aero_name: String = (car.get_node("Aero") as ActiveAero).state_name()
	var drift_str: String = "  •  DRIFT" if car.drift_mode else ""
	_meta_lbl.text = "km/h   G%s   %s%s" % [car.drivetrain.gear_label(), aero_name, drift_str]
	_tach.rpm = car.drivetrain.rpm
	_tach.boost = car.drivetrain.boost
	_tach.drs = aero_name == "DRS"
	_tach.airbrake = aero_name == "AIRBRAKE"
	_tach.queue_redraw()


func _build_ui() -> void:
	_radio_lbl = Label.new()
	_radio_lbl.position = Vector2(18.0, 14.0)
	_radio_lbl.add_theme_font_size_override("font_size", 14)
	_radio_lbl.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96, 0.90))
	_radio_lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.65))
	_radio_lbl.add_theme_constant_override("shadow_offset_x", 1)
	_radio_lbl.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_radio_lbl)

	_fps_lbl = Label.new()
	_fps_lbl.set_anchors_preset(PRESET_TOP_RIGHT)
	_fps_lbl.offset_left = -120.0
	_fps_lbl.offset_top = 14.0
	_fps_lbl.offset_right = -18.0
	_fps_lbl.offset_bottom = 40.0
	_fps_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_lbl.add_theme_font_size_override("font_size", 14)
	_fps_lbl.add_theme_color_override("font_color", Color(0.60, 0.95, 0.55))
	_fps_lbl.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.65))
	add_child(_fps_lbl)

	_tach = _TachPanel.new()
	_tach.set_anchors_preset(PRESET_BOTTOM_RIGHT)
	_tach.offset_left = -286.0
	_tach.offset_top = -126.0
	_tach.offset_right = -20.0
	_tach.offset_bottom = -20.0
	_tach.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_tach)

	_speed_lbl = Label.new()
	_speed_lbl.position = Vector2(16.0, 8.0)
	_speed_lbl.size = Vector2(234.0, 50.0)
	_speed_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_speed_lbl.add_theme_font_size_override("font_size", 40)
	_speed_lbl.add_theme_color_override("font_color", Color(0.98, 0.98, 0.99))
	_tach.add_child(_speed_lbl)

	_meta_lbl = Label.new()
	_meta_lbl.position = Vector2(16.0, 56.0)
	_meta_lbl.size = Vector2(234.0, 22.0)
	_meta_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_meta_lbl.add_theme_font_size_override("font_size", 14)
	_meta_lbl.add_theme_color_override("font_color", Color(1.0, 0.56, 0.14))
	_tach.add_child(_meta_lbl)


class _TachPanel extends Control:
	var rpm: float = 900.0
	var boost: float = 0.0
	var drs: bool = false
	var airbrake: bool = false

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.06, 0.075, 0.10, 0.78), true)
		var border_col := Color(0.95, 0.25, 0.18, 0.85) if airbrake else (Color(0.25, 0.85, 1.0, 0.85) if drs else Color(1.0, 0.502, 0.0, 0.55))
		draw_rect(r, border_col, false, 1.5)
		# RPM bar with redline (7600..8250)
		var bar := Rect2(14.0, size.y - 22.0, size.x - 28.0, 9.0)
		draw_rect(bar, Color(0.16, 0.18, 0.22, 0.9), true)
		var red_frac: float = 7600.0 / 8250.0
		var red_x: float = bar.position.x + bar.size.x * red_frac
		draw_rect(Rect2(red_x, bar.position.y, bar.position.x + bar.size.x - red_x, bar.size.y), Color(0.45, 0.10, 0.10, 0.85), true)
		var frac: float = clampf(rpm / 8250.0, 0.0, 1.0)
		var fill_col := Color(0.95, 0.22, 0.16) if rpm >= 7600.0 else (Color(1.0, 0.55, 0.08) if rpm >= 6000.0 else Color(0.92, 0.95, 1.0))
		draw_rect(Rect2(bar.position.x, bar.position.y, bar.size.x * frac, bar.size.y), fill_col, true)
		# Thin boost bar underneath
		var b_bar := Rect2(14.0, size.y - 9.0, (size.x - 28.0) * clampf(boost, 0.0, 1.0), 3.0)
		if b_bar.size.x > 0.5:
			draw_rect(b_bar, Color(0.25, 0.80, 1.0, 0.9), true)
