class_name MapData
extends RefCounted
## Shared road-network simplification, region labels, and background topographic
## map texture baker for Minimap and FullMap (R6).

static var WORLD_MIN: Vector2 = Vector2(-16800.0, -16800.0) if OsmWorld.enabled else Vector2(-18000.0, -10200.0)
static var WORLD_MAX: Vector2 = Vector2(16800.0, 16800.0) if OsmWorld.enabled else Vector2(18000.0, 10200.0)
static var TEX_W: int = 640
static var TEX_H: int = 640 if OsmWorld.enabled else 362

const TOWN_NAMES: PackedStringArray = ["Westgate", "Mirrorbrook", "Redrock", "Bayview", "Eastvale"]

static var REGIONS: Array[Dictionary] = _osm_regions() if OsmWorld.enabled else _old_regions()


static func _osm_regions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for l: Dictionary in OsmWorld.meta.get("labels", []):
		out.append({"name": str(l["name"]), "pos": Vector2(float(l["pos"][0]), float(l["pos"][1])), "major": bool(l.get("major", false))})
	return out


static func _old_regions() -> Array[Dictionary]:
	return [
	{"name": "DOWNTOWN CITY", "pos": Vector2(5632.0, 5632.0), "major": true},
	{"name": "HILL PASS", "pos": Vector2(-1608.0, -5550.0), "major": true},
	{"name": "COAST", "pos": Vector2(1600.0, 8150.0), "major": true},
	{"name": "NORTHWEST PEAKS", "pos": Vector2(-5200.0, -7600.0), "major": false},
	{"name": "NORTHEAST PEAKS", "pos": Vector2(5400.0, -7000.0), "major": false},
	{"name": "REDWOOD FOREST", "pos": Vector2(-5600.0, -3100.0), "major": false},
	{"name": "MIRROR LAKE", "pos": Vector2(-5600.0, -1450.0), "major": false},
	{"name": "SUNBAKED DESERT", "pos": Vector2(-6900.0, 5150.0), "major": false},
	{"name": "CENTRAL HILLS", "pos": Vector2(1400.0, -3400.0), "major": false},
	{"name": "EAST HIGHLANDS", "pos": Vector2(7600.0, -1800.0), "major": false},
	{"name": "COUNTRYSIDE", "pos": Vector2(1000.0, 2200.0), "major": false},
	{"name": "OPEN SEA", "pos": Vector2(1600.0, 9300.0), "major": false},
	]

# Road palette: [casing_color, fill_color]
const ROAD_FILL: Array[Color] = [
	Color(0.98, 0.76, 0.34, 1.0),  # HIGHWAY: warm amber-gold
	Color(0.86, 0.88, 0.90, 1.0),  # COUNTRY: crisp off-white
	Color(0.84, 0.65, 0.46, 1.0),  # MOUNTAIN: warm tan
	Color(0.74, 0.80, 0.88, 1.0),  # CITY: cool light slate
	Color(0.90, 0.62, 0.24, 1.0),  # RAMP: warm muted amber
	Color(0.66, 0.72, 0.65, 1.0),  # RURAL: soft sage-grey
]
const ROAD_CASE: Color = Color(0.05, 0.07, 0.10, 0.92)
const DRAW_ORDER: PackedInt32Array = [5, 2, 1, 3, 4, 0]  # RURAL -> MTN -> COUNTRY -> CITY -> RAMP -> HIGHWAY

static var edges_fine: Array[PackedVector2Array] = []
static var edges_coarse: Array[PackedVector2Array] = []
static var edge_rects: Array[Rect2] = []
static var edge_types: PackedInt32Array = PackedInt32Array()
static var edge_elev: PackedByteArray = PackedByteArray()
static var edge_kinds: PackedInt32Array = PackedInt32Array()
static var roundabouts: Array[Dictionary] = []
static var river_pts: PackedVector2Array = PackedVector2Array()
static var river_widths: PackedFloat32Array = PackedFloat32Array()
static var towns: Array[Dictionary] = []
## Map-only markers (no in-world object yet): an event site at each town and a petrol station beside it.
static var pois: Array[Dictionary] = []

static var _roads_ready: bool = false
static var _bg_started: bool = false
static var _bg_task_id: int = -1
static var _bg_mutex: Mutex = Mutex.new()
static var _bg_bytes: PackedByteArray = PackedByteArray()
static var _bg_tex: ImageTexture = null


