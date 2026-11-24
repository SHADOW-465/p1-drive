class_name OsmWorld
extends RefCounted
## Horizon Triland (real OSM + SRTM, data/world/*.json) as the drivable world. The region files are baked offline
## (tools/bake_world.py) into data/world/baked/: road graph, conformed terrain raster, biome planes, building
## footprints, water. Pure static and read-only after load, so tile workers may call it freely.
## `--world=old` (command line or user args) selects the earlier procedural map instead.

## Map data folder. Chosen at start-up with --map=<id> (see MAP_DIRS). Default: the original Horizon Triland map.
static var DIR: String = "res://data/world/baked/"
const MAP_DIRS: Dictionary = {
	"triland": "res://data/world/baked/",
	"lofoten": "res://data/world/lofoten/",
}
const NONE: float = -9999.0

static var enabled: bool = true
static var n: int = 513  # raster points per side
static var lattice: float = 64.0
static var origin: float = -16384.0
static var terrain: PackedFloat32Array = []
static var weights: PackedByteArray = []  # 6 planes: CITY, FOREST, DESERT, MOUNTAIN, HILLS, COAST
static var meta: Dictionary = {}
static var _buildings: Dictionary = {}
static var _water: Array[Dictionary] = []  # {y, poly: PackedVector2Array, rect: Rect2}
static var _water_idx: Dictionary[Vector2i, PackedInt32Array] = {}
const WATER_CELL: float = 256.0


static func _static_init() -> void:
	for a: String in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a == "--world=old":
			enabled = false
		if a.begins_with("--map="):
			var mid: String = a.substr(6)
			if MAP_DIRS.has(mid) and FileAccess.file_exists(String(MAP_DIRS[mid]) + "meta.json"):
				DIR = MAP_DIRS[mid]
			else:
				push_warning("MAP %s is not built yet (no meta.json); using triland" % mid)
				print("MAP %s not built; using triland" % mid)
	if enabled:
		_load()


static func _load() -> void:
	meta = JSON.parse_string(FileAccess.get_file_as_string(DIR + "meta.json"))
	n = int(meta["n"])
	lattice = float(meta["lattice"])
	origin = float(meta["origin"])
	var tb: PackedByteArray = FileAccess.get_file_as_bytes(DIR + "terrain.bin")
	terrain = tb.to_float32_array()
	weights = FileAccess.get_file_as_bytes(DIR + "weights.bin")
	_buildings = JSON.parse_string(FileAccess.get_file_as_string(DIR + "buildings.json"))
	for s: Array in meta["sea"]:
		_add_water(0.0, s)
	for w: Dictionary in meta["water"]:
		_add_water(float(w["y"]), w["poly"])


static func _add_water(y: float, pts: Array) -> void:
	var poly := PackedVector2Array()
	for p: Array in pts:
		poly.append(Vector2(float(p[0]), float(p[1])))
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p: Vector2 in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	var id: int = _water.size()
	_water.append({"y": y, "poly": poly, "rect": Rect2(lo, hi - lo)})
	for cz: int in range(floori(lo.y / WATER_CELL), floori(hi.y / WATER_CELL) + 1):
		for cx: int in range(floori(lo.x / WATER_CELL), floori(hi.x / WATER_CELL) + 1):
			var k := Vector2i(cx, cz)
			if not _water_idx.has(k):
				_water_idx[k] = PackedInt32Array()
			_water_idx[k].append(id)


## Catmull-Rom bicubic height of the conformed terrain raster (no noise).
static func height(wx: float, wz: float) -> float:
	var fx: float = clampf((wx - origin) / lattice, 0.0, n - 1.001)
	var fz: float = clampf((wz - origin) / lattice, 0.0, n - 1.001)
	var ix: int = int(fx)
	var iz: int = int(fz)
	var tx: float = fx - ix
	var tz: float = fz - iz
	var wxs: PackedFloat32Array = _cr(tx)
	var wzs: PackedFloat32Array = _cr(tz)
	var h: float = 0.0
	for j: int in 4:
		var row: int = clampi(iz + j - 1, 0, n - 1) * n
		var acc: float = 0.0
		for i: int in 4:
			acc += wxs[i] * terrain[row + clampi(ix + i - 1, 0, n - 1)]
		h += wzs[j] * acc
	return h


static func _cr(t: float) -> PackedFloat32Array:
	var t2: float = t * t
	var t3: float = t2 * t
	return PackedFloat32Array([0.5 * (-t3 + 2.0 * t2 - t), 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0), 0.5 * (-3.0 * t3 + 4.0 * t2 + t), 0.5 * (t3 - t2)])


## Biome weights at lattice point (ix, iz) (world = lattice * index) in TerrainFn order (COUNTRY, HILLS, MOUNTAIN, COAST, CITY, FOREST, DESERT).
static func lattice_weights(ix: int, iz: int) -> PackedFloat32Array:
	var i: int = clampi(ix + int(-origin / lattice), 0, n - 1)
	var j: int = clampi(iz + int(-origin / lattice), 0, n - 1)
	var q: int = j * n + i
	var plane: int = n * n
	var city: float = weights[q] / 255.0
	var forest: float = weights[plane + q] / 255.0
	var desert: float = weights[2 * plane + q] / 255.0
	var mount: float = weights[3 * plane + q] / 255.0
	var hills: float = weights[4 * plane + q] / 255.0
	var coast: float = weights[5 * plane + q] / 255.0
	var sum: float = city + forest + desert + mount + hills + coast
	var w := PackedFloat32Array([maxf(1.0 - sum, 0.0), hills, mount, coast, city, forest, desert])
	if sum > 1.0:
		for k: int in w.size():
			w[k] /= sum
	return w


