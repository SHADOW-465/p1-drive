class_name Scatter
extends RefCounted
## Deterministic procedural scatter (T20 / PLAN §2.6): 4x4 chunks of 256 m per FULL tile,
## tree A (conifer), tree B (broadleaf), rock MultiMesh buffers built in worker threads.

const CHUNKS: int = 4
const CHUNK_SIZE: float = 256.0
const MAX_A: int = 90
const MAX_B: int = 75
const MAX_ROCK: int = 34
const MAX_DENSITY: float = 1.35

static var _meshes: Array[ArrayMesh] = []
static var _mat: StandardMaterial3D


static func ensure_resources() -> void:
	if not _meshes.is_empty():
		return
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.88
	_mat.metallic = 0.0
	_meshes = [_make_conifer(), _make_broadleaf(), _make_rock()]


static func _make_conifer() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	var trunk_c := Color(0.26, 0.16, 0.09).srgb_to_linear()
	var leaf1 := Color(0.11, 0.28, 0.12).srgb_to_linear()
	var leaf2 := Color(0.15, 0.34, 0.14).srgb_to_linear()
	_prism(4, 0.0, 2.6, 0.28, 0.18, trunk_c, v, n, c, idx)
	_cone(5, 2.0, 6.2, 1.9, leaf1, v, n, c, idx)
	_cone(5, 4.4, 8.6, 1.35, leaf2, v, n, c, idx)
	return _to_mesh(v, n, c, idx)


static func _make_broadleaf() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	var trunk_c := Color(0.29, 0.19, 0.11).srgb_to_linear()
	var leaf1 := Color(0.18, 0.38, 0.13).srgb_to_linear()
	var leaf2 := Color(0.24, 0.44, 0.16).srgb_to_linear()
	_prism(4, 0.0, 3.0, 0.30, 0.20, trunk_c, v, n, c, idx)
	_crown(6, 3.0, 6.2, 2.2, leaf1, v, n, c, idx)
	_crown(6, 5.0, 7.6, 1.55, leaf2, v, n, c, idx)
	return _to_mesh(v, n, c, idx)


static func _make_rock() -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	var rc := Color(0.42, 0.41, 0.39).srgb_to_linear()
	_crown(6, -0.2, 1.15, 1.1, rc, v, n, c, idx)
	return _to_mesh(v, n, c, idx)


static func _prism(sides: int, y0: float, y1: float, r0: float, r1: float, col: Color, v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> void:
	for i: int in sides:
		var a0: float = TAU * i / sides
		var a1: float = TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
		var p1 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
		var p2 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
		var p3 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
		var nrm := Vector3(cos((a0 + a1) * 0.5), 0.15, sin((a0 + a1) * 0.5)).normalized()
		var b: int = v.size()
		v.append_array([p0, p3, p2, p1])
		n.append_array([nrm, nrm, nrm, nrm])
		c.append_array([col, col, col, col])
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])


