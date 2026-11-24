class_name Scatter
extends RefCounted
## Deterministic procedural scatter (T20 / R3): 4x4 chunks of 256 m per FULL tile,
## real CC0 tree/shrub/fern/rock/roadside-grass MultiMesh buffers with LOD0/LOD1 & dither fade.

const CHUNKS: int = 4
const CHUNK_SIZE: float = 256.0
const MAX_DENSITY: float = 1.35

enum { CONIFER, PINE, OAK, SHRUB, FERN, ROCK, GRASS, SAKURA, TYPE_COUNT }  # SAKURA: Tokyo region only

const CAPS: PackedInt32Array = [128, 96, 28, 48, 56, 18, 0, 10]  # GRASS is road-placed
const HAS_LOD1: PackedByteArray = [1, 1, 1, 0, 0, 1, 0, 1]
const VIS_LOD0_END: PackedFloat32Array = [150.0, 150.0, 150.0, 120.0, 90.0, 110.0, 80.0, 120.0]
const VIS_LOD1_START: PackedFloat32Array = [120.0, 120.0, 120.0, 0.0, 0.0, 80.0, 0.0, 60.0]
const VIS_MAX_END: PackedFloat32Array = [999.0, 999.0, 999.0, 120.0, 90.0, 999.0, 80.0, 999.0]
# Scale-1 crown half extent and height of each LOD0 mesh (baked .res AABBs) and the clear zone kept between it and a road's
# shoulder: no trunk, crown, shrub or rock stands in a road corridor (RoadMesher.corridor_edge).
const CROWN: PackedFloat32Array = [2.95, 4.17, 2.98, 0.5, 1.2, 2.2, 0.4, 4.2]  # half width of baked tree AABBs (synced Nov 22)
const HEIGHT: PackedFloat32Array = [10.0, 12.5, 9.5, 1.6, 1.2, 1.2, 0.55, 9.0]
const CLEAR_ZONE: PackedFloat32Array = [2.0, 2.0, 2.0, 0.6, 0.4, 1.0, 0.2, 2.0]

static var _lod0_meshes: Array[ArrayMesh] = []
static var _lod1_meshes: Array[ArrayMesh] = []
static var _lod1_mats: Array[Array] = []  # per type: Array[ShaderMaterial] for live range updates


