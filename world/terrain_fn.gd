class_name TerrainFn
extends RefCounted
## Pure static terrain function (PLAN 2.3 / RD1): biome weights, base height, and
## continuous analytical river, ravine, lake, and coastline sculpting from data/world_def.json.
## Read-only after load, so worker threads may call it freely.

enum { COUNTRY, HILLS, MOUNTAIN, COAST, CITY, FOREST, DESERT, NB }
const BIOME_NAMES: PackedStringArray = ["countryside", "hills", "mountain", "coast", "city", "forest", "desert"]
const LATTICE: float = 64.0  # biome weights live on this world-aligned grid (tile edges are multiples)
const CITY_Y: float = 20.0
const COAST_Z: float = 8200.0
const WATER_NONE: float = -9999.0

const GRID_MIN: float = -10240.0
const GRID_CELL: float = 512.0
const GRID_N: int = 40

static var def: Dictionary = {}
static var world_seed: int = 0
static var _blobs: Array[PackedFloat32Array] = []  # [biome, kind 0 circle / 1 rect, a, b, c, d, falloff]
static var _noise: Array[FastNoiseLite] = []
static var tint: FastNoiseLite  # low-frequency colour/density variation

static var _river_pts: PackedVector3Array = []
static var _river_u: PackedFloat32Array = []
static var _river_min: Vector2 = Vector2.ZERO
static var _river_max: Vector2 = Vector2.ZERO
static var _river_grid: Array[PackedInt32Array] = []

static var _ravine_pts: PackedVector3Array = []
static var _ravine_min: Vector2 = Vector2.ZERO
static var _ravine_max: Vector2 = Vector2.ZERO
static var _ravine_grid: Array[PackedInt32Array] = []

static var _has_lake: bool = false
static var _lake_center: Vector2 = Vector2.ZERO
static var _lake_y: float = 36.0
static var _lake_r: float = 540.0


static func _static_init() -> void:
	def = JSON.parse_string(FileAccess.get_file_as_string("res://data/world_def.json"))
	if OsmWorld.enabled:
		def = {"seed": 202611, "blobs": [], "hero_tiles": {}}  # biomes, relief and water come from OsmWorld
	world_seed = int(def["seed"])
	for b: Dictionary in def["blobs"]:
		var e := PackedFloat32Array([BIOME_NAMES.find(b["biome"]), 0, 0, 0, 0, 0, b["f"]])
		if b.has("c"):
			e[2] = b["c"][0]
			e[3] = b["c"][1]
			e[4] = b["r"]
		else:
			e[1] = 1.0
			e[2] = b["min"][0]
			e[3] = b["min"][1]
			e[4] = b["max"][0]
			e[5] = b["max"][1]
		_blobs.append(e)
	# wavelength m, octaves, ridged (COUNTRY, HILLS, MOUNTAIN, COAST, CITY(unused), FOREST, DESERT)
	for p: Array in [
		[900.0, 3, false],
		[1400.0, 4, false],
		[2600.0, 5, true],
		[1000.0, 3, false],
		[900.0, 2, false],
		[1100.0, 3, false],
		[1300.0, 3, false],
	]:
		var n := FastNoiseLite.new()
		n.seed = world_seed + _noise.size() * 101
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0 / p[0]
		n.fractal_type = FastNoiseLite.FRACTAL_RIDGED if p[2] else FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = p[1]
		_noise.append(n)
	tint = FastNoiseLite.new()
	tint.seed = world_seed + 999
	tint.frequency = 1.0 / 350.0
	tint.fractal_octaves = 2

	_init_carves()


