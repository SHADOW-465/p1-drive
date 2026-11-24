class_name Minimap
extends Control
## H1: Forza-style rotating circular minimap. Roads/terrain are rendered north-up into a SubViewport
## at low Hz (only when the car drifts or the zoom changes); a rotation shader shows it every frame.
## The route (moving dashes), POIs, player arrow and compass are a light overlay clipped to the disc.

const BOX: float = 210.0
const RAD: float = 96.0
const PIVOT_OFF: float = 12.0
const R_MIN: float = 175.0  # view radius in metres at standstill
const R_MAX: float = 450.0  # ... at speed
const HALF_K: float = 1.6   # bake half-extent / bake view radius
const MIN_PX: Array[float] = [5.0, 3.6, 3.2, 3.6, 2.8, 3.0]  # design px, by road type
const FILL: Array[Color] = [
	Color(1.0, 0.9, 0.55, 1.0), Color(0.96, 0.97, 1.0, 1.0), Color(0.98, 0.84, 0.62, 1.0),
	Color(0.92, 0.95, 1.0, 1.0), Color(1.0, 0.8, 0.5, 1.0), Color(0.82, 0.88, 0.80, 1.0),
]
const CASE: Color = Color(0.02, 0.03, 0.05, 0.9)
const CYAN: Color = Color(0.22, 0.93, 1.0)

var car: Car
var u: float = 1.0

var _view: SubViewport
var _bake: _Bake
var _quad: ColorRect
var _mat: ShaderMaterial
var _over: _Overlay
var _radius_m: float = R_MIN
var _heading: float = 0.0
var _center_xz: Vector2 = Vector2.ZERO
var _region_name: String = ""
var _region_t: float = 0.0
var _disp_c: Vector2 = Vector2.ZERO  # bake params the shader may use (committed after the render)
var _disp_half: float = 1.0
var _disp_r: float = R_MIN
var _have_bake: bool = false
var _pending: Array = []
var _bake_age: float = 9.0
var _bg_in: bool = false
var _headless: bool = DisplayServer.get_name() == "headless"
var _last_sig: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	MapData.ensure_roads()
	MapData.start_bake_bg()
	if _headless:
		return  # no renderer: nothing to bake or show
	_view = SubViewport.new()
	_view.transparent_bg = true
	_view.disable_3d = true
	_view.msaa_2d = Viewport.MSAA_2X
	_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_bake = _Bake.new()
	_view.add_child(_bake)
	add_child(_view)
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/minimap.gdshader")
	_mat.set_shader_parameter("map_tex", _view.get_texture())
	_quad = ColorRect.new()
	_quad.material = _mat
	_quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_quad)
	_over = _Overlay.new()
	_over.map = self
	_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_over)
	set_ui_scale(u)


func set_ui_scale(s: float) -> void:
	u = s
	custom_minimum_size = Vector2(BOX, BOX) * u
	size = custom_minimum_size
	if _quad == null:
		return
	_quad.size = size
	_over.size = size
	_over.u = u
	var px: int = clampi(roundi(512.0 * u / 64.0) * 64, 512, 1024)
	_view.size = Vector2i(px, px)
	_mat.set_shader_parameter("aa", 1.0 / u)
	_have_bake = false
	_mat.set_shader_parameter("ready", 0.0)
	queue_redraw()
	_over.queue_redraw()


func _draw() -> void:
	# soft drop shadow under the disc (static, drawn once)
	var c: Vector2 = size * 0.5
	for i: int in 7:
		draw_circle(c + Vector2(0.0, 4.0 * u), (RAD + 1.0 + i * 1.6) * u, Color(0.0, 0.0, 0.0, 0.055))


