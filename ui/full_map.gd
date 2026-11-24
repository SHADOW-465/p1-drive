class_name FullMap
extends Control
## Full-screen interactive world map toggled by M key (R6): pan/zoom, topographic
## terrain/coast background, RoadGraph network, town & region labels, player marker.
## R6c: click or F sets a road waypoint (a second click or F clears it) and draws the GPS route.

var car: Car

var _canvas: _FullMapCanvas
var _loc_lbl: Label
var _dragging: bool = false
var _press_button: int = -1
var _press_pos: Vector2 = Vector2.ZERO
var _cam_xz: Vector2 = Vector2(-100.0, 200.0)
var _zoom: float = 0.0385  # screen pixels per world meter
var _pulse_t: float = 0.0
var _opened_once: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	visible = false
	MapData.ensure_roads()
	MapData.start_bake_bg()
	_build_ui()


func _input(event: InputEvent) -> void:
	# While the map is up, consume keys before the pause menu's _unhandled_input.
	if not visible:
		return
	if event.is_action_pressed("map_toggle") or event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		close_map()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var ke := event as InputEventKey
		if ke.physical_keycode == KEY_SPACE or ke.physical_keycode == KEY_C:
			_center_on_player(true)
			get_viewport().set_input_as_handled()
		elif ke.physical_keycode == KEY_F and not ke.echo:
			_place_or_clear_at_cursor()
			get_viewport().set_input_as_handled()
		elif ke.physical_keycode == KEY_EQUAL or ke.physical_keycode == KEY_KP_ADD:
			_zoom_at(_canvas.size * 0.5, 1.25)
			get_viewport().set_input_as_handled()
		elif ke.physical_keycode == KEY_MINUS or ke.physical_keycode == KEY_KP_SUBTRACT:
			_zoom_at(_canvas.size * 0.5, 0.80)
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if visible or get_tree().paused:
		return
	if event.is_action_pressed("map_toggle"):
		open_map()
		get_viewport().set_input_as_handled()


func open_map() -> void:
	if visible:
		return
	MapData.ensure_roads()
	MapData.start_bake_bg()
	_sync_player()
	if not _opened_once:
		_opened_once = true
		_zoom = 0.0385
		_cam_xz = Vector2(-100.0, 200.0)
		_clamp_cam()
	visible = true
	# --shot=<frame> keeps the tree running so the frame counter can save the picture.
	get_tree().paused = Settings.arg_value("--shot", "") == ""
	_canvas.queue_redraw()


func close_map() -> void:
	visible = false
	_dragging = false
	_press_button = -1
	get_tree().paused = false


func _sync_player() -> void:
	if car == null:
		return
	var cw: Vector3 = Origin.to_world(car.global_position)
	_canvas.player_xz = Vector2(cw.x, cw.z)
	var fwd: Vector3 = -car.global_basis.z
	var f2 := Vector2(fwd.x, fwd.z)
	if f2.length_squared() > 1e-4:
		_canvas.player_heading = atan2(f2.x, -f2.y)
	if _loc_lbl != null:
		var reg: String = MapData.nearest_region_name(_canvas.player_xz)
		_loc_lbl.text = "Location: %s   •   %.1f km Network" % [reg, RoadGraph.total_km()]
		if GpsRoute.active:
			var route_bit: String = "NO ROUTE" if not GpsRoute.reachable else "Route %s" % GpsRoute.format_dist(GpsRoute.remain_m)
			_loc_lbl.text += "   •   " + route_bit


func _center_on_player(zoom_in: bool) -> void:
	_sync_player()
	_cam_xz = _canvas.player_xz
	if zoom_in and _zoom < 0.14:
		_zoom = 0.16
	_clamp_cam()
	_canvas.queue_redraw()


func _zoom_at(screen_pt: Vector2, factor: float) -> void:
	var old_z: float = _zoom
	var new_z: float = clampf(old_z * factor, 0.025, 1.40)
	if absf(new_z - old_z) < 1e-6:
		return
	var half: Vector2 = _canvas.size * 0.5
	var world_under: Vector2 = _cam_xz + (screen_pt - half) / old_z
	_zoom = new_z
	_cam_xz = world_under - (screen_pt - half) / new_z
	_clamp_cam()
	_canvas.queue_redraw()