static func _init_carves() -> void:
	var raw_river: Array = def.get("river", [])
	if raw_river.size() >= 2:
		var ctrl := PackedVector3Array()
		for p: Array in raw_river:
			ctrl.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		_river_pts = _subdivide_catmull(ctrl, 6)
		var total_len: float = 0.0
		_river_u.resize(_river_pts.size())
		_river_u[0] = 0.0
		for i: int in range(1, _river_pts.size()):
			total_len += Vector2(_river_pts[i].x - _river_pts[i - 1].x, _river_pts[i].z - _river_pts[i - 1].z).length()
			_river_u[i] = total_len
		for i: int in _river_u.size():
			_river_u[i] = _river_u[i] / maxf(total_len, 1.0)
		var b := _bounds_xz(_river_pts, 280.0)
		_river_min = b[0]
		_river_max = b[1]
		_river_grid = _build_seg_grid(_river_pts, 260.0)

	var raw_ravine: Array = def.get("ravine", [])
	if raw_ravine.size() >= 2:
		var ctrl := PackedVector3Array()
		for p: Array in raw_ravine:
			ctrl.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		_ravine_pts = _subdivide_catmull(ctrl, 4)
		var b := _bounds_xz(_ravine_pts, 160.0)
		_ravine_min = b[0]
		_ravine_max = b[1]
		_ravine_grid = _build_seg_grid(_ravine_pts, 135.0)

	var lk: Dictionary = def.get("lake", {})
	if lk.has("center"):
		_has_lake = true
		var c: Array = lk["center"]
		_lake_center = Vector2(float(c[0]), float(c[1]))
		_lake_y = float(lk.get("water_y", 36.0))
		_lake_r = float(lk.get("radius", 540.0))


