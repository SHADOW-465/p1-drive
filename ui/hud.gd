class_name HUD
extends Control
## Driving HUD (H1): Forza-style Speedo + Minimap + next-turn card, radio track, time, FPS (F3).
## Design units are 720p pixels; _layout() scales them to the viewport height.

var car: Car
var sky: DayNight

var _radio_lbl: Label
var _fps_lbl: Label
var _speedo: Speedo
var _minimap: Minimap
var _gps: _GpsPanel
var _radio_text: String = "No music"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_build_ui()
	resized.connect(_layout)
	_layout()
	_fps_lbl.visible = Settings.fps_visible
	_minimap.visible = Settings.minimap_visible
	set_radio_text(Radio.status_text())
	Radio.track_changed.connect(set_radio_text)
	Settings.settings_changed.connect(func() -> void:
		if _fps_lbl != null:
			_fps_lbl.visible = Settings.fps_visible
		if _minimap != null:
			_minimap.visible = Settings.minimap_visible
	)


func _exit_tree() -> void:
	MapData.shutdown_bg()


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


func set_car(c: Car) -> void:
	car = c
	_minimap.car = c
	_speedo.set_car(c)


func _process(dt: float) -> void:
	if _fps_lbl.visible:
		_fps_lbl.text = "FPS %d" % Engine.get_frames_per_second()
	_radio_lbl.text = _format_top_left()
	if car == null:
		return
	var fwd: Vector3 = -car.global_basis.z
	GpsRoute.update(Origin.to_world(car.global_position), Vector2(fwd.x, fwd.z), dt)
	if _gps != null:
		_gps.visible = GpsRoute.active


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

	_speedo = Speedo.new()
	_speedo.car = car
	add_child(_speedo)

	_minimap = Minimap.new()
	_minimap.car = car
	add_child(_minimap)

	_gps = _GpsPanel.new()
	_gps.visible = false
	_gps.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gps)


func _layout() -> void:
	var u: float = clampf(size.y / 720.0, 0.6, 3.0)
	var m: float = 16.0 * u
	_speedo.set_ui_scale(u)
	_speedo.position = size - _speedo.size - Vector2(m * 0.5, m * 0.5)
	_minimap.set_ui_scale(u)
	_minimap.position = Vector2(m * 0.5, size.y - _minimap.size.y - m * 0.5)
	_gps.u = u
	_gps.size = Vector2(Minimap.BOX - 6.0, 50.0) * u
	_gps.position = Vector2(m * 0.5 + 3.0 * u, _minimap.position.y - _gps.size.y - 4.0 * u)
	_gps.queue_redraw()


class _GpsPanel extends Control:
	var u: float = 1.0
	var _key: String = ""
	var _card: StyleBoxFlat

	func _init() -> void:
		_card = StyleBoxFlat.new()
		_card.bg_color = Color(0.03, 0.05, 0.08, 0.72)
		_card.set_corner_radius_all(14)
		_card.set_border_width_all(1)
		_card.anti_aliasing = true
		_card.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
		_card.shadow_size = 6

	func _process(_dt: float) -> void:
		if not visible:
			return
		var key: String = "%s|%d|%d|%s" % [GpsRoute.turn_kind, roundi(GpsRoute.turn_dist_m), roundi(GpsRoute.remain_m), GpsRoute.reachable]
		if key != _key:
			_key = key
			queue_redraw()

	func _draw() -> void:
		if not GpsRoute.active:
			return
		var kind: String = GpsRoute.turn_kind
		var accent := Color(0.22, 0.95, 1.0, 0.95)
		var ang: float = 0.0
		var title: String = "ROUTE"
		if kind == "left":
			ang = -PI * 0.5
			title = "LEFT"
		elif kind == "right":
			ang = PI * 0.5
			title = "RIGHT"
		elif kind == "uturn":
			ang = PI
			title = "U-TURN"
		elif kind == "arrive":
			title = "ARRIVE"
		elif kind == "straight":
			title = "STRAIGHT"
		elif kind == "none":
			title = "NO ROUTE"
			accent = Color(1.0, 0.55, 0.25, 0.95)
		_card.border_color = Color(accent, 0.5)
		draw_style_box(_card, Rect2(Vector2.ZERO, size))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(u, u))
		var h: float = size.y / u
		var pivot := Vector2(27.0, h * 0.5)
		draw_circle(pivot, 17.0, Color(accent, 0.12))
		draw_arc(pivot, 17.0, 0.0, TAU, 32, Color(accent, 0.55), 1.2, true)
		if kind == "arrive":
			draw_arc(pivot, 8.0, 0.0, TAU, 20, accent, 2.0, true)
			draw_circle(pivot, 2.8, accent)
		elif kind != "none":
			var tip := Vector2(0.0, -10.0).rotated(ang) + pivot
			var bl := Vector2(-7.0, 7.0).rotated(ang) + pivot
			var br := Vector2(7.0, 7.0).rotated(ang) + pivot
			draw_colored_polygon(PackedVector2Array([tip, br, bl]), accent)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var ts: int = roundi(17.0 * u)
		var ss: int = roundi(12.0 * u)
		var tx: float = 52.0 * u
		var dist: String = ""
		var show_turn: bool = kind == "left" or kind == "right" or kind == "uturn"
		if GpsRoute.reachable and not (kind == "uturn" and GpsRoute.turn_dist_m < 1.0):
			dist = GpsRoute.format_dist(GpsRoute.turn_dist_m if show_turn else GpsRoute.remain_m)
		var ty: float = 22.0 * u + 0.35 * ts
		draw_string(Speedo.F_NUM, Vector2(tx, ty + 1.5), title, HORIZONTAL_ALIGNMENT_LEFT, -1, ts, Color(0, 0, 0, 0.45))
		draw_string(Speedo.F_NUM, Vector2(tx, ty), title, HORIZONTAL_ALIGNMENT_LEFT, -1, ts, Color(0.95, 0.98, 1.0))
		if dist != "":
			draw_string(Speedo.F_NUM, Vector2(0.0, ty), dist, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 12.0 * u, ts, accent)
		var sub: String = ""
		if kind == "uturn" and GpsRoute.turn_dist_m < 1.0:
			sub = "Turn around  •  %s left" % GpsRoute.format_dist(GpsRoute.remain_m)
		elif show_turn:
			sub = "%s to waypoint" % GpsRoute.format_dist(GpsRoute.remain_m)
		elif kind == "none":
			sub = "No road reaches this pin"
		if sub != "":
			draw_string(Speedo.F_TXT, Vector2(tx, 41.0 * u + 0.35 * ss), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, ss, Color(0.72, 0.80, 0.86))