static func ensure_roads() -> void:
	if _roads_ready:
		return
	_roads_ready = true
	var n_edges: int = RoadGraph.e_pts.size()
	edges_fine.resize(n_edges)
	edges_coarse.resize(n_edges)
	edge_rects.resize(n_edges)
	edge_types = RoadGraph.e_type.duplicate()
	edge_elev = RoadGraph.e_elev.duplicate()
	edge_kinds = RoadGraph.e_kind.duplicate()
	for e: int in n_edges:
		var pts3: PackedVector3Array = RoadGraph.e_pts[e]
		var fine: PackedVector2Array = _simplify_xz(pts3, 12.0, 0.992)
		var coarse: PackedVector2Array = _simplify_xz(pts3, 32.0, 0.980)
		edges_fine[e] = fine
		edges_coarse[e] = coarse
		edge_rects[e] = _calc_rect(fine)

	roundabouts.clear()
	for nid: int in RoadGraph.nodes.size():
		if RoadGraph.node_kind[nid] == RoadGraph.NODE_ROUNDABOUT:
			var np: Vector3 = RoadGraph.nodes[nid]
			roundabouts.append({"pos": Vector2(np.x, np.z), "r": RoadGraph.node_radius[nid]})

	river_pts = PackedVector2Array()
	river_widths = PackedFloat32Array()
	for i: int in TerrainFn._river_pts.size():
		var rp: Vector3 = TerrainFn._river_pts[i]
		river_pts.append(Vector2(rp.x, rp.z))
		var u: float = TerrainFn._river_u[i] if i < TerrainFn._river_u.size() else 0.0
		river_widths.append(lerpf(32.0, 112.0, smoothstep(0.0, 1.0, u)))

	towns.clear()
	pois.clear()
	if OsmWorld.enabled:
		for l: Dictionary in OsmWorld.meta.get("labels", []):
			towns.append({"name": str(l["name"]), "pos": Vector2(float(l["pos"][0]), float(l["pos"][1]))})
		for p: Dictionary in OsmWorld.meta.get("petrol", []):
			var pos: Array = p["pos"]
			pois.append({"kind": "petrol", "pos": Vector2(float(pos[0]), float(pos[2]))})
	else:
		var raw_towns: Array = TerrainFn.def.get("towns", [])
		for i: int in raw_towns.size():
			var t: Array = raw_towns[i]
			var tname: String = TOWN_NAMES[i] if i < TOWN_NAMES.size() else "Town %d" % (i + 1)
			towns.append({"name": tname, "pos": Vector2(float(t[0]), float(t[1]))})
		for td: Dictionary in towns:
			var tp: Vector2 = td["pos"]
			pois.append({"kind": "event", "pos": tp})
			pois.append({"kind": "petrol", "pos": tp + Vector2(190.0, 120.0)})


static func draw_river(ci: CanvasItem, px_per_m: float, vis_rect: Rect2) -> void:
	if river_pts.size() < 2:
		return
	var step: int = 3 if px_per_m < 0.08 else 1
	var col := Color(0.20, 0.55, 0.90, 0.95)
	var i: int = 0
	while i < river_pts.size() - 1:
		var i2: int = mini(i + step, river_pts.size() - 1)
		var a: Vector2 = river_pts[i]
		var b: Vector2 = river_pts[i2]
		if vis_rect.grow(350.0).has_point(a) or vis_rect.grow(350.0).has_point(b):
			var w: float = maxf(river_widths[i], 2.2 / px_per_m)
			ci.draw_line(a, b, col, w, true)
		i = i2