func _process(dt: float) -> void:
	if _headless:
		MapData.poll_bg_texture()
	if not visible or car == null or _headless:
		return
	var car_w: Vector3 = Origin.to_world(car.global_position)
	_center_xz = Vector2(car_w.x, car_w.z)
	var fwd: Vector3 = -car.global_basis.z
	if fwd.x * fwd.x + fwd.z * fwd.z > 1e-4:
		var target_h: float = atan2(fwd.x, -fwd.z)
		_heading = target_h if dt <= 0.0 else lerp_angle(_heading, target_h, 1.0 - exp(-18.0 * dt))
	var t_spd: float = clampf((car.speed_kmh - 30.0) / 250.0, 0.0, 1.0)
	var target_r: float = lerpf(R_MIN, R_MAX, t_spd)
	_radius_m = target_r if dt <= 0.0 else lerpf(_radius_m, target_r, 1.0 - exp(-3.5 * dt))
	_region_t -= dt
	if _region_t <= 0.0:
		_region_t = 0.35
		_region_name = MapData.nearest_region_name(_center_xz)
	_bake_age += dt
	var bg_late: bool = not _bg_in and MapData.poll_bg_texture() != null
	var drift: float = _center_xz.distance_to(_disp_c)
	var ratio: float = _radius_m / _disp_r
	if _pending.is_empty() and (not _have_bake or bg_late or (_bake_age > 0.4 and (drift > 0.27 * _disp_r or ratio < 0.72 or ratio > 1.28))):
		_start_bake((_radius_m + target_r) * 0.5)
	if _have_bake:
		_mat.set_shader_parameter("heading", _heading)
		_mat.set_shader_parameter("uv_center", Vector2(0.5, 0.5) + (_center_xz - _disp_c) / (2.0 * _disp_half))
		_mat.set_shader_parameter("uv_per_px", (_radius_m / RAD) / (2.0 * _disp_half))
	# the overlay only redraws when something it shows moved (the route animates, so it always does)
	var steer: float = car.steering
	var sig: PackedFloat32Array = PackedFloat32Array([_heading, _center_xz.x, _center_xz.y, _radius_m, steer, car.speed_kmh])
	if sig != _last_sig or GpsRoute.active or _over.region != _region_name:
		_last_sig = sig
		_over.heading = _heading
		_over.center_xz = _center_xz
		_over.radius_m = _radius_m
		_over.steer = steer
		_over.region = _region_name
		_over.queue_redraw()


func _start_bake(view_r: float) -> void:
	var tex: ImageTexture = MapData.poll_bg_texture()
	_bg_in = tex != null
	_bake.setup(_center_xz, view_r, view_r * HALF_K, _view.size.x, tex)
	_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_pending = [_center_xz, view_r, view_r * HALF_K, 0]
	_bake_age = 0.0
	RenderingServer.frame_post_draw.connect(_on_post_draw)


# Commit the new bake params only once its render finished, so the map never jumps for a frame.
func _on_post_draw() -> void:
	if _pending.is_empty():
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
		return
	_pending[3] += 1
	if _pending[3] < 2:
		return
	_disp_c = _pending[0]
	_disp_r = _pending[1]
	_disp_half = _pending[2]
	_pending = []
	_have_bake = true
	_mat.set_shader_parameter("ready", 1.0)
	RenderingServer.frame_post_draw.disconnect(_on_post_draw)