static func ensure_resources() -> void:
	if not _lod0_meshes.is_empty():
		return
	var foliage_shader := load("res://shaders/foliage.gdshader") as Shader
	var rock_shader := load("res://shaders/rock.gdshader") as Shader

	var bark_a_diff := load("res://assets/textures/nature/bark_brown_01/bark_brown_01_diff_1k.jpg") as Texture2D
	var bark_a_nor := load("res://assets/textures/nature/bark_brown_01/bark_brown_01_nor_gl_1k.jpg") as Texture2D
	var bark_a_arm := load("res://assets/textures/nature/bark_brown_01/bark_brown_01_arm_1k.jpg") as Texture2D
	var bark_b_diff := load("res://assets/textures/nature/bark_willow/bark_willow_diff_1k.jpg") as Texture2D
	var bark_b_nor := load("res://assets/textures/nature/bark_willow/bark_willow_nor_gl_1k.jpg") as Texture2D
	var bark_b_arm := load("res://assets/textures/nature/bark_willow/bark_willow_arm_1k.jpg") as Texture2D
	var leaf_diff := load("res://assets/textures/ground/leafy_grass/leafy_grass_diffuse_1k.jpg") as Texture2D
	var leaf_nor := load("res://assets/textures/ground/leafy_grass/leafy_grass_nor_gl_1k.jpg") as Texture2D
	var leaf_arm := load("res://assets/textures/ground/leafy_grass/leafy_grass_arm_1k.jpg") as Texture2D

	var tree_specs: Array[Array] = [
		["tree_conifer", bark_a_diff, bark_a_nor, bark_a_arm, Color(0.40, 0.62, 0.36), 10.0, 0.06],
		["tree_pine", bark_a_diff, bark_a_nor, bark_a_arm, Color(0.44, 0.66, 0.40), 12.5, 0.05],
		["tree_oak", bark_b_diff, bark_b_nor, bark_b_arm, Color(0.84, 0.96, 0.72), 9.5, 0.07],
	]
	for ti: int in tree_specs.size():
		var sp: Array = tree_specs[ti]
		var bark0 := _fol_mat(foliage_shader, sp[1], sp[2], sp[3], Color(1.0, 0.90, 0.84), 2.5, 0.0, 0.02, sp[5], 0.92, 1.0, 0.0, 0.0)
		var fol0 := _fol_mat(foliage_shader, leaf_diff, leaf_nor, leaf_arm, sp[4], 1.6, 0.32, sp[6], sp[5], 0.68, 0.80, 0.25, 0.0)
		var bark1 := bark0.duplicate() as ShaderMaterial
		var fol1 := fol0.duplicate() as ShaderMaterial
		_add_lod_pair("res://assets/models/nature/baked/%s" % sp[0], [bark0, fol0], [bark1, fol1], ti)

	var ph_specs: Array[Array] = [
		["shrub", "res://assets/models/nature/shrub_03/textures/shrub_03", Color(1.04, 1.14, 0.96), 1.35, 0.04, 0.42, SHRUB],
		["fern", "res://assets/models/nature/fern_02/textures/fern_02", Color(1.02, 1.12, 0.92), 0.95, 0.05, 0.42, FERN],
	]
	for ps: Array in ph_specs:
		var pfx: String = ps[1]
		var m0 := _fol_mat(
			foliage_shader,
			load(pfx + "_diff_1k.jpg") as Texture2D,
			load(pfx + "_nor_gl_1k.jpg") as Texture2D,
			load(pfx + "_arm_1k.jpg") as Texture2D,
			ps[2], 1.0, ps[5], ps[4], ps[3], 0.72, 0.55, 0.48, 0.0
		)
		var m1 := m0.duplicate() as ShaderMaterial
		_add_lod_pair("res://assets/models/nature/baked/%s" % ps[0], [m0], [m1], ps[6])

	var r_pfx: String = "res://assets/models/nature/rock_09/textures/rock_09"
	var rm0 := _rock_mat(
		rock_shader,
		load(r_pfx + "_diff_1k.jpg") as Texture2D,
		load(r_pfx + "_nor_gl_1k.jpg") as Texture2D,
		load(r_pfx + "_arm_1k.jpg") as Texture2D
	)
	var rm1 := rm0.duplicate() as ShaderMaterial
	_add_lod_pair("res://assets/models/nature/baked/rock_a", [rm0], [rm1], ROCK)

	var gm0 := _fol_mat(
		foliage_shader,
		load("res://assets/models/nature/grass_bermuda_01/textures/grass_bermuda_01_diff_1k.png") as Texture2D,
		load("res://assets/models/nature/grass_bermuda_01/textures/grass_bermuda_01_nor_gl_1k.jpg") as Texture2D,
		load("res://assets/models/nature/grass_bermuda_01/textures/grass_bermuda_01_arm_1k.jpg") as Texture2D,
		Color(1.06, 1.16, 0.92), 1.0, 0.46, 0.055, 0.42, 0.65, 0.40, 0.60, 0.28
	)
	_add_lod_pair("res://assets/models/nature/baked/grass", [gm0], [], GRASS)
	var sk_bark := _fol_mat(foliage_shader, bark_a_diff, bark_a_nor, bark_a_arm, Color(1.0, 0.90, 0.90), 2.5, 0.0, 0.02, 9.0, 0.92, 1.0, 0.0, 0.0)
	var sk_fol := _fol_mat(foliage_shader, leaf_diff, leaf_nor, leaf_arm, Color(1.0, 0.78, 0.86), 1.6, 0.32, 0.06, 9.0, 0.68, 0.80, 0.25, 0.0)
	_add_lod_pair("res://assets/models/nature/baked/tree_sakura", [sk_bark, sk_fol], [sk_bark.duplicate(), sk_fol.duplicate()], SAKURA)
	update_shader_ranges()