## Roads are batched into one multiline per colour and width step: one canvas polyline per edge is ~4500 draw
## commands on the 2200-edge OSM map, each with its own GPU buffer, past the Vulkan allocation limit (VkResult -10).
static func draw_roads(ci: CanvasItem, polys: Array[PackedVector2Array], vis: PackedInt32Array, px_per_m: float, vis_rect: Rect2) -> void:
	var min_px: PackedFloat32Array = PackedFloat32Array([4.0, 2.4, 2.1, 2.8, 1.8, 1.4])
	# Pass 1: road dark casing (elevated bridges/overpasses use slightly stronger steel deck casing)
	var batch: Dictionary = {}
	for e: int in vis:
		var t: int = edge_types[e]
		var ek: int = edge_kinds[e] if e < edge_kinds.size() else RoadGraph.KIND_ROAD
		var paved: float = RoadGraph.e_width[e] if e < RoadGraph.e_width.size() else RoadGraph.WIDTH[t]
		var w_fill: float = maxf(paved * 1.05, min_px[t] / px_per_m)
		var case_c: Color = ROAD_CASE if ek != RoadGraph.KIND_BRIDGE and ek != RoadGraph.KIND_OVERPASS else Color(0.02, 0.04, 0.08, 0.96)
		_batch_add(batch, polys[e], case_c, w_fill + 2.4 / px_per_m)
	_batch_draw(ci, batch)

	# Pass 2: road fill ordered by hierarchy (rural up to highway)
	for t_ord: int in DRAW_ORDER:
		for e: int in vis:
			if edge_types[e] != t_ord:
				continue
			var ek: int = edge_kinds[e] if e < edge_kinds.size() else RoadGraph.KIND_ROAD
			var paved_f: float = RoadGraph.e_width[e] if e < RoadGraph.e_width.size() else RoadGraph.WIDTH[t_ord]
			var w: float = maxf(paved_f * 0.95, min_px[t_ord] / px_per_m)
			var col: Color = ROAD_FILL[t_ord]
			if ek == RoadGraph.KIND_TUNNEL:
				col = col.darkened(0.42)
			elif ek == RoadGraph.KIND_BRIDGE or ek == RoadGraph.KIND_OVERPASS:
				col = col.lerp(Color(0.98, 0.99, 1.0), 0.25)
			_batch_add(batch, polys[e], col, w)
			if t_ord == RoadGraph.HIGHWAY and px_per_m >= 0.09:
				_batch_add(batch, polys[e], Color(0.18, 0.14, 0.08, 0.55), maxf(1.4, 1.0 / px_per_m))
		_batch_draw(ci, batch)

	# Roundabout ring glyphs
	for rb: Dictionary in roundabouts:
		var rp: Vector2 = rb["pos"]
		if not vis_rect.grow(100.0).has_point(rp):
			continue
		var r_m: float = float(rb["r"])
		var rw: float = maxf(9.0, 2.4 / px_per_m)
		ci.draw_circle(rp, r_m, ROAD_CASE)
		ci.draw_arc(rp, r_m, 0.0, TAU, 28, ROAD_CASE, rw + 2.4 / px_per_m, true)
		ci.draw_arc(rp, r_m, 0.0, TAU, 28, ROAD_FILL[RoadGraph.COUNTRY], rw, true)
		ci.draw_circle(rp, maxf(r_m - rw * 0.55, 2.0), Color(0.11, 0.18, 0.12, 0.92))


## Width steps of ~6 %: invisible on the map, and few enough buckets to stay a handful of draw commands.
static func _batch_add(batch: Dictionary, poly: PackedVector2Array, col: Color, w: float) -> void:
	if poly.size() < 2:
		return
	var key: String = "%s|%d" % [col.to_html(), roundi(log(maxf(w, 0.01)) * 16.0)]
	if not batch.has(key):
		batch[key] = [col, w, PackedVector2Array()]
	var segs: PackedVector2Array = batch[key][2]
	for i: int in range(1, poly.size()):
		segs.append(poly[i - 1])
		segs.append(poly[i])
	batch[key][2] = segs


## Draws and empties the batch (segment joints are unmitred; at map scale the simplified bends hide it).
static func _batch_draw(ci: CanvasItem, batch: Dictionary) -> void:
	for key: String in batch:
		var b: Array = batch[key]
		ci.draw_multiline(b[2], b[0], b[1], true)
	batch.clear()


static func _simplify_xz(pts3: PackedVector3Array, max_step: float, cos_thresh: float) -> PackedVector2Array:
	var n: int = pts3.size()
	var out := PackedVector2Array()
	if n == 0:
		return out
	var p0 := Vector2(pts3[0].x, pts3[0].z)
	out.append(p0)
	if n == 1:
		return out
	var last_kept: Vector2 = p0
	var last_dir: Vector2 = (Vector2(pts3[1].x, pts3[1].z) - p0).normalized()
	for i: int in range(1, n - 1):
		var cur := Vector2(pts3[i].x, pts3[i].z)
		var nxt := Vector2(pts3[i + 1].x, pts3[i + 1].z)
		var d_nxt: Vector2 = (nxt - cur)
		var dist_kept: float = cur.distance_to(last_kept)
		var turn: bool = false
		if d_nxt.length_squared() > 1e-4:
			var dir: Vector2 = d_nxt.normalized()
			if last_dir.dot(dir) < cos_thresh:
				turn = true
				last_dir = dir
		if dist_kept >= max_step or (turn and dist_kept >= 6.0):
			out.append(cur)
			last_kept = cur
			if d_nxt.length_squared() > 1e-4:
				last_dir = d_nxt.normalized()
	out.append(Vector2(pts3[n - 1].x, pts3[n - 1].z))
	return out