static func _subdivide_catmull(ctrl: PackedVector3Array, sub: int) -> PackedVector3Array:
	var n: int = ctrl.size()
	if n < 3:
		return ctrl
	var out := PackedVector3Array()
	for i: int in n - 1:
		var p1: Vector3 = ctrl[i]
		var p2: Vector3 = ctrl[i + 1]
		var p0: Vector3 = ctrl[i - 1] if i > 0 else p1 * 2.0 - p2
		var p3: Vector3 = ctrl[i + 2] if i < n - 2 else p2 * 2.0 - p1
		for k: int in sub:
			var t: float = float(k) / float(sub)
			var t2: float = t * t
			var t3: float = t2 * t
			var pt: Vector3 = 0.5 * (
				(2.0 * p1)
				+ (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
			)
			out.append(pt)
	out.append(ctrl[n - 1])
	return out


static func _bounds_xz(pts: PackedVector3Array, pad: float) -> Array[Vector2]:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p: Vector3 in pts:
		lo.x = minf(lo.x, p.x)
		lo.y = minf(lo.y, p.z)
		hi.x = maxf(hi.x, p.x)
		hi.y = maxf(hi.y, p.z)
	return [lo - Vector2(pad, pad), hi + Vector2(pad, pad)]


## Undulating natural coastline latitude Z(wx).
static func coast_z(wx: float) -> float:
	return COAST_Z + 480.0 * sin(wx * 0.00048 + 2.4) + 240.0 * sin(wx * 0.00115 - 0.7) + 90.0 * cos(wx * 0.0024)


## Normalized biome weights at lattice point (ix, iz) = world (ix, iz) * LATTICE.
static func lattice_weights(ix: int, iz: int) -> PackedFloat32Array:
	if OsmWorld.enabled:
		return OsmWorld.lattice_weights(ix, iz)
	var x: float = ix * LATTICE
	var z: float = iz * LATTICE
	var w := PackedFloat32Array()
	w.resize(NB)
	var sum: float = 0.0
	for b: PackedFloat32Array in _blobs:
		var bi: int = int(b[0])
		if bi < 0 or bi >= NB:
			continue
		var d: float
		if b[1] < 0.5:
			d = Vector2(x - b[2], z - b[3]).length() - b[4]
		elif bi == COAST:
			d = maxf(maxf(b[2] - x, x - b[4]), maxf(coast_z(x) - z, z - b[5]))
		else:
			d = maxf(maxf(b[2] - x, x - b[4]), maxf(b[3] - z, z - b[5]))
		if d < b[6]:
			var v: float = 1.0 - smoothstep(0.0, b[6], d)
			w[bi] = maxf(w[bi], v)
	for i: int in range(1, NB):
		sum += w[i]
	if sum > 1.0:
		for i: int in range(1, NB):
			w[i] /= sum
	else:
		w[COUNTRY] = 1.0 - sum
	return w


static func biome_weights(wx: float, wz: float) -> PackedFloat32Array:
	var fx: float = wx / LATTICE
	var fz: float = wz / LATTICE
	var ix: int = floori(fx)
	var iz: int = floori(fz)
	fx -= ix
	fz -= iz
	var a: PackedFloat32Array = lattice_weights(ix, iz)
	var b: PackedFloat32Array = lattice_weights(ix + 1, iz)
	var c: PackedFloat32Array = lattice_weights(ix, iz + 1)
	var d: PackedFloat32Array = lattice_weights(ix + 1, iz + 1)
	var w := PackedFloat32Array()
	w.resize(NB)
	for i: int in NB:
		w[i] = lerpf(lerpf(a[i], b[i], fx), lerpf(c[i], d[i], fx), fz)
	return w


## Height for given weights (hot path: tile gen passes interpolated lattice weights).
static func height_w(w: PackedFloat32Array, wx: float, wz: float) -> float:
	if OsmWorld.enabled:
		return OsmWorld.height(wx, wz)  # baked SRTM, already conformed; stamp() seats the road edges
	var h: float = 0.0
	if w[COUNTRY] > 0.001:
		h += w[COUNTRY] * (22.0 + 25.0 * _noise[COUNTRY].get_noise_2d(wx, wz))
	if w[HILLS] > 0.001:
		h += w[HILLS] * (82.0 + 108.0 * _noise[HILLS].get_noise_2d(wx, wz))
	if w[MOUNTAIN] > 0.001:
		h += w[MOUNTAIN] * (75.0 + 380.0 * (0.5 + 0.5 * _noise[MOUNTAIN].get_noise_2d(wx, wz)))
	if w[COAST] > 0.001:
		var cz: float = coast_z(wx)
		h += w[COAST] * (clampf(10.0 - (wz - cz) * 0.02, -15.0, 10.0) + 7.0 * _noise[COAST].get_noise_2d(wx, wz))
	h += w[CITY] * CITY_Y
	if w[FOREST] > 0.001:
		h += w[FOREST] * (40.0 + 36.0 * _noise[FOREST].get_noise_2d(wx, wz))
	if w[DESERT] > 0.001:
		var dn: float = _noise[DESERT].get_noise_2d(wx, wz)
		var mesa: float = smoothstep(0.32, 0.58, dn) * 32.0
		h += w[DESERT] * (20.0 + 18.0 * dn + mesa)

	if w[CITY] < 0.99:
		var nat: float = 1.0 - w[CITY]
		if not _river_pts.is_empty() and wx >= _river_min.x and wx <= _river_max.x and wz >= _river_min.y and wz <= _river_max.y:
			h = lerpf(h, _carve_river(h, wx, wz), nat)
		if not _ravine_pts.is_empty() and wx >= _ravine_min.x and wx <= _ravine_max.x and wz >= _ravine_min.y and wz <= _ravine_max.y:
			h = lerpf(h, _carve_ravine(h, wx, wz), nat)
		if _has_lake and absf(wx - _lake_center.x) < 920.0 and absf(wz - _lake_center.y) < 920.0:
			h = lerpf(h, _carve_lake(h, wx, wz), nat)
	return h


static func base_height(wx: float, wz: float) -> float:
	return height_w(biome_weights(wx, wz), wx, wz)


static func _build_seg_grid(pts: PackedVector3Array, pad: float) -> Array[PackedInt32Array]:
	var g: Array[PackedInt32Array] = []
	g.resize(GRID_N * GRID_N)
	for k: int in GRID_N * GRID_N:
		g[k] = PackedInt32Array()
	for i: int in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var x0: int = clampi(floori((minf(a.x, b.x) - pad - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
		var x1: int = clampi(floori((maxf(a.x, b.x) + pad - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
		var z0: int = clampi(floori((minf(a.z, b.z) - pad - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
		var z1: int = clampi(floori((maxf(a.z, b.z) + pad - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
		for gz: int in range(z0, z1 + 1):
			for gx: int in range(x0, x1 + 1):
				g[gz * GRID_N + gx].append(i)
	return g


static func _grid_cell(wx: float, wz: float) -> int:
	var gx: int = clampi(floori((wx - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
	var gz: int = clampi(floori((wz - GRID_MIN) / GRID_CELL), 0, GRID_N - 1)
	return gz * GRID_N + gx


## Nearest river info: Vector4(dist, water_y, half_w, u) or Vector4(1e9, 0, 0, 0) outside bounds.
## On the OSM world this is the nearest baked sea, harbour, lake or canal.
static func river_query(wx: float, wz: float) -> Vector4:
	if OsmWorld.enabled:
		return OsmWorld.nearest_water(wx, wz)
	if _river_pts.is_empty() or wx < _river_min.x or wx > _river_max.x or wz < _river_min.y or wz > _river_max.y:
		return Vector4(1e9, 0.0, 0.0, 0.0)
	var segs: PackedInt32Array = _river_grid[_grid_cell(wx, wz)]
	if segs.is_empty():
		return Vector4(1e9, 0.0, 0.0, 0.0)
	var best_d2: float = 1e18
	var best_y: float = 0.0
	var best_u: float = 0.0
	for i: int in segs:
		var a: Vector3 = _river_pts[i]
		var b: Vector3 = _river_pts[i + 1]
		var abx: float = b.x - a.x
		var abz: float = b.z - a.z
		var ab2: float = maxf(abx * abx + abz * abz, 1e-4)
		var t: float = clampf(((wx - a.x) * abx + (wz - a.z) * abz) / ab2, 0.0, 1.0)
		var dx: float = wx - (a.x + abx * t)
		var dz: float = wz - (a.z + abz * t)
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best_y = lerpf(a.y, b.y, t)
			best_u = lerpf(_river_u[i], _river_u[i + 1], t)
	var half_w: float = lerpf(16.0, 56.0, smoothstep(0.0, 1.0, best_u))
	return Vector4(sqrt(best_d2), best_y, half_w, best_u)


static func _carve_river(h: float, wx: float, wz: float) -> float:
	var rq: Vector4 = river_query(wx, wz)
	var d: float = rq.x
	var water_y: float = rq.y
	var half_w: float = rq.z
	var u: float = rq.w
	var flood_r: float = half_w + 185.0
	if d >= flood_r:
		return h
	var head_fade: float = smoothstep(0.0, 0.06, u)
	var coast_fade: float = 1.0 - smoothstep(0.76, 0.94, u)
	var flood_y: float = water_y + 3.4 + 2.4 * _noise[COUNTRY].get_noise_2d(wx, wz)
	var w_flood: float = (1.0 - smoothstep(half_w + 20.0, flood_r, d)) * coast_fade * head_fade
	h = lerpf(h, flood_y, w_flood * 0.85)
	if d < half_w + 26.0:
		var ch_w: float = (1.0 - smoothstep(half_w * 0.42, half_w + 24.0, d)) * head_fade
		h = lerpf(h, water_y - 4.8, ch_w)
	return h


static func _carve_ravine(h: float, wx: float, wz: float) -> float:
	var segs: PackedInt32Array = _ravine_grid[_grid_cell(wx, wz)]
	if segs.is_empty():
		return h
	var best_d2: float = 1e18
	var floor_y: float = 0.0
	for i: int in segs:
		var a: Vector3 = _ravine_pts[i]
		var b: Vector3 = _ravine_pts[i + 1]
		var abx: float = b.x - a.x
		var abz: float = b.z - a.z
		var ab2: float = maxf(abx * abx + abz * abz, 1e-4)
		var t: float = clampf(((wx - a.x) * abx + (wz - a.z) * abz) / ab2, 0.0, 1.0)
		var dx: float = wx - (a.x + abx * t)
		var dz: float = wz - (a.z + abz * t)
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			floor_y = lerpf(a.y, b.y, t)
	var d: float = sqrt(best_d2)
	var rim_w: float = 115.0
	if d >= rim_w:
		return h
	var w_rav: float = 1.0 - smoothstep(18.0, rim_w, d)
	var diff: float = h - floor_y
	var excess: float = 0.5 * (diff + sqrt(diff * diff + 16.0))
	return h - excess * w_rav


static func lake_signed_dist(wx: float, wz: float) -> float:
	if not _has_lake:
		return 1e9
	var rel := Vector2(wx - _lake_center.x, wz - _lake_center.y)
	var r: float = rel.length()
	if r > 920.0:
		return r - _lake_r
	var ang: float = atan2(rel.y, rel.x)
	var inlet_d: float = absf(wrapf(ang - 0.25, -PI, PI))
	var r_edge: float = _lake_r * (1.0 + 0.22 * sin(2.0 * ang + 0.7) + 0.14 * cos(3.0 * ang - 0.5) - 0.20 * exp(-pow(inlet_d / 0.38, 2.0)))
	return r - r_edge


static func _carve_lake(h: float, wx: float, wz: float) -> float:
	var d_shore: float = lake_signed_dist(wx, wz)
	if d_shore >= 195.0:
		return h
	var bank_y: float = _lake_y + 2.8 + 4.0 * _noise[FOREST].get_noise_2d(wx, wz)
	var shore_w: float = 1.0 - smoothstep(24.0, 195.0, d_shore)
	h = lerpf(h, bank_y, shore_w * 0.75)
	if d_shore < 24.0:
		var bed_w: float = 1.0 - smoothstep(-36.0, 24.0, d_shore)
		h = lerpf(h, _lake_y - 7.5, bed_w)
	return h


## Water surface elevation at (wx, wz), or WATER_NONE when dry land.
static func water_level_at(wx: float, wz: float) -> float:
	if OsmWorld.enabled:
		return OsmWorld.water_level_at(wx, wz)
	var best: float = WATER_NONE
	if wz > coast_z(wx) - 180.0:
		best = 0.0
	var rq: Vector4 = river_query(wx, wz)
	if rq.x < rq.z + 18.0:
		best = maxf(best, rq.y)
	if _has_lake and lake_signed_dist(wx, wz) < 16.0:
		best = maxf(best, _lake_y)
	return best


static func self_check() -> String:
	var lo: float = 1e9
	var hi: float = -1e9
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i: int in 3000:
		var span: float = 16000.0 if OsmWorld.enabled else 10240.0
		var x: float = rng.randf_range(-span, span)
		var z: float = rng.randf_range(-span, span)
		var h: float = base_height(x, z)
		if h != base_height(x, z) or is_nan(h):
			return "not deterministic at %f,%f" % [x, z]
		lo = minf(lo, h)
		hi = maxf(hi, h)
		var bx: float = roundf(x / 1024.0) * 1024.0
		if absf(base_height(bx - 0.01, z) - base_height(bx + 0.01, z)) > 0.05:
			return "discontinuous at x=%f z=%f" % [bx, z]
		var w: PackedFloat32Array = biome_weights(x, z)
		var wsum: float = 0.0
		for v: float in w:
			wsum += v
		if absf(wsum - 1.0) > 0.001:
			return "weights not normalized"
	if OsmWorld.enabled:
		if hi < 300.0 or hi > 1800.0:
			return "mountain range off: max %f" % hi
		if lo > 0.0 or lo < -40.0:
			return "sea range off: min %f" % lo
		return ""
	if hi < 250.0 or hi > 520.0:
		return "mountain range off: max %f" % hi
	if lo > -5.0 or lo < -30.0:
		return "sea range off: min %f" % lo
	if absf(base_height(5632.0, 5120.0) - CITY_Y) > 0.01:
		return "city not flat"
	return ""
