class_name TerrainFn
extends RefCounted
## Pure static terrain function (PLAN 2.3): biome weights and base height from data/world_def.json.
## Read-only after load, so worker threads may call it freely.

enum { COUNTRY, HILLS, MOUNTAIN, COAST, CITY, NB }
const BIOME_NAMES: PackedStringArray = ["countryside", "hills", "mountain", "coast", "city"]
const LATTICE: float = 64.0  # biome weights live on this world-aligned grid (tile edges are multiples)
const CITY_Y: float = 20.0
const COAST_Z: float = 8200.0

static var def: Dictionary = {}
static var world_seed: int = 0
static var _blobs: Array[PackedFloat32Array] = []  # [biome, kind 0 circle / 1 rect, a, b, c, d, falloff]
static var _noise: Array[FastNoiseLite] = []
static var tint: FastNoiseLite  # low-frequency colour/density variation


static func _static_init() -> void:
	def = JSON.parse_string(FileAccess.get_file_as_string("res://data/world_def.json"))
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
	# wavelength m, octaves, ridged (PLAN 6.6)
	for p: Array in [[900.0, 3, false], [1400.0, 4, false], [2600.0, 5, true], [1000.0, 3, false]]:
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


## Normalized biome weights at lattice point (ix, iz) = world (ix, iz) * LATTICE.
static func lattice_weights(ix: int, iz: int) -> PackedFloat32Array:
	var x: float = ix * LATTICE
	var z: float = iz * LATTICE
	var w := PackedFloat32Array([0, 0, 0, 0, 0])
	var sum: float = 0.0
	for b: PackedFloat32Array in _blobs:
		var d: float
		if b[1] < 0.5:
			d = Vector2(x - b[2], z - b[3]).length() - b[4]
		else:
			d = maxf(maxf(b[2] - x, x - b[4]), maxf(b[3] - z, z - b[5]))
		if d < b[6]:
			var v: float = 1.0 - smoothstep(0.0, b[6], d)
			w[int(b[0])] = maxf(w[int(b[0])], v)
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
	var h: float = 0.0
	if w[COUNTRY] > 0.001:
		h += w[COUNTRY] * (22.0 + 25.0 * _noise[COUNTRY].get_noise_2d(wx, wz))
	if w[HILLS] > 0.001:
		h += w[HILLS] * (75.0 + 110.0 * _noise[HILLS].get_noise_2d(wx, wz))
	if w[MOUNTAIN] > 0.001:
		h += w[MOUNTAIN] * (70.0 + 380.0 * (0.5 + 0.5 * _noise[MOUNTAIN].get_noise_2d(wx, wz)))
	if w[COAST] > 0.001:
		h += w[COAST] * (clampf(9.0 - (wz - COAST_Z) * 0.02, -15.0, 9.0) + 7.0 * _noise[COAST].get_noise_2d(wx, wz))
	h += w[CITY] * CITY_Y
	return h


static func base_height(wx: float, wz: float) -> float:
	return height_w(biome_weights(wx, wz), wx, wz)


static func self_check() -> String:
	var lo: float = 1e9
	var hi: float = -1e9
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for i: int in 3000:
		var x: float = rng.randf_range(-10240.0, 10240.0)
		var z: float = rng.randf_range(-10240.0, 10240.0)
		var h: float = base_height(x, z)
		if h != base_height(x, z) or is_nan(h):
			return "not deterministic at %f,%f" % [x, z]
		lo = minf(lo, h)
		hi = maxf(hi, h)
		# continuity across a tile border near this point
		var bx: float = roundf(x / 1024.0) * 1024.0
		if absf(base_height(bx - 0.01, z) - base_height(bx + 0.01, z)) > 0.05:
			return "discontinuous at x=%f z=%f" % [bx, z]
		var w: PackedFloat32Array = biome_weights(x, z)
		if absf(w[0] + w[1] + w[2] + w[3] + w[4] - 1.0) > 0.001:
			return "weights not normalized"
	if hi < 250.0 or hi > 520.0:
		return "mountain range off: max %f" % hi
	if lo > -5.0 or lo < -30.0:
		return "sea range off: min %f" % lo
	if absf(base_height(5632.0, 5120.0) - CITY_Y) > 0.01:
		return "city not flat"
	return ""
