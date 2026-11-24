class_name TileGen
extends RefCounted
## Worker-side pure builders (PLAN 2.2 / RD1): build() returns plain data only, tile-local coords
## (origin = the tile's NW corner at world (tx, tz) * 1024). TileNode turns it into nodes.

enum { FULL, MID, FAR }
const TILE: float = 1024.0
const GRID: PackedInt32Array = [129, 33, 17]  # vertices per side, per LOD
const SKIRT: PackedFloat32Array = [12.0, 24.0, 40.0]  # skirt drop, hides LOD cracks
const SNOW_Y: float = 320.0

static var _indices: Array[PackedInt32Array] = []
static var _pal: PackedColorArray = []  # linear: 0..6 biomes, 7 rock, 8 sand, 9 snow


static func _static_init() -> void:
	for lod: int in 3:
		_indices.append(_build_indices(GRID[lod]))
	for c: Color in [
		Color(0.24, 0.43, 0.16),  # COUNTRY
		Color(0.19, 0.36, 0.15),  # HILLS
		Color(0.32, 0.38, 0.24),  # MOUNTAIN
		Color(0.44, 0.48, 0.26),  # COAST
		Color(0.36, 0.37, 0.38),  # CITY
		Color(0.08, 0.28, 0.09),  # FOREST
		Color(0.68, 0.49, 0.30),  # DESERT
		Color(0.43, 0.40, 0.37),  # rock
		Color(0.80, 0.72, 0.52),  # sand
		Color(0.92, 0.94, 0.97),  # snow
	]:
		_pal.append(c.srgb_to_linear())