static func _calc_rect(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var lo: Vector2 = pts[0]
	var hi: Vector2 = pts[0]
	for i: int in range(1, pts.size()):
		var p: Vector2 = pts[i]
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.y)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.y)
	return Rect2(lo, hi - lo).grow(24.0)


static func nearest_region_name(xz: Vector2) -> String:
	if OsmWorld.enabled:
		var best: String = "Horizon Triland"
		var best_d: float = 1.0e12
		for l: Dictionary in OsmWorld.meta.get("labels", []):
			var p: Array = l["pos"]
			var d: float = xz.distance_squared_to(Vector2(float(p[0]), float(p[1])))
			if d < best_d:
				best_d = d
				best = str(l["name"])
		return best
	if xz.x >= 5050.0 and xz.x <= 6250.0 and xz.y >= 4900.0 and xz.y <= 6250.0:
		return "Downtown City"
	if xz.x >= -2100.0 and xz.x <= -1000.0 and xz.y >= -6300.0 and xz.y <= -4800.0:
		return "Hill Pass"
	if xz.y >= 7500.0:
		return "Southern Coast"
	var w: PackedFloat32Array = TerrainFn.biome_weights(xz.x, xz.y)
	if w[TerrainFn.MOUNTAIN] > 0.35:
		return "Northwest Peaks" if xz.x < 1000.0 else "Northeast Peaks"
	if w[TerrainFn.FOREST] > 0.35:
		return "Mirror Lake" if TerrainFn.lake_signed_dist(xz.x, xz.y) < 350.0 else "Redwood Forest"
	if w[TerrainFn.DESERT] > 0.35:
		return "Sunbaked Desert"
	if w[TerrainFn.HILLS] > 0.35:
		return "East Highlands" if xz.x > 5000.0 else ("West Highlands" if xz.x < -2500.0 else "Central Hills")
	if w[TerrainFn.CITY] > 0.30:
		return "City Outskirts"
	return "Countryside"


static func start_bake_bg() -> void:
	if _bg_tex != null or _bg_started:
		return
	_bg_started = true
	_bg_task_id = WorkerThreadPool.add_task(_bake_worker)


static func poll_bg_texture() -> ImageTexture:
	if _bg_tex != null:
		return _bg_tex
	if not _bg_started:
		start_bake_bg()
	if _bg_task_id >= 0 and WorkerThreadPool.is_task_completed(_bg_task_id):
		WorkerThreadPool.wait_for_task_completion(_bg_task_id)
		_bg_task_id = -1
		_bg_mutex.lock()
		var bytes: PackedByteArray = _bg_bytes
		_bg_bytes = PackedByteArray()
		_bg_mutex.unlock()
		if bytes.size() == TEX_W * TEX_H * 3:
			var img := Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGB8, bytes)
			_bg_tex = ImageTexture.create_from_image(img)
	return _bg_tex


static func shutdown_bg() -> void:
	if _bg_task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_bg_task_id)
		_bg_task_id = -1