## North-up render of terrain, river and roads around the bake centre.
class _Bake extends Control:
	var center: Vector2 = Vector2.ZERO
	var view_r: float = Minimap.R_MIN
	var half: float = 300.0
	var px: int = 512
	var bg_tex: ImageTexture = null

	func setup(c: Vector2, vr: float, h: float, pixels: int, tex: ImageTexture) -> void:
		center = c
		view_r = vr
		half = h
		px = pixels
		bg_tex = tex
		size = Vector2(px, px)
		queue_redraw()

	func _draw() -> void:
		var ppm: float = float(px) / (2.0 * half)
		var xf := Transform2D(0.0, Vector2(ppm, ppm), 0.0, Vector2(px * 0.5, px * 0.5)).translated_local(-center)
		draw_set_transform_matrix(xf)
		var q_rect := Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0)
		if bg_tex != null:
			draw_texture_rect(bg_tex, Rect2(MapData.WORLD_MIN, MapData.WORLD_MAX - MapData.WORLD_MIN), false, Color(1.5, 1.55, 1.6, 1.0))  # lighter land so roads and water read against the backdrop
		MapData.draw_river(self, ppm, q_rect)
		for td: Dictionary in MapData.towns:  # town patch: soft pale disc under the roads
			var tp: Vector2 = td["pos"]
			if q_rect.grow(260.0).has_point(tp):
				draw_circle(tp, 190.0, Color(0.85, 0.78, 0.62, 0.45))
		var m_per_px: float = view_r / Minimap.RAD  # metres per design px
		var vis: PackedInt32Array = PackedInt32Array()
		for e: int in MapData.edges_fine.size():
			if MapData.edge_rects[e].intersects(q_rect):
				vis.append(e)
		var case_extra: float = 2.4 * m_per_px
		var batch: Dictionary = {}  # batched like MapData.draw_roads: one canvas command per colour / width step
		for e: int in vis:
			var t: int = MapData.edge_types[e]
			var w: float = maxf(RoadGraph.WIDTH[t] * 1.05, Minimap.MIN_PX[t] * m_per_px)
			MapData._batch_add(batch, MapData.edges_fine[e], Minimap.CASE, w + case_extra)
		MapData._batch_draw(self, batch)
		for t_ord: int in MapData.DRAW_ORDER:
			for e: int in vis:
				if MapData.edge_types[e] != t_ord:
					continue
				var ek: int = MapData.edge_kinds[e] if e < MapData.edge_kinds.size() else RoadGraph.KIND_ROAD
				var col: Color = Minimap.FILL[t_ord]
				if ek == RoadGraph.KIND_TUNNEL:
					col = col.darkened(0.45)
				var w2: float = maxf(RoadGraph.WIDTH[t_ord] * 0.95, Minimap.MIN_PX[t_ord] * m_per_px)
				MapData._batch_add(batch, MapData.edges_fine[e], col, w2)
			MapData._batch_draw(self, batch)
		for rb: Dictionary in MapData.roundabouts:
			var rp: Vector2 = rb["pos"]
			if not q_rect.grow(60.0).has_point(rp):
				continue
			var rr: float = float(rb["r"])
			var rw: float = maxf(9.0, Minimap.MIN_PX[RoadGraph.COUNTRY] * m_per_px)
			draw_arc(rp, rr, 0.0, TAU, 28, Minimap.CASE, rw + case_extra, true)
			draw_arc(rp, rr, 0.0, TAU, 28, Minimap.FILL[RoadGraph.COUNTRY], rw, true)