static func _add_lod_pair(base_path: String, mats0: Array, mats1: Array, ti: int) -> void:
	var m0 := (load(base_path + "_lod0.res") as ArrayMesh).duplicate() as ArrayMesh
	var e0: float = VIS_LOD0_END[ti]
	for si: int in mini(m0.get_surface_count(), mats0.size()):
		var mat0: ShaderMaterial = mats0[si]
		mat0.set_shader_parameter("fade_in_start", -10.0)
		mat0.set_shader_parameter("fade_in_end", -5.0)
		mat0.set_shader_parameter("fade_out_start", e0 - 32.0)
		mat0.set_shader_parameter("fade_out_end", e0 - 3.0)
		m0.surface_set_material(si, mat0)
	_lod0_meshes.append(m0)

	if HAS_LOD1[ti] == 1:
		var m1 := (load(base_path + "_lod1.res") as ArrayMesh).duplicate() as ArrayMesh
		var s1: float = VIS_LOD1_START[ti]
		var l1_list: Array = []
		for si: int in mini(m1.get_surface_count(), mats1.size()):
			var mat1: ShaderMaterial = mats1[si]
			mat1.set_shader_parameter("fade_in_start", s1 + 2.0)
			mat1.set_shader_parameter("fade_in_end", s1 + 28.0)
			m1.surface_set_material(si, mat1)
			l1_list.append(mat1)
		_lod1_meshes.append(m1)
		_lod1_mats.append(l1_list)
	else:
		_lod1_meshes.append(null)
		_lod1_mats.append([])