static func _cone(sides: int, y0: float, y1: float, r: float, col: Color, v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> void:
	var top := Vector3(0.0, y1, 0.0)
	for i: int in sides:
		var a0: float = TAU * i / sides
		var a1: float = TAU * (i + 1) / sides
		var p0 := Vector3(cos(a0) * r, y0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y0, sin(a1) * r)
		var nrm: Vector3 = (p1 - p0).cross(top - p0).normalized()
		var b: int = v.size()
		v.append_array([p0, top, p1])
		n.append_array([nrm, nrm, nrm])
		c.append_array([col, col * 1.15, col])
		idx.append_array([b, b + 1, b + 2])


static func _crown(sides: int, y0: float, y1: float, r: float, col: Color, v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> void:
	var ym: float = lerpf(y0, y1, 0.45)
	_prism(sides, y0, ym, r * 0.65, r, col * 0.9, v, n, c, idx)
	_cone(sides, ym, y1, r, col, v, n, c, idx)


static func _to_mesh(v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> ArrayMesh:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_COLOR] = c
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


## Worker-side scatter build: returns array of 16 chunk dicts {pos, aabb, bufs:[buf0, buf1, buf2]}.
static func build(tx: int, tz: int, n: int, h: PackedFloat32Array, bw: PackedFloat32Array) -> Array:
	var hero_cfg: Dictionary = TerrainFn.def.get("hero_tiles", {})
	var h_key: String = "%d,%d" % [tx, tz]
	if hero_cfg.has(h_key) and bool((hero_cfg[h_key] as Dictionary).get("no_scatter", false)):
		return []
	var chunks: Array = []
	var m: int = n + 2
	var cell: float = TileGen.TILE / (n - 1)
	var ox: float = tx * TileGen.TILE
	var oz: float = tz * TileGen.TILE
	var rng := RandomNumberGenerator.new()
	for cz: int in CHUNKS:
		for cx: int in CHUNKS:
			rng.seed = hash(Vector4i(TerrainFn.world_seed, tx * 16 + cx, tz * 16 + cz, 71))
			var bufs: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
			var c_min_y: float = 1e9
			var c_max_y: float = -1e9
			var x_base: float = cx * CHUNK_SIZE
			var z_base: float = cz * CHUNK_SIZE
			var c_center := Vector3(x_base + CHUNK_SIZE * 0.5, 0.0, z_base + CHUNK_SIZE * 0.5)
			# First pass collects world heights to place chunk origin at mean_y.
			var items: Array[Array] = [[], [], []]
			var y_sum: float = 0.0
			var y_cnt: int = 0
			var caps: PackedInt32Array = [MAX_A, MAX_B, MAX_ROCK]
			for type_i: int in 3:
				for _k: int in caps[type_i]:
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
					if bench > 0.25:
						continue
					var y: float = lerpf(lerpf(h[q], h[q + 1], fx), lerpf(h[q + m], h[q + m + 1], fx), fz)
					if y < 1.2:
						continue
					var ny: float = (2.0 * cell) / sqrt(pow(h[q - 1] - h[q + 1], 2.0) + pow(2.0 * cell, 2.0) + pow(h[q - m] - h[q + m], 2.0))
					if ny < 0.819:
						continue
					var w: PackedFloat32Array = TerrainFn.biome_weights(ox + lx, oz + lz)
					if w[TerrainFn.CITY] > 0.25:
						continue
					var prob: float
					if type_i < 2:
						prob = w[TerrainFn.COUNTRY] * 0.42 + w[TerrainFn.HILLS] * 0.88 + w[TerrainFn.MOUNTAIN] * (0.28 if y < 230.0 else 0.04) + w[TerrainFn.COAST] * 0.18
						if type_i == 0 and w[TerrainFn.MOUNTAIN] + w[TerrainFn.HILLS] < 0.25:
							prob *= 0.55
						if type_i == 1 and w[TerrainFn.MOUNTAIN] > 0.4:
							prob *= 0.3
					else:
						prob = w[TerrainFn.COUNTRY] * 0.18 + w[TerrainFn.HILLS] * 0.35 + w[TerrainFn.MOUNTAIN] * 0.85 + w[TerrainFn.COAST] * 0.45
					if rng.randf() > prob:
						continue
					var yaw: float = rng.randf() * TAU
					var sc: float = rng.randf_range(0.75, 1.35) if type_i < 2 else rng.randf_range(0.65, 1.9)
					var tint: float = rng.randf_range(0.84, 1.16)
					var col := Color(tint, tint * rng.randf_range(0.95, 1.05), tint, 1.0)
					items[type_i].append([Vector3(lx, y - 0.15, lz), yaw, sc, col])
					c_min_y = minf(c_min_y, y - 1.0)
					c_max_y = maxf(c_max_y, y + (11.0 if type_i < 2 else 3.0))
					y_sum += y
					y_cnt += 1
			if y_cnt == 0:
				continue
			c_center.y = y_sum / y_cnt
			for type_i: int in 3:
				var arr: Array = items[type_i]
				if arr.is_empty():
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
				"aabb": AABB(Vector3(-CHUNK_SIZE * 0.52, c_min_y - c_center.y, -CHUNK_SIZE * 0.52), Vector3(CHUNK_SIZE * 1.04, maxf(c_max_y - c_min_y, 8.0), CHUNK_SIZE * 1.04)),
				"bufs": bufs,
			})
	return chunks


## Applies settings (density / range) to an existing MultiMeshInstance3D.
static func apply_settings_to_mmi(mmi: MultiMeshInstance3D) -> void:
	mmi.visibility_range_end = Settings.scatter_range
	mmi.visibility_range_end_margin = 30.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.is_high() else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm: MultiMesh = mmi.multimesh
	if mm != null:
		mm.visible_instance_count = clampi(roundi(mm.instance_count * (Settings.scatter_density / MAX_DENSITY)), 0, mm.instance_count)
