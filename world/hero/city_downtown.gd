extends Node3D
## Downtown city hero (M3): 4x4 blocks inside tile (5, 5) around tile-local (512, 20, 512).
## Per block: ONE merged facade mesh (LOD0) + one simplified prism mesh (LOD1), one box occluder and one box
## collider. One skyline impostor mesh per tile. Facades use the 2-texture atlas shader (building.gdshader).

const GRID_ORIGIN: Vector2 = Vector2(512.0, 512.0)  # tile-local center of tile (5, 5)
const PITCH: float = 140.0
const GROUND_Y: float = TerrainFn.CITY_Y
const ROAD_CLEAR: float = 14.0  # half street width + sidewalk + margin
const B_TEX: String = "res://assets/textures/buildings/"

static var _mat: ShaderMaterial
static var _mat_lod: ShaderMaterial
static var _blocks: Array[Dictionary] = []  # {pos, lod0, lod1, occ_size, box_size, box_pos}
static var _sky: ArrayMesh
static var _cached_tree_buf: PackedFloat32Array
static var _cached_shrub_buf: PackedFloat32Array


func _ready() -> void:
	Scatter.ensure_resources()
	_ensure_data()
	var low: bool = Settings.preset == "low"
	var lod0_end: float = 180.0 if low else 280.0
	var lod1_end: float = 700.0 if low else 900.0
	var shadows: bool = Settings.shadow_quality >= 2
	var body := StaticBody3D.new()
	body.name = "CityColliders"
	add_child(body)
	for b: Dictionary in _blocks:
		var blk := Node3D.new()
		blk.position = b["pos"]
		add_child(blk)
		var m0 := MeshInstance3D.new()
		m0.name = "Buildings_LOD0"
		m0.mesh = b["lod0"]
		m0.material_override = _mat
		m0.visibility_range_end = lod0_end
		m0.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		blk.add_child(m0)
		var m1 := MeshInstance3D.new()
		m1.name = "Buildings_LOD1"
		m1.mesh = b["lod1"]
		m1.material_override = _mat_lod
		m1.visibility_range_begin = lod0_end
		m1.visibility_range_end = lod1_end
		m1.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		blk.add_child(m1)
		var osz: Vector3 = b["occ_size"]
		if osz.y > 0.0:
			var occ := OccluderInstance3D.new()
			var bo := BoxOccluder3D.new()
			bo.size = osz
			occ.occluder = bo
			occ.position = Vector3(0.0, osz.y * 0.5, 0.0)
			blk.add_child(occ)
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = b["box_size"]
		cs.shape = sh
		cs.position = (b["pos"] as Vector3) + (b["box_pos"] as Vector3)
		body.add_child(cs)
	var sky := MeshInstance3D.new()
	sky.name = "Skyline_LOD2"
	sky.mesh = _sky
	sky.material_override = _mat_lod
	sky.visibility_range_begin = lod1_end
	sky.visibility_range_end = 3200.0
	sky.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sky)
	_add_mmi("CityTrees", Scatter.get_lod0_mesh(Scatter.OAK), _cached_tree_buf, 100.0 if low else 140.0)
	_add_mmi("CityShrubs", Scatter.get_lod0_mesh(Scatter.SHRUB), _cached_shrub_buf, 70.0)


func _add_mmi(nm: String, mesh: Mesh, buf: PackedFloat32Array, vis_end: float) -> void:
	if buf.is_empty():
		return
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = buf.size() / 16
	mm.buffer = buf
	mmi.multimesh = mm
	mmi.visibility_range_end = vis_end
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


static func prewarm() -> void:
	Scatter.ensure_resources()
	_ensure_data()