static func _fol_mat(sh: Shader, diff: Texture2D, nor: Texture2D, arm: Texture2D, tint: Color, uv_sc: float, bl: float, wind: float, wind_h: float, rough_sc: float, n_str: float, n_up: float = 0.0, a_cut: float = 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tex_diff", diff)
	m.set_shader_parameter("tex_nor", nor)
	m.set_shader_parameter("tex_arm", arm)
	m.set_shader_parameter("albedo_tint", tint)
	m.set_shader_parameter("uv_scale", uv_sc)
	m.set_shader_parameter("alpha_scissor", a_cut)
	m.set_shader_parameter("backlight_strength", bl)
	m.set_shader_parameter("wind_amp", wind)
	m.set_shader_parameter("wind_height_scale", wind_h)
	m.set_shader_parameter("roughness_scale", rough_sc)
	m.set_shader_parameter("normal_strength", n_str)
	m.set_shader_parameter("normal_up_bias", n_up)
	return m


static func _rock_mat(sh: Shader, diff: Texture2D, nor: Texture2D, arm: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("tex_diff", diff)
	m.set_shader_parameter("tex_nor", nor)
	m.set_shader_parameter("tex_arm", arm)
	return m


static func update_shader_ranges() -> void:
	if _lod1_mats.is_empty():
		return
	for ti: int in TYPE_COUNT:
		var end_r: float = minf(Settings.scatter_range, VIS_MAX_END[ti])
		var fade_s: float = maxf(VIS_LOD1_START[ti] + 32.0, end_r - 40.0)
		for mat: ShaderMaterial in _lod1_mats[ti]:
			mat.set_shader_parameter("fade_out_start", fade_s)
			mat.set_shader_parameter("fade_out_end", end_r)


static func get_lod0_mesh(ti: int) -> ArrayMesh:
	return _lod0_meshes[ti]


static func get_lod1_mesh(ti: int) -> ArrayMesh:
	return _lod1_meshes[ti]


## Worker-side scatter build: returns array of chunk dicts {pos, aabb, bufs:[buf0..buf7]}.
static func build(tx: int, tz: int, n: int, h: PackedFloat32Array, bw: PackedFloat32Array) -> Array:
	var hero_cfg: Dictionary = TerrainFn.def.get("hero_tiles", {})
	var h_key: String = "%d,%d" % [tx, tz]
	if hero_cfg.has(h_key) and bool((hero_cfg[h_key] as Dictionary).get("no_scatter", false)):
		return []
	var m: int = n + 2
	var cell: float = TileGen.TILE / (n - 1)
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	var rng := RandomNumberGenerator.new()

	var junc_excl: Array[Vector3] = []  # [x, z, r^2]
	var tile_cx: float = ox + TileGen.TILE * 0.5
	var tile_cz: float = oz + TileGen.TILE * 0.5
	for ni: int in RoadGraph.nodes.size():
		var nk: int = RoadGraph.node_kind[ni]
		if nk == RoadGraph.NODE_ROUNDABOUT or nk == RoadGraph.NODE_MERGE:
			var np: Vector3 = RoadGraph.nodes[ni]
			if absf(np.x - tile_cx) < 650.0 and absf(np.z - tile_cz) < 650.0:
				var clr: float = (RoadGraph.node_radius[ni] + 10.0) if nk == RoadGraph.NODE_ROUNDABOUT else 54.0
				junc_excl.append(Vector3(np.x, np.z, clr * clr))

	# Pre-collect roadside grass into 4x4 chunk buckets
	var grass_chunks: Array[Array] = []
	grass_chunks.resize(CHUNKS * CHUNKS)
	for gi: int in CHUNKS * CHUNKS:
		grass_chunks[gi] = []
	var runs: Array = RoadGraph.runs_in_tile(tx, tz)
	if not runs.is_empty():
		var other_grid: Dictionary[Vector2i, Array] = {}
		if runs.size() > 1:
			for r: Vector3i in runs:
				var oe: int = r.x
				var opts: PackedVector3Array = RoadGraph.e_pts[oe]
				var clr: float = RoadGraph.e_width[oe] * 0.5 + 2.2
				var clr2: float = clr * clr
				var oi: int = r.y
				while oi <= r.z:
					var op: Vector3 = opts[oi]
					var item: Array = [oe, op.x, op.z, clr2]
					for gz_i: int in range(floori((op.z - clr) / 32.0), floori((op.z + clr) / 32.0) + 1):
						for gx_i: int in range(floori((op.x - clr) / 32.0), floori((op.x + clr) / 32.0) + 1):
							var kc := Vector2i(gx_i, gz_i)
							if not other_grid.has(kc):
								other_grid[kc] = []
							other_grid[kc].append(item)
					oi += 4
		_build_road_grass(tx, tz, n, m, cell, ox, oz, h, runs, junc_excl, grass_chunks, other_grid)

	var chunks: Array = []
	for cz: int in CHUNKS:
		for cx: int in CHUNKS:
			var ci: int = cz * CHUNKS + cx
			rng.seed = hash(Vector4i(TerrainFn.world_seed, tx * 16 + cx, tz * 16 + cz, 71))
			var items: Array[Array] = []
			items.resize(TYPE_COUNT)
			for ti: int in TYPE_COUNT:
				items[ti] = []
			items[GRASS] = grass_chunks[ci]

			var c_min_y: float = 1e9
			var c_max_y: float = -1e9
			var x_base: float = cx * CHUNK_SIZE
			var z_base: float = cz * CHUNK_SIZE
			var y_sum: float = 0.0
			var y_cnt: int = 0

			for it_g: Array in (items[GRASS] as Array):
				var gy: float = (it_g[0] as Vector3).y
				c_min_y = minf(c_min_y, gy - 0.5)
				c_max_y = maxf(c_max_y, gy + 1.5)
				y_sum += gy
				y_cnt += 1

			for type_i: int in TYPE_COUNT:
				for _k: int in CAPS[type_i]:
					var lx: float = x_base + rng.randf() * CHUNK_SIZE
					var lz: float = z_base + rng.randf() * CHUNK_SIZE
					var gx: float = lx / cell + 1.0
					var gz: float = lz / cell + 1.0
					var ix: int = clampi(int(gx), 1, n - 1)
					var iz: int = clampi(int(gz), 1, n - 1)
					var fx: float = gx - ix
					var fz: float = gz - iz
					var q: int = iz * m + ix
					var bench: float = maxf(maxf(bw[q], bw[q + 1]), maxf(bw[q + m], bw[q + m + 1])) if not bw.is_empty() else 0.0
					var bench_cut: float = 0.45 if (type_i <= OAK or type_i == SAKURA) else (0.82 if type_i <= FERN else 0.65)
					if bench > bench_cut:
						continue
					var y: float = lerpf(lerpf(h[q], h[q + 1], fx), lerpf(h[q + m], h[q + m + 1], fx), fz)
					var wl: float = TerrainFn.water_level_at(ox + lx, oz + lz)
					if y < 1.2 or (wl > TerrainFn.WATER_NONE + 1.0 and y < wl + 0.8):
						continue
					var ny: float = (2.0 * cell) / sqrt(pow(h[q - 1] - h[q + 1], 2.0) + pow(2.0 * cell, 2.0) + pow(h[q - m] - h[q + m], 2.0))
					# Trees only on gentle ground (~20 deg): a 6 m tree on a steeper slope floats on one side.
					var slope_cut: float = 0.94 if (type_i <= OAK or type_i == SAKURA) else (0.84 if type_i <= FERN else 0.72)
					if ny < slope_cut:
						continue
					var w: PackedFloat32Array = TerrainFn.biome_weights(ox + lx, oz + lz)
					if w[TerrainFn.CITY] > 0.25:
						continue
					if type_i == SAKURA and not _in_tokyo(ox + lx, oz + lz):
						continue
					if _near_junction(ox + lx, oz + lz, junc_excl):
						continue
					var prob: float = _biome_prob(type_i, w, y)
					if rng.randf() > prob:
						continue
					var yaw: float = rng.randf() * TAU
					var sc: float
					if type_i <= PINE:
						var f_boost: float = lerpf(1.0, rng.randf_range(1.38, 2.25), clampf(w[TerrainFn.FOREST] * 1.4, 0.0, 1.0))
						sc = rng.randf_range(0.82, 1.38) * f_boost
					elif type_i == OAK:
						sc = rng.randf_range(0.76, 1.32)
					elif type_i == SAKURA:
						sc = rng.randf_range(0.85, 1.15)
					elif type_i <= FERN:
						sc = rng.randf_range(0.80, 1.45)
					else:
						sc = rng.randf_range(0.60, 1.45)
					var tint: float = rng.randf_range(0.86, 1.14)
					if OsmWorld.enabled and RoadMesher.corridor_edge(ox + lx, oz + lz, y - 1.0, y + HEIGHT[type_i] * sc, CROWN[type_i] * sc + CLEAR_ZONE[type_i]) >= 0:
						continue
					var col := Color(tint * rng.randf_range(0.95, 1.04), tint * rng.randf_range(0.96, 1.06), tint * rng.randf_range(0.94, 1.02), 1.0)
					var sink: float = 0.6 if (type_i <= OAK or type_i == SAKURA) else 0.14  # trunk base buried a little so it meets the slope
					items[type_i].append([Vector3(lx, y - sink, lz), yaw, sc, col])
					c_min_y = minf(c_min_y, y - 1.0)
					c_max_y = maxf(c_max_y, y + (28.0 if type_i <= PINE else (16.0 if (type_i == OAK or type_i == SAKURA) else 3.0)))
					y_sum += y
					y_cnt += 1

			if y_cnt == 0:
				continue
			var c_center := Vector3(x_base + CHUNK_SIZE * 0.5, y_sum / y_cnt, z_base + CHUNK_SIZE * 0.5)
			var bufs: Array[PackedFloat32Array] = []
			bufs.resize(TYPE_COUNT)
			for type_i: int in TYPE_COUNT:
				var arr: Array = items[type_i]
				if arr.is_empty():
					bufs[type_i] = PackedFloat32Array()
					continue
				var buf := PackedFloat32Array()
				buf.resize(arr.size() * 16)
				for idx_i: int in arr.size():
					var it: Array = arr[idx_i]
					var p: Vector3 = (it[0] as Vector3) - c_center
					var yaw: float = it[1]
					var sc: float = it[2]
					var col: Color = it[3]
					var cs: float = cos(yaw) * sc
					var sn: float = sin(yaw) * sc
					var o: int = idx_i * 16
					buf[o] = cs
					buf[o + 1] = 0.0
					buf[o + 2] = sn
					buf[o + 3] = p.x
					buf[o + 4] = 0.0
					buf[o + 5] = sc
					buf[o + 6] = 0.0
					buf[o + 7] = p.y
					buf[o + 8] = -sn
					buf[o + 9] = 0.0
					buf[o + 10] = cs
					buf[o + 11] = p.z
					buf[o + 12] = col.r
					buf[o + 13] = col.g
					buf[o + 14] = col.b
					buf[o + 15] = 1.0
				bufs[type_i] = buf
			chunks.append({
				"pos": c_center,
				"aabb": AABB(Vector3(-CHUNK_SIZE * 0.54, c_min_y - c_center.y, -CHUNK_SIZE * 0.54), Vector3(CHUNK_SIZE * 1.08, maxf(c_max_y - c_min_y, 8.0), CHUNK_SIZE * 1.08)),
				"bufs": bufs,
			})
	return chunks


## Sakura only inside the Tokyo region bounds (data/world/regions/tokyo_hakone.json bounds_m, metres).
static func _in_tokyo(wx: float, wz: float) -> bool:
	return wx >= 1024.0 and wx <= 15600.0 and wz >= -14200.0 and wz <= 2600.0


static func _biome_prob(type_i: int, w: PackedFloat32Array, y: float) -> float:
	match type_i:
		SAKURA:
			return w[TerrainFn.COUNTRY] * 0.22 + w[TerrainFn.HILLS] * 0.10 + w[TerrainFn.COAST] * 0.18
		CONIFER:
			return w[TerrainFn.COUNTRY] * 0.08 + w[TerrainFn.HILLS] * 0.24 + w[TerrainFn.FOREST] * 0.94 + w[TerrainFn.MOUNTAIN] * (0.20 if y < 235.0 else 0.02) + w[TerrainFn.COAST] * 0.03
		PINE:
			return w[TerrainFn.COUNTRY] * 0.05 + w[TerrainFn.HILLS] * 0.18 + w[TerrainFn.FOREST] * 0.90 + w[TerrainFn.MOUNTAIN] * (0.16 if y < 220.0 else 0.01)
		OAK:
			return w[TerrainFn.COUNTRY] * 0.52 + w[TerrainFn.HILLS] * 0.30 + w[TerrainFn.FOREST] * 0.18 + w[TerrainFn.COAST] * 0.24 + w[TerrainFn.MOUNTAIN] * 0.03
		SHRUB:
			return w[TerrainFn.COUNTRY] * 0.32 + w[TerrainFn.HILLS] * 0.42 + w[TerrainFn.FOREST] * 0.85 + w[TerrainFn.DESERT] * 0.14 + w[TerrainFn.COAST] * 0.30 + w[TerrainFn.MOUNTAIN] * (0.18 if y < 245.0 else 0.02)
		FERN:
			return w[TerrainFn.COUNTRY] * 0.14 + w[TerrainFn.HILLS] * 0.35 + w[TerrainFn.FOREST] * 0.92 + w[TerrainFn.MOUNTAIN] * (0.10 if y < 200.0 else 0.0)
		ROCK:
			return w[TerrainFn.COUNTRY] * 0.16 + w[TerrainFn.HILLS] * 0.36 + w[TerrainFn.FOREST] * 0.24 + w[TerrainFn.DESERT] * 0.52 + w[TerrainFn.MOUNTAIN] * 0.85 + w[TerrainFn.COAST] * 0.45
	return 0.0


static func _build_road_grass(tx: int, tz: int, n: int, m: int, cell: float, ox: float, oz: float, h: PackedFloat32Array, runs: Array, junc_excl: Array[Vector3], grass_chunks: Array[Array], other_grid: Dictionary[Vector2i, Array] = {}) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(TerrainFn.world_seed, tx, tz)) ^ 0x5A17
	for r: Vector3i in runs:
		var e: int = r.x
		var type: int = RoadGraph.e_type[e]
		if type == RoadGraph.CITY or RoadGraph.e_elev[e] == 1:
			continue
		var pts: PackedVector3Array = RoadGraph.e_pts[e]
		var rng_e: Vector2i = RoadMesher.edge_range(e)
		var hw: float = RoadGraph.e_width[e] * 0.5
		var sw: float = RoadMesher.SHOULDER_W[type]
		var min_lat: float = hw + sw + (2.6 if type == RoadGraph.HIGHWAY else 1.8)
		var max_lat: float = hw + sw + 10.0
		var k: int = maxi(r.y, rng_e.x)
		var end_k: int = mini(r.z, rng_e.y)
		var check_other: bool = runs.size() > 1
		while k <= end_k and k < pts.size():
			var p: Vector3 = pts[k]
			var lx0: float = p.x - ox
			var lz0: float = p.z - oz
			if lx0 >= -12.0 and lx0 <= TileGen.TILE + 12.0 and lz0 >= -12.0 and lz0 <= TileGen.TILE + 12.0:
				var fwd: Vector3 = RoadGraph.tangent(e, k)
				var rt: Vector3 = fwd.cross(Vector3.UP).normalized()
				for side: float in [-1.0, 1.0]:
					for _sub: int in 3:
						var lat: float = side * rng.randf_range(min_lat, max_lat)
						var fwd_jit: float = rng.randf_range(-3.6, 3.6)
						var wx: float = p.x + rt.x * lat + fwd.x * fwd_jit
						var wz: float = p.z + rt.z * lat + fwd.z * fwd_jit
						var lx: float = wx - ox
						var lz: float = wz - oz
						if lx < 0.5 or lx >= TileGen.TILE - 0.5 or lz < 0.5 or lz >= TileGen.TILE - 0.5:
							continue
						var gx: float = lx / cell + 1.0
						var gz: float = lz / cell + 1.0
						var ix: int = clampi(int(gx), 1, n - 1)
						var iz: int = clampi(int(gz), 1, n - 1)
						var fx: float = gx - ix
						var fz: float = gz - iz
						var q: int = iz * m + ix
						var y: float = lerpf(lerpf(h[q], h[q + 1], fx), lerpf(h[q + m], h[q + m + 1], fx), fz)
						var wl: float = TerrainFn.water_level_at(wx, wz)
						if y < 1.8 or (wl > TerrainFn.WATER_NONE + 1.0 and y < wl + 0.8):
							continue
						var ny: float = (2.0 * cell) / sqrt(pow(h[q - 1] - h[q + 1], 2.0) + pow(2.0 * cell, 2.0) + pow(h[q - m] - h[q + m], 2.0))
						if ny < 0.82:
							continue
						var w: PackedFloat32Array = TerrainFn.biome_weights(wx, wz)
						if w[TerrainFn.CITY] > 0.30 or w[TerrainFn.DESERT] > 0.55:
							continue
						if check_other and _near_other_road(wx, wz, e, other_grid):
							continue
						if _near_junction(wx, wz, junc_excl):
							continue
						var cx: int = clampi(int(lx / CHUNK_SIZE), 0, CHUNKS - 1)
						var cz: int = clampi(int(lz / CHUNK_SIZE), 0, CHUNKS - 1)
						var yaw: float = rng.randf() * TAU
						var sc: float = rng.randf_range(1.45, 2.35)
						if OsmWorld.enabled and RoadMesher.corridor_edge(wx, wz, y - 1.0, y + HEIGHT[GRASS] * sc, CROWN[GRASS] * sc + CLEAR_ZONE[GRASS]) >= 0:
							continue
						var tint: float = rng.randf_range(0.82, 1.15)
						var col := Color(tint * rng.randf_range(0.94, 1.05), tint * rng.randf_range(0.97, 1.06), tint * rng.randf_range(0.88, 1.0), 1.0)
						grass_chunks[cz * CHUNKS + cx].append([Vector3(lx, y - 0.05, lz), yaw, sc, col])
			k += 2


static func _near_junction(wx: float, wz: float, junc_excl: Array[Vector3]) -> bool:
	for j: Vector3 in junc_excl:
		var dx: float = wx - j.x
		var dz: float = wz - j.y
		if dx * dx + dz * dz < j.z:
			return true
	return false


static func _near_other_road(wx: float, wz: float, own_edge: int, other_grid: Dictionary[Vector2i, Array]) -> bool:
	var cell_items: Variant = other_grid.get(Vector2i(floori(wx / 32.0), floori(wz / 32.0)))
	if cell_items == null:
		return false
	for it: Array in cell_items as Array:
		if int(it[0]) == own_edge:
			continue
		var dx: float = wx - float(it[1])
		var dz: float = wz - float(it[2])
		if dx * dx + dz * dz < float(it[3]):
			return true
	return false


## Applies settings (density / range / shadows / preset) to an existing MultiMeshInstance3D.
static func apply_settings_to_mmi(mmi: MultiMeshInstance3D) -> void:
	var ti: int = int(mmi.get_meta("scatter_type", 0))
	var lod_i: int = int(mmi.get_meta("scatter_lod", 0))
	if ti == GRASS:
		mmi.visible = (Settings.preset != "low")
	else:
		mmi.visible = true
	if lod_i == 0:
		mmi.visibility_range_begin = 0.0
		mmi.visibility_range_begin_margin = 0.0
		mmi.visibility_range_end = minf(VIS_LOD0_END[ti], Settings.scatter_range)
		mmi.visibility_range_end_margin = 0.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if (Settings.shadow_quality >= 3 and ti != GRASS and ti != FERN and ti != SHRUB) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		mmi.visibility_range_begin = VIS_LOD1_START[ti]
		mmi.visibility_range_begin_margin = 0.0
		mmi.visibility_range_end = minf(Settings.scatter_range, VIS_MAX_END[ti])
		mmi.visibility_range_end_margin = 0.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	var mm: MultiMesh = mmi.multimesh
	if mm != null:
		mm.visible_instance_count = clampi(roundi(mm.instance_count * (Settings.scatter_density / MAX_DENSITY)), 0, mm.instance_count)