static func buildings_in_tile(tx: int, tz: int) -> Array:
	return _buildings.get("%d,%d" % [tx, tz], [])


## Distance to the nearest baked water body within 400 m.
## Vector4(dist, water_y, half_width, along) matches TerrainFn.river_query so the fall gate
## can follow a real harbour or canal instead of the procedural river, which this world does not have.
static func nearest_water(wx: float, wz: float) -> Vector4:
	var p := Vector2(wx, wz)
	var best_d: float = 1e9
	var best_y: float = 0.0
	var cx: int = floori(wx / WATER_CELL)
	var cz: int = floori(wz / WATER_CELL)
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			for id: int in _water_idx.get(Vector2i(cx + dx, cz + dz), PackedInt32Array()):
				var w: Dictionary = _water[id]
				var r: Rect2 = w["rect"]
				if p.x < r.position.x - 220.0 or p.x > r.end.x + 220.0 or p.y < r.position.y - 220.0 or p.y > r.end.y + 220.0:
					continue
				var poly: PackedVector2Array = w["poly"]
				var d: float = 0.0 if Geometry2D.is_point_in_polygon(p, poly) else _poly_dist(p, poly)
				if d < best_d:
					best_d = d
					best_y = float(w["y"])
	if best_d > 400.0:
		return Vector4(1e9, 0.0, 0.0, 0.0)
	return Vector4(best_d, best_y, 40.0, 0.5)


static func _poly_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best: float = 1e12
	var count: int = poly.size()
	var a: Vector2 = poly[count - 1]
	for i: int in count:
		var b: Vector2 = poly[i]
		var ab: Vector2 = b - a
		var t: float = clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		best = minf(best, p.distance_squared_to(a + ab * t))
		a = b
	return sqrt(best)


## Water surface level at a point (sea 0, OSM lakes / canals / harbours at their level), NONE when dry.
static func water_level_at(wx: float, wz: float) -> float:
	var ids: PackedInt32Array = _water_idx.get(Vector2i(floori(wx / WATER_CELL), floori(wz / WATER_CELL)), PackedInt32Array())
	var best: float = NONE
	var p := Vector2(wx, wz)
	for id: int in ids:
		var w: Dictionary = _water[id]
		if (w["rect"] as Rect2).has_point(p) and Geometry2D.is_point_in_polygon(p, w["poly"]):
			best = maxf(best, float(w["y"]))
	return best


## Water level at the (g+1) x (g+1) lattice points of tile (tx, tz) (spacing 1024 / g, row-major, NONE = dry): scanline fill
## of every water polygon touching the tile. Points on a tile border are evaluated at identical world positions by both
## tiles, so terrain carving agrees across tiles. Highest level wins where polygons overlap.
static func water_grid(tx: int, tz: int, g: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize((g + 1) * (g + 1))
	out.fill(NONE)
	var ox: float = tx * 1024.0
	var oz: float = tz * 1024.0
	var cell: float = 1024.0 / g
	var seen: Dictionary[int, bool] = {}
	for cz: int in range(floori(oz / WATER_CELL), floori((oz + 1024.0) / WATER_CELL) + 1):
		for cx: int in range(floori(ox / WATER_CELL), floori((ox + 1024.0) / WATER_CELL) + 1):
			for id: int in _water_idx.get(Vector2i(cx, cz), PackedInt32Array()):
				if seen.has(id):
					continue
				seen[id] = true
				_fill_poly(_water[id], ox, oz, cell, g, out)
	return out


static func _fill_poly(w: Dictionary, ox: float, oz: float, cell: float, g: int, out: PackedFloat32Array) -> void:
	var poly: PackedVector2Array = w["poly"]
	var r: Rect2 = w["rect"]
	var y: float = w["y"]
	var np: int = poly.size()
	var j0: int = maxi(ceili((r.position.y - oz) / cell), 0)
	var j1: int = mini(floori((r.end.y - oz) / cell), g)
	var xs := PackedFloat32Array()
	for j: int in range(j0, j1 + 1):
		var zc: float = oz + j * cell
		xs.clear()
		var prev: Vector2 = poly[np - 1]
		for k: int in np:
			var cur: Vector2 = poly[k]
			if (prev.y <= zc and cur.y > zc) or (cur.y <= zc and prev.y > zc):
				xs.append(prev.x + (zc - prev.y) / (cur.y - prev.y) * (cur.x - prev.x))
			prev = cur
		xs.sort()
		for m: int in range(0, xs.size() - 1, 2):
			var i0: int = maxi(ceili((xs[m] - ox) / cell), 0)
			var i1: int = mini(floori((xs[m + 1] - ox) / cell), g)
			for i: int in range(i0, i1 + 1):
				if out[j * (g + 1) + i] < y:
					out[j * (g + 1) + i] = y