static func _bake_worker() -> void:
	var hgrid := PackedFloat32Array()
	hgrid.resize(TEX_W * TEX_H)
	var wgrid: Array[PackedFloat32Array] = []
	wgrid.resize(TEX_W * TEX_H)
	var span: Vector2 = WORLD_MAX - WORLD_MIN
	var dx: float = span.x / float(TEX_W - 1)
	var dz: float = span.y / float(TEX_H - 1)

	for j: int in TEX_H:
		var wz: float = WORLD_MIN.y + j * dz
		for i: int in TEX_W:
			var wx: float = WORLD_MIN.x + i * dx
			var w: PackedFloat32Array = TerrainFn.biome_weights(wx, wz)
			var idx: int = j * TEX_W + i
			wgrid[idx] = w
			hgrid[idx] = TerrainFn.height_w(w, wx, wz)

	var bytes := PackedByteArray()
	bytes.resize(TEX_W * TEX_H * 3)
	var sun_dir := Vector3(-0.62, 0.52, -0.58).normalized()
	for j: int in TEX_H:
		var j0: int = maxi(j - 1, 0)
		var j1: int = mini(j + 1, TEX_H - 1)
		var wz: float = WORLD_MIN.y + j * dz
		for i: int in TEX_W:
			var i0: int = maxi(i - 1, 0)
			var i1: int = mini(i + 1, TEX_W - 1)
			var wx: float = WORLD_MIN.x + i * dx
			var idx: int = j * TEX_W + i
			var h: float = hgrid[idx]
			var w: PackedFloat32Array = wgrid[idx]

			var col: Color
			var wl: float = TerrainFn.water_level_at(wx, wz)
			if h < 0.0 or (wl > TerrainFn.WATER_NONE + 1.0 and h < wl):
				var depth_t: float = clampf((maxf(wl, 0.0) - h) / 15.0, 0.0, 1.0)
				col = Color(0.12, 0.30, 0.52).lerp(Color(0.07, 0.19, 0.38), depth_t)
			else:
				var c_country := Color(0.12, 0.21, 0.12)
				var c_hills := Color(0.11, 0.19, 0.11)
				var c_mtn := Color(0.22, 0.21, 0.20)
				var c_coast := Color(0.24, 0.23, 0.17)
				var c_city := Color(0.20, 0.22, 0.25)
				var c_forest := Color(0.05, 0.17, 0.07)
				var c_desert := Color(0.33, 0.23, 0.14)
				col = c_country * w[TerrainFn.COUNTRY] \
					+ c_hills * w[TerrainFn.HILLS] \
					+ c_mtn * w[TerrainFn.MOUNTAIN] \
					+ c_coast * w[TerrainFn.COAST] \
					+ c_city * w[TerrainFn.CITY] \
					+ c_forest * w[TerrainFn.FOREST] \
					+ c_desert * w[TerrainFn.DESERT]
				if h < 4.5 and w[TerrainFn.COAST] > 0.15:
					col = col.lerp(Color(0.32, 0.29, 0.20), 0.55)
				if h > 290.0:
					col = col.lerp(Color(0.46, 0.49, 0.53), clampf((h - 290.0) / 80.0, 0.0, 0.75))

				var hx: float = (hgrid[j * TEX_W + i1] - hgrid[j * TEX_W + i0]) / ((i1 - i0) * dx)
				var hz: float = (hgrid[j1 * TEX_W + i] - hgrid[j0 * TEX_W + i]) / ((j1 - j0) * dz)
				var nrm := Vector3(-hx, 1.0, -hz).normalized()
				var shade: float = clampf(0.68 + 0.48 * nrm.dot(sun_dir), 0.52, 1.25)
				col *= shade

				# Subtle 45m topographic contour lines
				var band: float = absf(fmod(h + 900.0, 45.0) - 22.5)
				if band > 20.6 and h > 3.0:
					col = col.lerp(Color(0.38, 0.42, 0.44), 0.25)

				# City block grid hint
				if w[TerrainFn.CITY] > 0.45:
					var gx: float = absf(fposmod(wx - 5352.0, 140.0) - 70.0)
					var gz: float = absf(fposmod(wz - 5352.0, 140.0) - 70.0)
					if gx < 56.0 and gz < 56.0:
						col = col.lightened(0.08)

			var b: int = idx * 3
			bytes[b] = clampi(roundi(col.r * 255.0), 0, 255)
			bytes[b + 1] = clampi(roundi(col.g * 255.0), 0, 255)
			bytes[b + 2] = clampi(roundi(col.b * 255.0), 0, 255)

	_bg_mutex.lock()
	_bg_bytes = bytes
	_bg_mutex.unlock()


static func self_check() -> String:
	ensure_roads()
	if edges_fine.size() != RoadGraph.e_pts.size() or edges_fine.is_empty():
		return "road polylines missing"
	var pts: int = 0
	var dense: int = 0
	for e: int in edges_fine.size():
		if edges_fine[e].size() < 2 or edges_coarse[e].size() < 2:
			return "short edge %d" % e
		if edge_types[e] < 0 or edge_types[e] >= ROAD_FILL.size():
			return "bad type %d" % e
		pts += edges_fine[e].size()
		dense += RoadGraph.e_pts[e].size()
		for p: Vector2 in edges_fine[e]:
			if is_nan(p.x) or is_nan(p.y):
				return "nan polyline %d" % e
	if pts >= dense:
		return "simplify did not drop points (%d >= %d)" % [pts, dense]
	if OsmWorld.enabled:
		if nearest_region_name(Vector2(10600.0, -2400.0)) != "TOKYO GINZA C1":
			return "tokyo region"
		if nearest_region_name(Vector2(-8200.0, -150.0)) != "MONACO":
			return "monaco region"
		if nearest_region_name(Vector2(-350.0, 5850.0)) != "DUBAI DOWNTOWN":
			return "dubai region"
	else:
		if nearest_region_name(Vector2(5632.0, 5632.0)) != "Downtown City":
			return "city region"
		if nearest_region_name(Vector2(-1600.0, -5500.0)) != "Hill Pass":
			return "hill pass region"
		if nearest_region_name(Vector2(0.0, 8600.0)) != "Southern Coast":
			return "coast region"
	if towns.is_empty():
		return "no towns"
	return ""