class _Overlay extends Control:
	var map: Minimap
	var u: float = 1.0
	var heading: float = 0.0
	var center_xz: Vector2 = Vector2.ZERO
	var radius_m: float = Minimap.R_MIN
	var steer: float = 0.0
	var region: String = ""
	var _card: StyleBoxFlat

	func _init() -> void:
		_card = StyleBoxFlat.new()
		_card.bg_color = Color(0.03, 0.05, 0.08, 0.78)
		_card.set_corner_radius_all(9)
		_card.set_border_width_all(1)
		_card.border_color = Color(0.22, 0.93, 1.0, 0.55)
		_card.anti_aliasing = true
		_card.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
		_card.shadow_size = 5

	func _to_screen(w: Vector2, s: float) -> Vector2:
		return Vector2(0.0, Minimap.PIVOT_OFF) + Vector2(Minimap.BOX, Minimap.BOX) * 0.5 + (w - center_xz).rotated(-heading) * s

	func _draw() -> void:
		var c: Vector2 = Vector2(Minimap.BOX, Minimap.BOX) * 0.5
		var pv: Vector2 = c + Vector2(0.0, Minimap.PIVOT_OFF)
		var s: float = Minimap.RAD / maxf(radius_m, 10.0)  # design px per metre
		var t: float = Time.get_ticks_msec() * 0.001
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(u, u))
		var route_on: bool = GpsRoute.active and GpsRoute.reachable and GpsRoute.route_pts.size() > 1
		if route_on:
			_draw_route(c, s, t)
		if GpsRoute.active:
			var wp: Vector2 = _to_screen(GpsRoute.waypoint, s)
			var off: Vector2 = wp - c
			if off.length() < Minimap.RAD - 12.0:
				GpsRoute.draw_pin(self, wp)
			else:
				var rim: Vector2 = c + off.normalized() * (Minimap.RAD - 6.0)
				var d: Vector2 = off.normalized()
				var n: Vector2 = Vector2(-d.y, d.x)
				draw_colored_polygon(PackedVector2Array([rim + d * 6.0, rim - d * 4.0 + n * 5.0, rim - d * 4.0 - n * 5.0]), Color(Minimap.CYAN, 0.95))
		_draw_pois(c, s)
		# heading cone, leaning with the steering
		var lean: float = clampf(-steer * 0.7, -0.5, 0.5)
		var cone := PackedVector2Array([pv, pv + Vector2(0.0, -64.0).rotated(lean - 0.42), pv + Vector2(0.0, -64.0).rotated(lean + 0.42)])
		draw_polygon(cone, PackedColorArray([Color(1, 1, 1, 0.32), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)]))
		# player arrow
		var arrow := PackedVector2Array([Vector2(0.0, -11.5), Vector2(8.0, 9.0), Vector2(0.0, 4.6), Vector2(-8.0, 9.0)])
		var glow := PackedVector2Array()
		var shadow := PackedVector2Array()
		for p: Vector2 in arrow:
			glow.append(pv + p * 1.5)
			shadow.append(pv + p + Vector2(0.0, 2.0))
		draw_colored_polygon(glow, Color(1, 1, 1, 0.14))
		draw_colored_polygon(shadow, Color(0, 0, 0, 0.45))
		var abs_pts := PackedVector2Array()
		for p: Vector2 in arrow:
			abs_pts.append(pv + p)
		draw_colored_polygon(abs_pts, Color(1, 1, 1, 1))
		draw_polyline(PackedVector2Array([abs_pts[0], abs_pts[1], abs_pts[2], abs_pts[3], abs_pts[0]]), Color(0.04, 0.06, 0.09, 0.7), 1.0, true)
		# rim: inner shade, thin bright ring, outer glow
		draw_arc(c, Minimap.RAD - 3.0, 0.0, TAU, 96, Color(0, 0, 0, 0.22), 6.0, true)
		draw_arc(c, Minimap.RAD + 2.2, 0.0, TAU, 96, Color(1, 1, 1, 0.07), 4.0, true)
		draw_arc(c, Minimap.RAD + 0.6, 0.0, TAU, 96, Color(1, 1, 1, 0.20), 2.4, true)
		draw_arc(c, Minimap.RAD - 0.2, 0.0, TAU, 96, Color(1, 1, 1, 0.78), 1.4, true)
		# compass N on the rim
		var n_pos: Vector2 = c + Vector2(0.0, -(Minimap.RAD - 0.5)).rotated(-heading)
		draw_circle(n_pos + Vector2(0.0, 1.5), 10.0, Color(0, 0, 0, 0.35))
		draw_circle(n_pos, 9.0, Color(0.05, 0.07, 0.10, 0.95))
		draw_arc(n_pos, 9.0, 0.0, TAU, 24, Color(1.0, 0.35, 0.45, 0.95), 1.4, true)
		# destination readout pill
		var dist_txt: String = ""
		if route_on:
			dist_txt = GpsRoute.format_dist(GpsRoute.remain_m)
			var tw: float = Speedo.F_TXT.get_string_size(dist_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, roundi(13.0 * u)).x / u
			var pw: float = tw + 32.0
			draw_style_box(_card, Rect2(c.x - pw * 0.5, c.y + Minimap.RAD - 11.0, pw, 20.0))
			var fx: Vector2 = Vector2(c.x - pw * 0.5 + 10.0, c.y + Minimap.RAD - 6.0)
			draw_line(fx, fx + Vector2(0.0, 11.0), Color(Minimap.CYAN, 0.95), 1.3, true)
			draw_colored_polygon(PackedVector2Array([fx, fx + Vector2(7.0, 2.5), fx + Vector2(0.0, 5.5)]), Color(Minimap.CYAN, 0.95))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# text
		var ns: int = roundi(11.0 * u)
		Speedo.shadow_text(self, Speedo.F_NUM, "N", n_pos * u + Vector2(-10.0 * u, 0.35 * ns), 20.0 * u, ns, Color(1.0, 0.45, 0.52), u)
		if region != "":
			var rs: int = roundi(11.0 * u)
			Speedo.shadow_text(self, Speedo.F_TXT, region.to_upper(), (c + Vector2(-60.0, -Minimap.RAD * 0.62)) * u + Vector2(0.0, 0.35 * rs), 120.0 * u, rs, Color(1, 1, 1, 0.72), u)
		if dist_txt != "":
			var ds: int = roundi(13.0 * u)
			var tw2: float = Speedo.F_TXT.get_string_size(dist_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, ds).x
			var pw2: float = tw2 / u + 32.0
			draw_string(Speedo.F_TXT, Vector2((c.x - pw2 * 0.5 + 21.0) * u, (c.y + Minimap.RAD - 1.0) * u + 0.35 * ds), dist_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, ds, Color(0.93, 0.98, 1.0))

	func _draw_route(c: Vector2, s: float, t: float) -> void:
		var pts: PackedVector2Array = GpsRoute.route_pts
		var cum: PackedFloat32Array = GpsRoute._cum
		var prog: int = clampi(GpsRoute._prog, 0, pts.size() - 2)
		var span: float = radius_m * 1.5
		var i0: int = prog
		while i0 > 0 and cum[prog] - cum[i0] < span:
			i0 -= 1
		var i1: int = prog + 1
		while i1 < pts.size() - 1 and cum[i1] - cum[prog] < span:
			i1 += 1
		var scr := PackedVector2Array()
		for i: int in range(i0, i1 + 1):
			scr.append(_to_screen(pts[i], s))
		var lim: float = Minimap.RAD - 1.0
		var runs: Array[PackedVector2Array] = _clip(scr, c, lim)
		for r: PackedVector2Array in runs:
			draw_polyline(r, Color(0.0, 0.03, 0.05, 0.85), 7.4, true)
		for r: PackedVector2Array in runs:
			draw_polyline(r, Color(Minimap.CYAN, 0.20), 8.5, true)
			draw_polyline(r, Color(Minimap.CYAN, 0.95), 4.2, true)
		# marching dashes: world-anchored phase so they flow toward the destination
		var period: float = 38.0
		var dash: float = 11.0
		var phase: float = fmod(cum[i0] * s - t * 46.0, period)
		if phase < 0.0:
			phase += period
		var acc: float = -phase
		for i: int in scr.size() - 1:
			var a: Vector2 = scr[i]
			var b: Vector2 = scr[i + 1]
			var seg: float = a.distance_to(b)
			if seg < 0.001:
				continue
			var s0: float = acc
			var s1: float = acc + seg
			acc = s1
			var k: float = floorf(s0 / period)
			while k * period < s1:
				var d0: float = maxf(k * period, s0)
				var d1: float = minf(k * period + dash, s1)
				if d1 > d0 and k * period + dash > s0:
					var p0: Vector2 = a.lerp(b, (d0 - s0) / seg)
					var p1: Vector2 = a.lerp(b, (d1 - s0) / seg)
					if p0.distance_to(c) < lim and p1.distance_to(c) < lim:
						draw_line(p0, p1, Color(0.85, 1.0, 1.0, 0.95), 2.2, true)
				k += 1.0

	## Clip a polyline (screen space) to a disc; returns the pieces inside it.
	func _clip(pts: PackedVector2Array, c: Vector2, r: float) -> Array[PackedVector2Array]:
		var runs: Array[PackedVector2Array] = []
		var cur := PackedVector2Array()
		var r2: float = r * r
		for i: int in pts.size() - 1:
			var a: Vector2 = pts[i]
			var d: Vector2 = pts[i + 1] - a
			var f: Vector2 = a - c
			var qa: float = d.dot(d)
			var t0: float = 0.0
			var t1: float = 1.0
			if f.length_squared() > r2 or (a + d - c).length_squared() > r2:
				var qb: float = 2.0 * f.dot(d)
				var disc: float = qb * qb - 4.0 * qa * (f.dot(f) - r2)
				if qa < 1e-9 or disc <= 0.0:
					if cur.size() > 1:
						runs.append(cur)
					cur = PackedVector2Array()
					continue
				var sq: float = sqrt(disc)
				t0 = clampf((-qb - sq) / (2.0 * qa), 0.0, 1.0)
				t1 = clampf((-qb + sq) / (2.0 * qa), 0.0, 1.0)
				if t1 - t0 < 1e-4:
					if cur.size() > 1:
						runs.append(cur)
					cur = PackedVector2Array()
					continue
			var p0: Vector2 = a + d * t0
			if cur.size() > 0 and cur[cur.size() - 1].distance_squared_to(p0) > 0.04:
				if cur.size() > 1:
					runs.append(cur)
				cur = PackedVector2Array()
			if cur.is_empty():
				cur.append(p0)
			cur.append(a + d * t1)
			if t1 < 1.0:
				runs.append(cur)
				cur = PackedVector2Array()
		if cur.size() > 1:
			runs.append(cur)
		return runs

	func _draw_pois(c: Vector2, s: float) -> void:
		for p: Dictionary in MapData.pois:
			var wp: Vector2 = p["pos"]
			if absf(wp.x - center_xz.x) > 1800.0 or absf(wp.y - center_xz.y) > 1800.0:
				continue
			var sp: Vector2 = _to_screen(wp, s)
			var off: Vector2 = sp - c
			var inside: bool = off.length() < Minimap.RAD - 10.0
			var kind: String = p["kind"]
			var col: Color = Color(1.0, 0.62, 0.20) if kind == "petrol" else Color(1.0, 0.36, 0.62)
			if not inside:
				var rim: Vector2 = c + off.normalized() * (Minimap.RAD - 4.5)
				draw_circle(rim, 3.2, Color(col, 0.85))
				continue
			draw_circle(sp + Vector2(0.0, 1.5), 8.0, Color(0, 0, 0, 0.35))
			draw_circle(sp, 7.5, Color(0.04, 0.06, 0.09, 0.92))
			draw_arc(sp, 7.5, 0.0, TAU, 20, Color(col, 0.95), 1.3, true)
			if kind == "petrol":
				draw_rect(Rect2(sp + Vector2(-3.0, -3.6), Vector2(4.2, 7.0)), col)
				draw_line(sp + Vector2(1.2, -1.5), sp + Vector2(3.4, -1.5), col, 1.1, true)
				draw_line(sp + Vector2(3.4, -1.5), sp + Vector2(3.4, 2.4), col, 1.1, true)
			else:
				draw_line(sp + Vector2(-2.6, -4.0), sp + Vector2(-2.6, 4.2), col, 1.2, true)
				draw_colored_polygon(PackedVector2Array([sp + Vector2(-2.6, -4.0), sp + Vector2(3.8, -2.0), sp + Vector2(-2.6, 0.2)]), col)