static func _ensure_data() -> void:
	if _sky != null:
		return
	var diff: Texture2D = load(B_TEX + "atlas_diff.png")
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/building.gdshader")
	_mat.set_shader_parameter("atlas_diff", diff)
	_mat.set_shader_parameter("atlas_nra", load(B_TEX + "atlas_nra.png"))
	_mat.set_shader_parameter("normals_on", 0.0 if Settings.preset == "low" else 1.0)
	_mat_lod = ShaderMaterial.new()
	_mat_lod.shader = preload("res://shaders/building_lod.gdshader")
	_mat_lod.set_shader_parameter("atlas_diff", diff)

	var rng := RandomNumberGenerator.new()
	rng.seed = 202611
	var palette: PackedColorArray = [
		Color(0.55, 0.62, 0.70).srgb_to_linear(),  # cool glass/steel tint
		Color(0.72, 0.71, 0.69).srgb_to_linear(),  # architectural concrete
		Color(0.78, 0.68, 0.62).srgb_to_linear(),  # warm brick
		Color(0.68, 0.64, 0.58).srgb_to_linear(),  # sandstone/brick
		Color(0.52, 0.56, 0.62).srgb_to_linear(),  # slate tower
	]
	var trees: Array[Array] = []
	var shrubs: Array[Array] = []
	var sky := _Mesh.new()

	for bz: int in range(-2, 2):
		for bx: int in range(-2, 2):
			var cx: float = GRID_ORIGIN.x + (bx + 0.5) * PITCH
			var cz: float = GRID_ORIGIN.y + (bz + 0.5) * PITCH
			var inner: float = PITCH - 2.0 * ROAD_CLEAR  # ~112 m usable block
			var is_core: bool = (bx >= -1 and bx <= 0 and bz >= -1 and bz <= 0)
			var m0 := _Mesh.new()
			var m1 := _Mesh.new()
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			var max_h: float = 0.0
			var min_h: float = INF
			var occluder: bool = true
			if bx == -2 and bz == 1:
				# Civic plaza block: low-rise glass pavilion + a small oak grove + landscaped shrubs
				var p_seed: float = (1 + rng.randf_range(0.08, 0.88)) / 4.0
				m0.box(Vector3.ZERO, Vector3(34.0, 9.5, 34.0), palette[1], p_seed)
				m1.box(Vector3.ZERO, Vector3(34.0, 9.5, 34.0), palette[1], p_seed)
				lo = Vector2(-17.0, -17.0)
				hi = Vector2(17.0, 17.0)
				max_h = 9.5
				occluder = false
				for ti: int in 5:
					var ang: float = ti * TAU / 5.0 + 0.3
					var rad: float = 34.0 + (ti % 2) * 8.0
					trees.append([Vector3(cx + cos(ang) * rad, GROUND_Y, cz + sin(ang) * rad), rng.randf() * TAU, rng.randf_range(0.78, 1.05), Color(0.95, 1.0, 0.92, 1.0)])
				for si: int in 8:
					var ang: float = si * TAU / 8.0
					var rad: float = 23.0 + (si % 3) * 4.5
					shrubs.append([Vector3(cx + cos(ang) * rad, GROUND_Y, cz + sin(ang) * rad), rng.randf() * TAU, rng.randf_range(0.9, 1.4), Color(0.95, 1.0, 0.90, 1.0)])
			else:
				# Corner street trees safely inside block edges (fewer than before: they are the costliest draws)
				for cy_s: float in [-1.0, 1.0]:
					for cx_s: float in [-1.0, 1.0]:
						if rng.randf() < 0.3:
							var tx_p: float = cx + cx_s * (inner * 0.47)
							var tz_p: float = cz + cy_s * (inner * 0.47)
							trees.append([Vector3(tx_p, GROUND_Y, tz_p), rng.randf() * TAU, rng.randf_range(0.62, 0.85), Color(0.92, 0.98, 0.88, 1.0)])
				# 2x2 sub-lots per block
				var lot: float = inner * 0.42
				for sz: int in 2:
					for sx: int in 2:
						if rng.randf() < 0.12:
							continue
						var lx: float = (sx - 0.5) * (inner * 0.48)
						var lz: float = (sz - 0.5) * (inner * 0.48)
						var w: float = rng.randf_range(lot * 0.62, lot * 0.88)
						var d: float = rng.randf_range(lot * 0.62, lot * 0.88)
						var h: float = rng.randf_range(42.0, 112.0) if is_core else rng.randf_range(15.0, 46.0)
						var style: int = rng.randi_range(0, 1) if is_core else rng.randi_range(1, 3)
						var col: Color = palette[style if style < palette.size() else 0]
						var seed_a: float = (style + rng.randf_range(0.06, 0.92)) / 4.0
						var top: float = h
						if is_core and h > 58.0:
							# Podium + main tower + upper stepped setback (no bottom faces, so no hidden overlap)
							var pod_h: float = rng.randf_range(10.0, 15.0)
							m0.box(Vector3(lx, 0.0, lz), Vector3(w, pod_h, d), col, seed_a)
							var tw: float = w * rng.randf_range(0.74, 0.86)
							var td: float = d * rng.randf_range(0.74, 0.86)
							m0.box(Vector3(lx, pod_h, lz), Vector3(tw, h - pod_h, td), col, seed_a)
							var top_h: float = rng.randf_range(8.0, 18.0)
							m0.box(Vector3(lx, h, lz), Vector3(tw * 0.58, top_h, td * 0.58), palette[1], (1 + rng.randf_range(0.1, 0.8)) / 4.0)
							top = h + top_h
						else:
							m0.box(Vector3(lx, 0.0, lz), Vector3(w, h, d), col, seed_a)
							if rng.randf() < 0.7:
								var mh: float = rng.randf_range(2.5, 4.8)
								m0.box(Vector3(lx + rng.randf_range(-2.0, 2.0), h, lz + rng.randf_range(-2.0, 2.0)), Vector3(w * 0.34, mh, d * 0.34), palette[1], (1 + 0.5) / 4.0)
								top = h + mh
						m1.box(Vector3(lx, 0.0, lz), Vector3(w, top, d), col, seed_a)
						lo = lo.min(Vector2(lx - w * 0.5, lz - d * 0.5))
						hi = hi.max(Vector2(lx + w * 0.5, lz + d * 0.5))
						max_h = maxf(max_h, top)
						min_h = minf(min_h, h)
			if max_h <= 0.0:
				continue  # every lot skipped
			var ctr: Vector2 = (lo + hi) * 0.5
			var ext: Vector2 = hi - lo
			var bpos := Vector3(cx, GROUND_Y, cz)
			sky.box(bpos + Vector3(ctr.x, 0.0, ctr.y), Vector3(ext.x * 0.85, max_h * 0.8, ext.y * 0.85), palette[(bx + 2) % palette.size()], (1 + 0.5) / 4.0)
			_blocks.append({
				"pos": bpos,
				"lod0": m0.mesh(),
				"lod1": m1.mesh(),
				# occluder sits inside the lowest facade so it never hides something that is actually visible
				"occ_size": Vector3(ext.x * 0.8, minf(min_h, 14.0) * 0.9, ext.y * 0.8) if occluder else Vector3.ZERO,
				"box_size": Vector3(ext.x, max_h, ext.y),
				"box_pos": Vector3(ctr.x, max_h * 0.5, ctr.y),
			})
	_sky = sky.mesh()
	_cached_tree_buf = _pack_instances(trees)
	_cached_shrub_buf = _pack_instances(shrubs)