static func build(tx: int, tz: int, lod: int) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var d: Dictionary = {"tx": tx, "tz": tz, "lod": lod}
	var n: int = GRID[lod]
	var cols := PackedColorArray()
	var desert_w := PackedFloat32Array()
	var forest_w := PackedFloat32Array()
	var h: PackedFloat32Array = _heights(tx, tz, n, cols, desert_w, forest_w)
	var bw := PackedFloat32Array()
	var wg := PackedFloat32Array()
	var wn: int = (n - 1) / 2 if n == GRID[FULL] else n - 1  # water lattice cells per side
	if OsmWorld.enabled:
		wg = OsmWorld.water_grid(tx, tz, wn)
		_carve_water(h, n, wg, wn)
	if lod != FAR:
		bw = RoadMesher.stamp(tx, tz, n, lod, h, cols)
	_terrain(d, tx, tz, n, lod, h, cols, desert_w, forest_w, bw)
	if OsmWorld.enabled:
		_water_osm(d, tx, tz, n, h, wg, wn)
		CityChunks.build(d, tx, tz, h, n, lod)
	else:
		_water(d, tx, tz, n, h)
	if lod != FAR:
		RoadMesher.mesh(d, tx, tz, lod)
	if lod == FULL:
		RoadMesher.props(d, tx, tz)
		if OsmWorld.enabled:
			PoiBuilder.build(d, tx, tz)
		var sc: Array = Scatter.build(tx, tz, n, h, bw)
		if not sc.is_empty():
			d["scatter"] = sc
		var hero: Dictionary = (TerrainFn.def.get("hero_tiles", {}) as Dictionary).get("%d,%d" % [tx, tz], {})
		if hero.has("overlay"):
			d["overlay"] = hero["overlay"]
	TileNode.prebuild(d)
	d["ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return d


## Base heights + biome colours on the (n+2)^2 grid: one cell of margin for border normals.
static func _heights(tx: int, tz: int, n: int, cols: PackedColorArray, desert_w: PackedFloat32Array, forest_w: PackedFloat32Array) -> PackedFloat32Array:
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var ox: float = tx * TILE
	var oz: float = tz * TILE
	var lat: float = TerrainFn.LATTICE
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
	desert_w.resize(m * m)
	forest_w.resize(m * m)
	var w := PackedFloat32Array()
	w.resize(TerrainFn.NB)
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
			var q: int = j * m + i
			h[q] = TerrainFn.height_w(w, wx, wz)
			col *= 1.0 + 0.16 * TerrainFn.tint.get_noise_2d(wx, wz) * (1.0 - w[TerrainFn.CITY])
			col.a = w[TerrainFn.CITY]
			cols[q] = col
			desert_w[q] = w[TerrainFn.DESERT]
			forest_w[q] = w[TerrainFn.FOREST]
	return h


## Mesh arrays (+ collider heights for FULL) from the margin grid.
static func _terrain(d: Dictionary, tx: int, tz: int, n: int, lod: int, h: PackedFloat32Array, cols: PackedColorArray, desert_w: PackedFloat32Array, forest_w: PackedFloat32Array, bw: PackedFloat32Array) -> void:
	var m: int = n + 2
	var cell: float = TILE / (n - 1)
	var ox: float = tx * TILE
	var oz: float = tz * TILE
	var holes: Array[Dictionary] = []
	if lod != TileGen.FAR:
		holes = RoadMesher.tunnel_mouths_in_tile(tx, tz)
	if lod == MID:
		for hole: Dictionary in holes:
			hole["half_lat"] = float(hole["half_lat"]) + 30.0
			hole["min_along"] = float(hole["min_along"]) - 20.0
			hole["max_along"] = float(hole["max_along"]) + 40.0
	var has_hole: bool = false
	var nv: int = n * n
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uvs2 := PackedVector2Array()
	var vcol := PackedColorArray()
	verts.resize(nv + 4 * n)
	norms.resize(nv + 4 * n)
	uvs.resize(nv + 4 * n)
	uvs2.resize(nv + 4 * n)
	vcol.resize(nv + 4 * n)
	var hm := PackedFloat32Array()
	hm.resize(nv)
	var rock: Color = _pal[7]
	var sand: Color = _pal[8]
	var snow: Color = _pal[9]
	var has_bw: bool = not bw.is_empty()
	for j: int in n:
		for i: int in n:
			var q: int = (j + 1) * m + i + 1
			var y: float = h[q]
			var nrm := Vector3(h[q - 1] - h[q + 1], 2.0 * cell, h[q - m] - h[q + m]).normalized()
			var c: Color = cols[q]
			var city: float = c.a
			var nat: float = 1.0 - city
			var road_cut: float = bw[q] if has_bw else 0.0
			c = c.lerp(rock, smoothstep(0.82, 0.68, nrm.y) * nat)
			c = c.lerp(snow, smoothstep(SNOW_Y - 25.0, SNOW_Y + 25.0, y) * smoothstep(0.6, 0.8, nrm.y))
			c = c.lerp(sand, smoothstep(4.0, 1.5, y) * nat)
			c.a = desert_w[q]
			var k: int = j * n + i
			verts[k] = Vector3(i * cell, y, j * cell)
			norms[k] = nrm
			uvs[k] = Vector2(road_cut, city)
			uvs2[k] = Vector2(forest_w[q], 0.0)
			vcol[k] = c
			if not holes.is_empty():
				var wx: float = ox + i * cell
				var wz: float = oz + j * cell
				var blocked: bool = false
				for hole: Dictionary in holes:
					var dv: Vector2 = Vector2(wx, wz) - (hole["center"] as Vector2)
					var along: float = dv.dot(hole["fwd"] as Vector2)
					var lat: float = absf(dv.dot(hole["rt"] as Vector2))
					if along >= float(hole["min_along"]) and along <= float(hole["max_along"]) and lat <= float(hole["half_lat"]):
						blocked = true
						break
				if blocked:
					hm[k] = NAN
					has_hole = true
					continue
			hm[k] = y
	# skirts: copies of the border vertices, dropped
	var drop := Vector3(0.0, SKIRT[lod], 0.0)
	for i: int in n:
		var src: PackedInt32Array = [i, (n - 1) * n + i, i * n, i * n + n - 1]  # N, S, W, E
		for s: int in 4:
			var k: int = nv + s * n + i
			verts[k] = verts[src[s]] - drop
			norms[k] = norms[src[s]]
			uvs[k] = uvs[src[s]]
			uvs2[k] = uvs2[src[s]]
			vcol[k] = vcol[src[s]]
	d["verts"] = verts
	d["norms"] = norms
	d["uvs"] = uvs
	d["uvs2"] = uvs2
	d["cols"] = vcol
	var base_idx: PackedInt32Array = _indices[lod]
	if has_hole:
		var f_idx := PackedInt32Array()
		for t: int in range(0, base_idx.size(), 3):
			var i0: int = base_idx[t]
			var i1: int = base_idx[t + 1]
			var i2: int = base_idx[t + 2]
			if (i0 < nv and is_nan(hm[i0])) or (i1 < nv and is_nan(hm[i1])) or (i2 < nv and is_nan(hm[i2])):
				continue
			f_idx.append(i0)
			f_idx.append(i1)
			f_idx.append(i2)
		d["idx"] = f_idx
	else:
		d["idx"] = base_idx
	if lod != FAR:
		d["hm"] = hm


## Lowers the terrain under OSM water. wg holds the water level at the (wn+1)^2 lattice points (cell = 1024 / wn); a terrain
## vertex between lattice points counts as wet when every lattice point beside it does, so neighbouring tiles agree on borders.
static func _carve_water(h: PackedFloat32Array, n: int, wg: PackedFloat32Array, wn: int) -> void:
	var wet: bool = false
	for v: float in wg:
		if v > OsmWorld.NONE + 1.0:
			wet = true
			break
	if not wet:
		return
	var m: int = n + 2
	var stride: int = (n - 1) / wn
	var gw: int = wn + 1
	for j: int in n:
		var j0: int = j / stride
		var j1: int = j0 + (1 if j % stride != 0 else 0)
		for i: int in n:
			var i0: int = i / stride
			var i1: int = i0 + (1 if i % stride != 0 else 0)
			var lvl: float = 1e9
			for jj: int in range(j0, j1 + 1):
				for ii: int in range(i0, i1 + 1):
					lvl = minf(lvl, wg[jj * gw + ii])
			if lvl > OsmWorld.NONE + 1.0:
				var q: int = (j + 1) * m + i + 1
				h[q] = minf(h[q], lvl - 2.2)


## OSM water (sea, lakes, canals, harbours): lattice cells with any wet corner become flat quads at the water level,
## merged along x in runs of up to 8. COLOR.r is the depth factor of the water shader.
static func _water_osm(d: Dictionary, tx: int, tz: int, n: int, h: PackedFloat32Array, wg: PackedFloat32Array, wn: int) -> void:
	var gw: int = wn + 1
	var cell_w: float = TILE / wn
	var stride: int = (n - 1) / wn
	var m: int = n + 2
	var ox: float = tx * TILE
	var oz: float = tz * TILE
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for j: int in wn:
		var i: int = 0
		while i < wn:
			var wy: float = maxf(maxf(wg[j * gw + i], wg[j * gw + i + 1]), maxf(wg[(j + 1) * gw + i], wg[(j + 1) * gw + i + 1]))
			if wy <= OsmWorld.NONE + 1.0:
				i += 1
				continue
			var i2: int = i + 1
			while i2 < wn and i2 - i < 8:
				var wy2: float = maxf(maxf(wg[j * gw + i2], wg[j * gw + i2 + 1]), maxf(wg[(j + 1) * gw + i2], wg[(j + 1) * gw + i2 + 1]))
				if absf(wy2 - wy) > 0.01:
					break
				i2 += 1
			var hs := PackedFloat32Array([
				h[(j * stride + 1) * m + i * stride + 1], h[(j * stride + 1) * m + i2 * stride + 1],
				h[((j + 1) * stride + 1) * m + i2 * stride + 1], h[((j + 1) * stride + 1) * m + i * stride + 1]])
			if minf(minf(hs[0], hs[1]), minf(hs[2], hs[3])) > wy + 1.2:
				i = i2
				continue
			var xs := PackedFloat32Array([i * cell_w, i2 * cell_w, i2 * cell_w, i * cell_w])
			var zs := PackedFloat32Array([j * cell_w, j * cell_w, (j + 1) * cell_w, (j + 1) * cell_w])
			var b: int = verts.size()
			for k: int in 4:
				verts.append(Vector3(xs[k], wy, zs[k]))
				norms.append(Vector3.UP)
				uvs.append(Vector2(ox + xs[k], oz + zs[k]))
				cols.append(Color(clampf((wy - hs[k]) / 6.0, 0.0, 1.0), 0.0, 0.0, 1.0))
			idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
			i = i2
	if not verts.is_empty():
		d["water"] = {"verts": verts, "norms": norms, "uvs": uvs, "cols": cols, "idx": idx}


## Water surface mesh (sea, Mirror Lake, Clearwater River) when present in this tile.
static func _water(d: Dictionary, tx: int, tz: int, n: int, h: PackedFloat32Array) -> void:
	var ox: float = tx * TILE
	var oz: float = tz * TILE
	var has_sea: bool = oz + TILE > TerrainFn.coast_z(ox + 512.0) - 900.0
	var has_lake: bool = TerrainFn._has_lake and absf(ox + 512.0 - TerrainFn._lake_center.x) < 1450.0 and absf(oz + 512.0 - TerrainFn._lake_center.y) < 1450.0
	var has_river: bool = not TerrainFn._river_pts.is_empty() and ox + TILE >= TerrainFn._river_min.x and ox <= TerrainFn._river_max.x and oz + TILE >= TerrainFn._river_min.y and oz <= TerrainFn._river_max.y
	if not has_sea and not has_lake and not has_river:
		return

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()

	if has_sea or has_lake:
		var g: int = 16
		var stride: int = (n - 1) / g
		var m: int = n + 2
		var cell_w: float = TILE / g
		for gz: int in g:
			for gx: int in g:
				var cx: float = ox + (gx + 0.5) * cell_w
				var cz: float = oz + (gz + 0.5) * cell_w
				var wy: float = TerrainFn.WATER_NONE
				if has_sea and cz > TerrainFn.coast_z(cx) - 220.0:
					wy = 0.0
				elif has_lake and TerrainFn.lake_signed_dist(cx, cz) < 85.0:
					wy = TerrainFn._lake_y
				if wy <= TerrainFn.WATER_NONE + 1.0:
					continue
				var hi00: float = h[(gz * stride + 1) * m + (gx * stride + 1)]
				var hi10: float = h[(gz * stride + 1) * m + ((gx + 1) * stride + 1)]
				var hi01: float = h[((gz + 1) * stride + 1) * m + (gx * stride + 1)]
				var hi11: float = h[((gz + 1) * stride + 1) * m + ((gx + 1) * stride + 1)]
				if minf(minf(hi00, hi10), minf(hi01, hi11)) > wy + 1.2:
					continue
				var b: int = verts.size()
				var x0: float = gx * cell_w
				var z0: float = gz * cell_w
				var x1: float = x0 + cell_w
				var z1: float = z0 + cell_w
				var hs: PackedFloat32Array = [hi00, hi10, hi11, hi01]
				var xs: PackedFloat32Array = [x0, x1, x1, x0]
				var zs: PackedFloat32Array = [z0, z0, z1, z1]
				for k: int in 4:
					verts.append(Vector3(xs[k], wy, zs[k]))
					norms.append(Vector3.UP)
					uvs.append(Vector2(ox + xs[k], oz + zs[k]))
					cols.append(Color(clampf((wy - hs[k]) / 6.0, 0.0, 1.0), 0.0, 0.0, 1.0))
				idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])

	if has_river:
		var rpts: PackedVector3Array = TerrainFn._river_pts
		var ru: PackedFloat32Array = TerrainFn._river_u
		for i: int in rpts.size() - 1:
			if ru[i] < 0.05:
				continue
			var p0: Vector3 = rpts[i]
			var p1: Vector3 = rpts[i + 1]
			var mid: Vector3 = (p0 + p1) * 0.5
			if floori(mid.x / TILE) != tx or floori(mid.z / TILE) != tz:
				continue
			var b: int = verts.size()
			for j: int in [i, i + 1]:
				var pj: Vector3 = rpts[j]
				var p_prev: Vector3 = rpts[maxi(j - 1, 0)]
				var p_next: Vector3 = rpts[mini(j + 1, rpts.size() - 1)]
				var fwd := Vector3(p_next.x - p_prev.x, 0.0, p_next.z - p_prev.z).normalized()
				var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
				var hw: float = lerpf(16.0, 56.0, smoothstep(0.0, 1.0, ru[j])) + 10.0
				var lp := Vector3(pj.x - ox, pj.y, pj.z - oz)
				verts.append_array([lp - rt * hw, lp, lp + rt * hw])
				norms.append_array([Vector3.UP, Vector3.UP, Vector3.UP])
				uvs.append_array([
					Vector2(pj.x - rt.x * hw, pj.z - rt.z * hw),
					Vector2(pj.x, pj.z),
					Vector2(pj.x + rt.x * hw, pj.z + rt.z * hw),
				])
				cols.append_array([Color(0.08, 1.0, 0.0, 1.0), Color(0.75, 1.0, 0.0, 1.0), Color(0.08, 1.0, 0.0, 1.0)])
			idx.append_array([b, b + 3, b + 1, b + 1, b + 3, b + 4])
			idx.append_array([b + 1, b + 4, b + 2, b + 2, b + 4, b + 5])

	if not verts.is_empty():
		d["water"] = {"verts": verts, "norms": norms, "uvs": uvs, "cols": cols, "idx": idx}


## Quad diagonals run (i+1, j) -> (i, j+1) to match the HeightMapShape3D triangulation.
static func _build_indices(n: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	for j: int in n - 1:
		for i: int in n - 1:
			var a: int = j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var nv: int = n * n
	for i: int in n - 1:
		var e: PackedInt32Array = [i + 1, i, (n - 1) * n + i, (n - 1) * n + i + 1, i * n, (i + 1) * n, (i + 1) * n + n - 1, i * n + n - 1]
		var o: PackedInt32Array = [1, 0, 0, 1, 0, 1, 1, 0]
		for s: int in 4:
			var a: int = e[s * 2]
			var b: int = e[s * 2 + 1]
			var sa: int = nv + s * n + i + o[s * 2]
			var sb: int = nv + s * n + i + o[s * 2 + 1]
			idx.append_array([a, b, sb, a, sb, sa])
	return idx