func _clamp_cam() -> void:
	_cam_xz.x = clampf(_cam_xz.x, MapData.WORLD_MIN.x - 1000.0, MapData.WORLD_MAX.x + 1000.0)
	_cam_xz.y = clampf(_cam_xz.y, MapData.WORLD_MIN.y - 1000.0, MapData.WORLD_MAX.y + 1000.0)


func _process(dt: float) -> void:
	if not visible:
		return
	_pulse_t += dt
	var pan := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		pan.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		pan.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		pan.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		pan.y += 1.0
	if pan.length_squared() > 0.0:
		_cam_xz += pan.normalized() * (680.0 / _zoom) * dt
		_clamp_cam()

	if Input.is_physical_key_pressed(KEY_E):
		_zoom_at(_canvas.size * 0.5, 1.0 + 1.4 * dt)
	if Input.is_physical_key_pressed(KEY_Q):
		_zoom_at(_canvas.size * 0.5, maxf(1.0 - 1.4 * dt, 0.5))

	_sync_player()
	_canvas.bg_tex = MapData.poll_bg_texture()
	_canvas.cam_xz = _cam_xz
	_canvas.zoom = _zoom
	_canvas.pulse_t = _pulse_t
	_canvas.queue_redraw()


func _screen_to_world(screen_pt: Vector2) -> Vector2:
	return _cam_xz + (screen_pt - _canvas.size * 0.5) / maxf(_zoom, 0.001)


func _place_or_clear(world_xz: Vector2) -> void:
	if car == null:
		return
	var cw: Vector3 = Origin.to_world(car.global_position)
	GpsRoute.toggle(Vector2(cw.x, cw.z), world_xz)
	_sync_player()
	_canvas.queue_redraw()


func _place_or_clear_at_cursor() -> void:
	var mouse: Vector2 = _canvas.get_local_mouse_position()
	var pt: Vector2 = mouse if Rect2(Vector2.ZERO, _canvas.size).has_point(mouse) else _canvas.size * 0.5
	_place_or_clear(_screen_to_world(pt))


func _on_canvas_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_press_button = mb.button_index
				_press_pos = mb.position
				_dragging = false
			elif _press_button == mb.button_index:
				if mb.button_index == MOUSE_BUTTON_LEFT and not _dragging and mb.position.distance_to(_press_pos) < 6.0:
					_place_or_clear(_screen_to_world(mb.position))
				_press_button = -1
				_dragging = false
			_canvas.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.18)
			_canvas.accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / 1.18)
			_canvas.accept_event()
	elif event is InputEventMouseMotion and _press_button != -1:
		var mm := event as InputEventMouseMotion
		if not _dragging and mm.position.distance_to(_press_pos) >= 6.0:
			_dragging = true
		if _dragging:
			_cam_xz -= mm.relative / _zoom
			_clamp_cam()
			_canvas.cam_xz = _cam_xz
			_canvas.queue_redraw()
		_canvas.accept_event()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# Header bar
	var hdr_bg := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.075, 0.10, 0.96)
	sb.border_color = Color(1.0, 0.502, 0.0, 0.55)
	sb.border_width_bottom = 2
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	hdr_bg.add_theme_stylebox_override("panel", sb)
	root.add_child(hdr_bg)

	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 14)
	hdr_bg.add_child(hdr)

	var title := Label.new()
	title.text = "WORLD MAP  //  P1 DRIVE"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.502, 0.0))
	hdr.add_child(title)

	_loc_lbl = Label.new()
	_loc_lbl.text = "%.1f km Network" % RoadGraph.total_km()
	_loc_lbl.add_theme_font_size_override("font_size", 14)
	_loc_lbl.add_theme_color_override("font_color", Color(0.76, 0.80, 0.86))
	_loc_lbl.size_flags_horizontal = SIZE_EXPAND_FILL
	_loc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hdr.add_child(_loc_lbl)

	hdr.add_child(_make_btn("Center (Space)", func() -> void: _center_on_player(true)))
	hdr.add_child(_make_btn("Full View", func() -> void:
		_zoom = 0.0385
		_cam_xz = Vector2(-100.0, 200.0)
		_canvas.queue_redraw()
	))
	var close_b: Button = _make_btn("Close (M / Esc)", close_map)
	close_b.add_theme_color_override("font_color", Color(1.0, 0.56, 0.16))
	hdr.add_child(close_b)

	_canvas = _FullMapCanvas.new()
	_canvas.size_flags_vertical = SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = SIZE_EXPAND_FILL
	_canvas.clip_contents = true
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.gui_input.connect(_on_canvas_gui_input)
	root.add_child(_canvas)