static func _pack_instances(arr: Array[Array]) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	if arr.is_empty():
		return buf
	buf.resize(arr.size() * 16)
	for i: int in arr.size():
		var it: Array = arr[i]
		var pos: Vector3 = it[0]
		var yaw: float = it[1]
		var sc: float = it[2]
		var col: Color = it[3]
		var cs: float = cos(yaw) * sc
		var sn: float = sin(yaw) * sc
		var o: int = i * 16
		buf[o] = cs
		buf[o + 1] = 0.0
		buf[o + 2] = sn
		buf[o + 3] = pos.x
		buf[o + 4] = 0.0
		buf[o + 5] = sc
		buf[o + 6] = 0.0
		buf[o + 7] = pos.y - 0.1
		buf[o + 8] = -sn
		buf[o + 9] = 0.0
		buf[o + 10] = cs
		buf[o + 11] = pos.z
		buf[o + 12] = col.r
		buf[o + 13] = col.g
		buf[o + 14] = col.b
		buf[o + 15] = col.a
	return buf


## Accumulates axis-aligned boxes (no bottom face) into one ArrayMesh. UV = facade metres, UV2.x = box height.
class _Mesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()

	func box(base: Vector3, sz: Vector3, col: Color, seed_a: float) -> void:
		var x0: float = base.x - sz.x * 0.5
		var x1: float = base.x + sz.x * 0.5
		var z0: float = base.z - sz.z * 0.5
		var z1: float = base.z + sz.z * 0.5
		var y0: float = base.y
		var y1: float = base.y + sz.y
		var tint := Color(col.r, col.g, col.b, seed_a)
		# corners listed counter-clockwise seen from outside; u/v in metres along the face
		_face(Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3.RIGHT, sz.z, sz.y, sz.y, tint)
		_face(Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3.LEFT, sz.z, sz.y, sz.y, tint)
		_face(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK, sz.x, sz.y, sz.y, tint)
		_face(Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3.FORWARD, sz.x, sz.y, sz.y, tint)
		_face(Vector3(x0, y1, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), Vector3(x0, y1, z0), Vector3.UP, sz.x, sz.z, sz.y, tint)

	func _face(a: Vector3, b: Vector3, cc: Vector3, d: Vector3, nrm: Vector3, wu: float, wv: float, bh: float, tint: Color) -> void:
		var o: int = v.size()
		v.append_array([a, b, cc, d])
		for k: int in 4:
			n.append(nrm)
			c.append(tint)
			uv2.append(Vector2(bh, 0.0))
		uv.append_array([Vector2(0.0, 0.0), Vector2(wu, 0.0), Vector2(wu, wv), Vector2(0.0, wv)])
		# Godot front faces wind clockwise
		idx.append_array([o, o + 2, o + 1, o, o + 3, o + 2])

	func mesh() -> ArrayMesh:
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		arr[Mesh.ARRAY_TEX_UV] = uv
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		arr[Mesh.ARRAY_INDEX] = idx
		var am := ArrayMesh.new()
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		return am
