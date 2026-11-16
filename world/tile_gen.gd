class_name TileGen
extends RefCounted
## Worker-side pure builders (PLAN 2.2): build() returns plain data only, tile-local coords
## (origin = the tile's NW corner at world (tx, tz) * 1024). TileNode turns it into nodes.

enum { FULL, MID, FAR }
const TILE: float = 1024.0
const GRID: PackedInt32Array = [129, 33, 17]  # vertices per side, per LOD
const SKIRT: PackedFloat32Array = [12.0, 24.0, 40.0]  # skirt drop, hides LOD cracks
const SNOW_Y: float = 320.0

static var _indices: Array[PackedInt32Array] = []
static var _pal: PackedColorArray = []  # linear: country, hills, mountain, coast, city, rock, sand, snow


static func _static_init() -> void:
	for lod: int in 3:
		_indices.append(_build_indices(GRID[lod]))
	for c: Color in [Color(0.33, 0.47, 0.2), Color(0.25, 0.4, 0.18), Color(0.36, 0.41, 0.25), Color(0.47, 0.5, 0.26),
			Color(0.36, 0.37, 0.38), Color(0.43, 0.4, 0.37), Color(0.8, 0.72, 0.52), Color(0.92, 0.94, 0.97)]:
		_pal.append(c.srgb_to_linear())


static func build(tx: int, tz: int, lod: int) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var d: Dictionary = {"tx": tx, "tz": tz, "lod": lod}
	var n: int = GRID[lod]
	var cols := PackedColorArray()
	var h: PackedFloat32Array = _heights(tx, tz, n, cols)
	var bw := PackedFloat32Array()
	if lod != FAR:
		bw = RoadMesher.stamp(tx, tz, n, lod, h, cols)
	_terrain(d, n, lod, h, cols)
	if lod != FAR:
		RoadMesher.mesh(d, tx, tz, lod)
	if lod == FULL:
		RoadMesher.props(d, tx, tz)
		var sc: Array = Scatter.build(tx, tz, n, h, bw)
		if not sc.is_empty():
			d["scatter"] = sc
		var hero: Dictionary = (TerrainFn.def.get("hero_tiles", {}) as Dictionary).get("%d,%d" % [tx, tz], {})
		if hero.has("overlay"):
			d["overlay"] = hero["overlay"]
	d["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return d


## Base heights + biome colours on the (n+2)^2 grid: one cell of margin for border normals.
static func _heights(tx: int, tz: int, n: int, cols: PackedColorArray) -> PackedFloat32Array:
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var ox: float = tx * TILE
	var oz: float = tz * TILE
	var lat: float = TerrainFn.LATTICE
	# lattice weights around the tile, margin included (cell <= lattice step)
	var ln: int = int(TILE / lat) + 4
	var lx0: int = floori(ox / lat) - 1
	var lz0: int = floori(oz / lat) - 1
	var lw: Array[PackedFloat32Array] = []
	for j: int in ln:
		for i: int in ln:
			lw.append(TerrainFn.lattice_weights(lx0 + i, lz0 + j))
	var h := PackedFloat32Array()
	h.resize(m * m)
	cols.resize(m * m)
	var w := PackedFloat32Array([0, 0, 0, 0, 0])
	for j: int in m:
		var wz: float = oz + (j - 1) * cell
		var fz: float = wz / lat - lz0
		var jz: int = int(fz)
		fz -= jz
		for i: int in m:
			var wx: float = ox + (i - 1) * cell
			var fx: float = wx / lat - lx0
			var ix: int = int(fx)
			fx -= ix
			var a: PackedFloat32Array = lw[jz * ln + ix]
			var b: PackedFloat32Array = lw[jz * ln + ix + 1]
			var c: PackedFloat32Array = lw[(jz + 1) * ln + ix]
			var e: PackedFloat32Array = lw[(jz + 1) * ln + ix + 1]
			var col := Color(0, 0, 0)
			for k: int in TerrainFn.NB:
				var v: float = lerpf(lerpf(a[k], b[k], fx), lerpf(c[k], e[k], fx), fz)
				w[k] = v
				col += _pal[k] * v
			h[j * m + i] = TerrainFn.height_w(w, wx, wz)
			col *= 1.0 + 0.16 * TerrainFn.tint.get_noise_2d(wx, wz) * (1.0 - w[TerrainFn.CITY])
			col.a = w[TerrainFn.CITY]
			cols[j * m + i] = col
	return h


## Mesh arrays (+ collider heights for FULL) from the margin grid.
static func _terrain(d: Dictionary, n: int, lod: int, h: PackedFloat32Array, cols: PackedColorArray) -> void:
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var nv: int = n * n
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var vcol := PackedColorArray()
	verts.resize(nv + 4 * n)
	norms.resize(nv + 4 * n)
	vcol.resize(nv + 4 * n)
	var hm := PackedFloat32Array()
	hm.resize(nv)
	var rock: Color = _pal[5]
	var sand: Color = _pal[6]
	var snow: Color = _pal[7]
	for j: int in n:
		for i: int in n:
			var q: int = (j + 1) * m + i + 1
			var y: float = h[q]
			var nrm := Vector3(h[q - 1] - h[q + 1], 2.0 * cell, h[q - m] - h[q + m]).normalized()
			var c: Color = cols[q]
			var city: float = c.a
			var nat: float = 1.0 - city
			c = c.lerp(rock, smoothstep(0.82, 0.68, nrm.y) * nat)
			c = c.lerp(snow, smoothstep(SNOW_Y - 25.0, SNOW_Y + 25.0, y) * smoothstep(0.6, 0.8, nrm.y))
			c = c.lerp(sand, smoothstep(4.0, 1.5, y) * nat)
			c.a = 1.0
			var k: int = j * n + i
			verts[k] = Vector3(i * cell, y, j * cell)
			norms[k] = nrm
			vcol[k] = c
			hm[k] = y
	# skirts: copies of the border vertices, dropped
	var drop := Vector3(0.0, SKIRT[lod], 0.0)
	for i: int in n:
		var src: PackedInt32Array = [i, (n - 1) * n + i, i * n, i * n + n - 1]  # N, S, W, E
		for s: int in 4:
			var k: int = nv + s * n + i
			verts[k] = verts[src[s]] - drop
			norms[k] = norms[src[s]]
			vcol[k] = vcol[src[s]]
	d["verts"] = verts
	d["norms"] = norms
	d["cols"] = vcol
	d["idx"] = _indices[lod]
	if lod == FULL:
		d["hm"] = hm


## Quad diagonals run (i+1, j) -> (i, j+1) to match the HeightMapShape3D triangulation.
static func _build_indices(n: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	for j: int in n - 1:
		for i: int in n - 1:
			var a: int = j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var nv: int = n * n
	for i: int in n - 1:
		# border vertex pairs (a, b) ordered so the skirt faces outwards: N, S, W, E
		var e: PackedInt32Array = [i + 1, i, (n - 1) * n + i, (n - 1) * n + i + 1, i * n, (i + 1) * n, (i + 1) * n + n - 1, i * n + n - 1]
		var o: PackedInt32Array = [1, 0, 0, 1, 0, 1, 1, 0]
		for s: int in 4:
			var a: int = e[s * 2]
			var b: int = e[s * 2 + 1]
			var sa: int = nv + s * n + i + o[s * 2]
			var sb: int = nv + s * n + i + o[s * 2 + 1]
			idx.append_array([a, b, sb, a, sb, sa])
	return idx