func _make_btn(txt: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(118.0, 32.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.14, 0.17, 0.22, 0.95)
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	b.add_theme_stylebox_override("normal", sb)
	var sb_h := sb.duplicate() as StyleBoxFlat
	sb_h.bg_color = Color(0.22, 0.26, 0.34, 0.98)
	b.add_theme_stylebox_override("hover", sb_h)
	b.add_theme_stylebox_override("pressed", sb_h)
	b.pressed.connect(cb)
	return b


class _FullMapCanvas extends Control:
	var bg_tex: ImageTexture = null
	var cam_xz: Vector2 = Vector2.ZERO
	var zoom: float = 0.042
	var player_xz: Vector2 = Vector2.ZERO
	var player_heading: float = 0.0
	var pulse_t: float = 0.0

	func _world_to_screen(w: Vector2) -> Vector2:
		return size * 0.5 + (w - cam_xz) * zoom

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.045, 0.085, 0.135, 1.0), true)

		var half: Vector2 = size * 0.5
		var xf := Transform2D(0.0, half).scaled_local(Vector2(zoom, zoom)).translated_local(-cam_xz)
		draw_set_transform_matrix(xf)

		if bg_tex != null:
			draw_texture_rect(bg_tex, Rect2(MapData.WORLD_MIN, MapData.WORLD_MAX - MapData.WORLD_MIN), false, Color(1.0, 1.0, 1.0, 0.92))

		# Subtle 2 km coordinate grid
		var grid_col := Color(1.0, 1.0, 1.0, 0.05)
		var g_w: float = 1.0 / maxf(zoom, 0.01)
		for gx: int in range(-14000, 16000, 2000):
			draw_line(Vector2(float(gx), MapData.WORLD_MIN.y), Vector2(float(gx), MapData.WORLD_MAX.y), grid_col, g_w)
		for gz: int in range(-10000, 12000, 2000):
			draw_line(Vector2(MapData.WORLD_MIN.x, float(gz)), Vector2(MapData.WORLD_MAX.x, float(gz)), grid_col, g_w)

		var view_half_m: Vector2 = half / maxf(zoom, 0.005)
		var view_rect := Rect2(cam_xz - view_half_m, view_half_m * 2.0).grow(200.0)
		MapData.draw_river(self, zoom, view_rect)
		var polys: Array[PackedVector2Array] = MapData.edges_coarse if zoom < 0.18 else MapData.edges_fine
		var vis: PackedInt32Array = PackedInt32Array()
		for e: int in polys.size():
			if MapData.edge_rects[e].intersects(view_rect):
				vis.append(e)

		MapData.draw_roads(self, polys, vis, zoom, view_rect)
		if GpsRoute.active:
			GpsRoute.draw_world(self, zoom)

		draw_set_transform_matrix(Transform2D.IDENTITY)

		var font: Font = ThemeDB.fallback_font
		# Town markers (procedural world only: in OsmWorld, towns duplicates REGIONS)
		if not OsmWorld.enabled and zoom >= 0.030:
			for td: Dictionary in MapData.towns:
				var tp: Vector2 = _world_to_screen(td["pos"])
				if not Rect2(Vector2(-40.0, -40.0), size + Vector2(80.0, 80.0)).has_point(tp):
					continue
				draw_circle(tp, 5.0, Color(0.06, 0.075, 0.10, 0.95))
				draw_circle(tp, 3.2, Color(0.92, 0.95, 0.99, 0.95))
				if font != null and zoom >= 0.045:
					var tname: String = td["name"]
					draw_string(font, tp + Vector2(8.0, 4.0), tname, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.86, 0.90, 0.95, 0.90))

		# Petrol / POI markers when zoomed in
		if zoom >= 0.055:
			for poi: Dictionary in MapData.pois:
				var pp: Vector2 = _world_to_screen(poi["pos"])
				if not Rect2(Vector2(-20.0, -20.0), size + Vector2(40.0, 40.0)).has_point(pp):
					continue
				var col: Color = Color(1.0, 0.62, 0.20) if str(poi["kind"]) == "petrol" else Color(1.0, 0.36, 0.62)
				draw_circle(pp, 5.5, Color(0.05, 0.07, 0.10, 0.92))
				draw_arc(pp, 5.5, 0.0, TAU, 16, col, 1.3, true)
				draw_circle(pp, 2.2, col)

		# Region names (major first, with screen-space collision avoidance so badges never overlap)
		if font != null:
			var placed_boxes: Array[Rect2] = []
			for pass_major: bool in [true, false]:
				for reg: Dictionary in MapData.REGIONS:
					var major: bool = bool(reg["major"])
					if major != pass_major:
						continue
					var rp: Vector2 = _world_to_screen(reg["pos"])
					if not Rect2(Vector2(-120.0, -40.0), size + Vector2(240.0, 80.0)).has_point(rp):
						continue
					var rname: String = reg["name"]
					var fsize: int = 13 if major else 11
					var sz: Vector2 = font.get_string_size(rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
					var asc: float = font.get_ascent(fsize)
					var box := Rect2(rp.x - sz.x * 0.5 - 9.0, rp.y - asc * 0.5 - 5.0, sz.x + 18.0, asc + 10.0)
					var hit: bool = false
					for eb: Rect2 in placed_boxes:
						if box.grow(4.0).intersects(eb):
							hit = true
							break
					if hit:
						continue
					placed_boxes.append(box)
					if major:
						draw_rect(box, Color(0.05, 0.065, 0.095, 0.85), true)
						draw_rect(box, Color(1.0, 0.502, 0.0, 0.72), false, 1.2)
						draw_string(font, Vector2(rp.x - sz.x * 0.5, rp.y + asc * 0.36), rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.98, 0.98, 1.0, 0.98))
					else:
						draw_string(font, Vector2(rp.x - sz.x * 0.5 + 1.0, rp.y + asc * 0.36 + 1.0), rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.0, 0.0, 0.0, 0.72))
						draw_string(font, Vector2(rp.x - sz.x * 0.5, rp.y + asc * 0.36), rname, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.80, 0.87, 0.95, 0.82))

		# Player position + heading arrow
		var p_scr: Vector2 = _world_to_screen(player_xz)
		var pulse: float = fmod(pulse_t * 0.85, 1.0)
		draw_arc(p_scr, 11.0 + 14.0 * pulse, 0.0, TAU, 28, Color(1.0, 0.502, 0.0, (1.0 - pulse) * 0.75), 2.0, true)
		var p_outer := PackedVector2Array([
			Vector2(0.0, -13.0).rotated(player_heading) + p_scr,
			Vector2(9.5, 10.0).rotated(player_heading) + p_scr,
			Vector2(0.0, 5.2).rotated(player_heading) + p_scr,
			Vector2(-9.5, 10.0).rotated(player_heading) + p_scr,
		])
		var p_inner := PackedVector2Array([
			Vector2(0.0, -10.5).rotated(player_heading) + p_scr,
			Vector2(7.2, 8.0).rotated(player_heading) + p_scr,
			Vector2(0.0, 4.0).rotated(player_heading) + p_scr,
			Vector2(-7.2, 8.0).rotated(player_heading) + p_scr,
		])
		draw_colored_polygon(p_outer, Color(0.04, 0.05, 0.07, 0.98))
		draw_colored_polygon(p_inner, Color(1.0, 0.502, 0.0, 1.0))
		if font != null:
			draw_string(font, p_scr + Vector2(-12.0, 24.0), "YOU", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.72, 0.30, 0.95))

		if GpsRoute.active:
			var wp: Vector2 = _world_to_screen(GpsRoute.waypoint)
			if Rect2(Vector2(-30.0, -30.0), size + Vector2(60.0, 60.0)).has_point(wp):
				GpsRoute.draw_pin(self, wp)
				if font != null:
					var pin_txt: String = "NO ROUTE" if not GpsRoute.reachable else GpsRoute.format_dist(GpsRoute.remain_m)
					draw_string(font, wp + Vector2(14.0, 4.0), pin_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.55, 0.98, 1.0, 0.96))

		_draw_overlays(font)

	func _draw_overlays(font: Font) -> void:
		# Bottom-left legend + controls
		var leg_r := Rect2(16.0, size.y - 68.0, 760.0, 52.0)
		draw_rect(leg_r, Color(0.05, 0.065, 0.095, 0.84), true)
		draw_rect(leg_r, Color(0.28, 0.34, 0.42, 0.65), false, 1.0)
		if font != null:
			var items: Array = [
				["Highway", MapData.ROAD_FILL[RoadGraph.HIGHWAY]],
				["Country", MapData.ROAD_FILL[RoadGraph.COUNTRY]],
				["Mountain", MapData.ROAD_FILL[RoadGraph.MOUNTAIN]],
				["City", MapData.ROAD_FILL[RoadGraph.CITY]],
				["Rural", MapData.ROAD_FILL[RoadGraph.RURAL]],
				["Player", Color(1.0, 0.502, 0.0)],
			]
			var lx: float = 28.0
			var ly: float = size.y - 46.0
			for it: Array in items:
				draw_rect(Rect2(lx, ly - 5.0, 16.0, 5.0), it[1] as Color, true)
				draw_string(font, Vector2(lx + 22.0, ly + 2.0), str(it[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.90, 0.93, 0.97))
				lx += 96.0
			draw_string(font, Vector2(28.0, size.y - 24.0), "Drag / WASD: Pan   •   Scroll: Zoom   •   Click or F: Waypoint (again clears)   •   Space: Center   •   M / Esc: Close", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.68, 0.73, 0.80))

		# Bottom-right scale bar + compass
		var scale_choices: PackedFloat32Array = PackedFloat32Array([100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0])
		var bar_m: float = 1000.0
		for sm: float in scale_choices:
			if sm * zoom >= 70.0 and sm * zoom <= 180.0:
				bar_m = sm
				break
		var bar_px: float = clampf(bar_m * zoom, 50.0, 200.0)
		var bar_lbl: String = "%d km" % int(bar_m / 1000.0) if bar_m >= 1000.0 else "%d m" % int(bar_m)
		var box_r := Rect2(size.x - 240.0, size.y - 68.0, 224.0, 52.0)
		draw_rect(box_r, Color(0.05, 0.065, 0.095, 0.84), true)
		draw_rect(box_r, Color(0.28, 0.34, 0.42, 0.65), false, 1.0)
		var bx: float = size.x - 74.0 - bar_px
		var by: float = size.y - 34.0
		draw_line(Vector2(bx, by), Vector2(bx + bar_px, by), Color(0.92, 0.94, 0.98), 2.0)
		draw_line(Vector2(bx, by - 5.0), Vector2(bx, by + 3.0), Color(0.92, 0.94, 0.98), 2.0)
		draw_line(Vector2(bx + bar_px, by - 5.0), Vector2(bx + bar_px, by + 3.0), Color(0.92, 0.94, 0.98), 2.0)
		if font != null:
			draw_string(font, Vector2(bx, by - 9.0), bar_lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.88, 0.91, 0.95))

		var comp := Vector2(size.x - 42.0, size.y - 42.0)
		draw_circle(comp, 16.0, Color(0.09, 0.11, 0.15, 0.95))
		draw_arc(comp, 16.0, 0.0, TAU, 24, Color(1.0, 0.502, 0.0, 0.65), 1.5, true)
		var n_tri := PackedVector2Array([comp + Vector2(0.0, -11.0), comp + Vector2(4.5, 2.0), comp + Vector2(-4.5, 2.0)])
		draw_colored_polygon(n_tri, Color(1.0, 0.502, 0.0))
		if font != null:
			draw_string(font, comp + Vector2(-4.0, 12.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.92, 0.94, 0.98))
