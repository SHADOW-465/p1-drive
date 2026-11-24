class_name TileNode
extends Node3D
## Main-thread side of a tile (PLAN 2.2): turns TileGen data into meshes/shapes in small steps.

static var terrain_mat: ShaderMaterial
static var road_mat: ShaderMaterial
static var water_mat: ShaderMaterial
static var props_mat: ShaderMaterial
static var props_glow_mat: ShaderMaterial
static var building_mat: ShaderMaterial
static var building_lod_mat: ShaderMaterial
static var overlay_cache: Dictionary[String, PackedScene] = {}
static var step_ms: Dictionary[StringName, float] = {}  # worst time per apply step (dev stat)
static var _server_lock: Mutex = Mutex.new()  # dummy renderer + Jolt are not safe for two workers at once

var tx: int
var tz: int
var lod: int
var data: Dictionary
var _steps: Array[Callable] = []


func setup(d: Dictionary) -> void:
	data = d
	tx = d["tx"]
	tz = d["tz"]
	lod = d["lod"]
	name = "Tile_%d_%d_%d" % [tx, tz, lod]
	_steps = [_terrain_mesh]
	if d.has("hm"):
		_steps.append(_terrain_collider)
	if d.has("water"):
		_steps.append(_water_mesh)
	if d.has("road_chunks"):
		for k: int in (d["road_chunks"] as Array).size():
			_steps.append(_road_chunk.bind(k))
	elif d.has("road"):
		_steps.append(_road_mesh)
	if d.has("road_faces"):
		for k: int in (d["road_shapes"] as Array).size():
			_steps.append(_road_collider_chunk.bind(k))
	if d.has("props_chunks"):
		for k: int in (d["props_chunks"] as Array).size():
			_steps.append(_props_chunk.bind(k))
	elif d.has("props"):
		_steps.append(_props_mesh)
	if d.has("props") and (d["props"] as Dictionary).has("glow"):
		_steps.append(_props_glow)
	if d.has("prop_faces"):
		for k: int in (d["prop_shapes"] as Array).size():
			_steps.append(_props_collider_chunk.bind(k))
	if d.has("scatter"):
		var chunks: Array = d["scatter"]
		for i: int in chunks.size():
			_steps.append(_scatter_batch.bind(i, i + 1))
	if d.has("overlay"):
		_steps.append(_overlay_node)
	if d.has("city"):
		for i: int in (d["city"] as Array).size():
			_steps.append(_city_chunk.bind(i))
	if d.has("city_sky"):
		_steps.append(_city_sky)
	if d.has("city_faces"):
		_steps.append(_city_collider)


## Runs one apply step; false when the tile is complete.
func step() -> bool:
	if not _steps.is_empty():
		var c: Callable = _steps.pop_front()
		var t0: int = Time.get_ticks_usec()
		c.call()
		var k: StringName = c.get_method()
		step_ms[k] = maxf(step_ms.get(k, 0.0), (Time.get_ticks_usec() - t0) / 1000.0)
	if _steps.is_empty():
		data = {}
		return false
	return true


func body() -> StaticBody3D:
	var b: StaticBody3D = get_node_or_null(^"Body") as StaticBody3D
	if b == null:
		b = StaticBody3D.new()
		b.name = "Body"
		add_child(b)
	return b


static func _material(path: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(path) as Shader
	return m


static func get_terrain_material() -> ShaderMaterial:
	if terrain_mat == null:
		terrain_mat = _material("res://shaders/terrain.gdshader")
		var base: String = "res://assets/textures/ground/"
		var sets: Dictionary = {
			"grass": ["leafy_grass", "1k"],
			"dirt": ["dirt", "1k"],
			"rock": ["rock_face_03", "1k"],
			"sand": ["sand_01", "1k"],
		}
		for key: String in sets:
			var info: Array = sets[key]
			var nm: String = str(info[0])
			var res: String = str(info[1])
			terrain_mat.set_shader_parameter("tex_%s_diff" % key, load("%s%s/%s_diffuse_%s.jpg" % [base, nm, nm, res]))
			terrain_mat.set_shader_parameter("tex_%s_nor" % key, load("%s%s/%s_nor_gl_%s.jpg" % [base, nm, nm, res]))
			terrain_mat.set_shader_parameter("tex_%s_arm" % key, load("%s%s/%s_arm_%s.jpg" % [base, nm, nm, res]))
	return terrain_mat


static func get_road_material() -> ShaderMaterial:
	if road_mat == null:
		road_mat = _material("res://shaders/road.gdshader")
		var base: String = "res://assets/textures/ground/"
		var sets: Dictionary = {
			"asphalt": ["asphalt_02", "2k"],
			"concrete": ["concrete_pavers_02", "1k"],
			"verge": ["dirt", "1k"],
		}
		for key: String in sets:
			var info: Array = sets[key]
			var nm: String = str(info[0])
			var res: String = str(info[1])
			road_mat.set_shader_parameter("tex_%s_diff" % key, load("%s%s/%s_diffuse_%s.jpg" % [base, nm, nm, res]))
			road_mat.set_shader_parameter("tex_%s_nor" % key, load("%s%s/%s_nor_gl_%s.jpg" % [base, nm, nm, res]))
			road_mat.set_shader_parameter("tex_%s_arm" % key, load("%s%s/%s_arm_%s.jpg" % [base, nm, nm, res]))
	return road_mat


static func make_mesh(a: Dictionary) -> ArrayMesh:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = a["verts"]
	arr[Mesh.ARRAY_NORMAL] = a["norms"]
	arr[Mesh.ARRAY_COLOR] = a["cols"]
	arr[Mesh.ARRAY_INDEX] = a["idx"]
	if a.has("uvs"):
		arr[Mesh.ARRAY_TEX_UV] = a["uvs"]
	if a.has("uvs2"):
		arr[Mesh.ARRAY_TEX_UV2] = a["uvs2"]
	return _array_to_mesh(arr)


## Worker thread (end of TileGen.build): builds collision shapes off the main thread.
## RenderingServer meshes are built on the main thread in step() to avoid DummyMesh/Dependency races.
static func prebuild(d: Dictionary) -> void:
	if d.has("road"):
		d["road_chunks"] = _chunk_mesh_dict(d["road"] as Dictionary, 12000)
	if d.has("props"):
		d["props_chunks"] = _chunk_mesh_dict(d["props"] as Dictionary, 12000)
	if d.has("hm"):
		d["terrain_shape"] = make_terrain_shape(d["hm"], d["lod"])
	if d.has("road_splits"):
		d["road_shapes"] = _run_shapes(d["road_faces"], d["road_splits"])
	elif d.has("road_faces"):
		d["road_shapes"] = _face_shapes(d["road_faces"], 900)
	if d.has("prop_faces"):
		d["prop_shapes"] = _face_shapes(d["prop_faces"], 600)
	if d.has("city_faces"):
		d["city_shape"] = _face_shapes(d["city_faces"], (d["city_faces"] as PackedVector3Array).size())[0]


static func _chunk_mesh_dict(src: Dictionary, max_idx: int) -> Array[Dictionary]:
	var src_idx: PackedInt32Array = src["idx"]
	if src_idx.size() <= max_idx:
		return [src]
	var sv: PackedVector3Array = src["verts"]
	var sn: PackedVector3Array = src["norms"]
	var suv: PackedVector2Array = src["uvs"]
	var sc: PackedColorArray = src["cols"]
	var remap := PackedInt32Array()
	remap.resize(sv.size())
	remap.fill(-1)
	var out: Array[Dictionary] = []
	var used := PackedInt32Array()
	for start: int in range(0, src_idx.size(), max_idx):
		var stop: int = mini(start + max_idx, src_idx.size())
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var uv := PackedVector2Array()
		var c := PackedColorArray()
		var idx := PackedInt32Array()
		idx.resize(stop - start)
		used.clear()
		for k: int in range(start, stop):
			var vi: int = src_idx[k]
			var nv: int = remap[vi]
			if nv < 0:
				nv = v.size()
				remap[vi] = nv
				used.append(vi)
				v.append(sv[vi])
				n.append(sn[vi])
				uv.append(suv[vi])
				c.append(sc[vi])
			idx[k - start] = nv
		for vi: int in used:
			remap[vi] = -1
		out.append({"verts": v, "norms": n, "uvs": uv, "cols": c, "idx": idx})
	return out


## Road collider in chunks of whole slab runs (~1000 triangles): each slab keeps Jolt's internal-edge welding along its
## length (a seam mid-slab is a bump), and no single shape costs the main thread a long add.
static func _run_shapes(faces: PackedVector3Array, splits: PackedInt32Array) -> Array:
	var out: Array = []
	var start: int = 0
	_server_lock.lock()
	for k: int in splits.size():
		var end: int = splits[k]
		if end - start >= 3000 or (k == splits.size() - 1 and end > start):
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(faces.slice(start, end))
			out.append(shape)
			start = end
	_server_lock.unlock()
	return out


static func _face_shapes(faces: PackedVector3Array, chunk: int) -> Array:
	var out: Array = []
	_server_lock.lock()
	for i: int in range(0, faces.size(), chunk):
		var shape := ConcavePolygonShape3D.new()
		# Edge direction flips triangle winding; wheel rays must hit either side.
		shape.backface_collision = true
		shape.set_faces(faces.slice(i, mini(i + chunk, faces.size())))
		out.append(shape)
	_server_lock.unlock()
	return out


## MeshInstance3D child built on the main thread from worker mesh arrays.
func _add_mesh(node_name: String, mat: Material, src: Dictionary) -> MeshInstance3D:
	var mesh: ArrayMesh = make_mesh(src)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _terrain_mesh() -> void:
	var mi: MeshInstance3D = _add_mesh("Terrain", get_terrain_material(), data)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.is_high() else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _road_mesh() -> void:
	_add_mesh("Road", get_road_material(), data["road"] as Dictionary)


func _road_chunk(k: int) -> void:
	_add_mesh("Road_%d" % k, get_road_material(), (data["road_chunks"] as Array)[k] as Dictionary)


static func get_water_material() -> ShaderMaterial:
	if water_mat == null:
		water_mat = _material("res://shaders/water.gdshader")
	return water_mat


func _water_mesh() -> void:
	_add_mesh("Water", get_water_material(), data["water"] as Dictionary)


static func get_props_material() -> ShaderMaterial:
	if props_mat == null:
		props_mat = _material("res://shaders/props.gdshader")
		var base: String = "res://assets/textures/props/"
		props_mat.set_shader_parameter("tex_rail_diff", load(base + "corrugated_iron/corrugated_iron_diff_1k.jpg"))
		props_mat.set_shader_parameter("tex_rail_nor", load(base + "corrugated_iron/corrugated_iron_nor_gl_1k.jpg"))
		props_mat.set_shader_parameter("tex_rail_arm", load(base + "corrugated_iron/corrugated_iron_arm_1k.jpg"))
		props_mat.set_shader_parameter("tex_metal_diff", load(base + "metal_plate_02/metal_plate_02_diff_1k.jpg"))
		props_mat.set_shader_parameter("tex_metal_nor", load(base + "metal_plate_02/metal_plate_02_nor_gl_1k.jpg"))
		props_mat.set_shader_parameter("tex_metal_arm", load(base + "metal_plate_02/metal_plate_02_arm_1k.jpg"))
		props_mat.set_shader_parameter("tex_conc_diff", load(base + "concrete_panels/concrete_panels_diff_1k.jpg"))
		props_mat.set_shader_parameter("tex_conc_nor", load(base + "concrete_panels/concrete_panels_nor_gl_1k.jpg"))
		props_mat.set_shader_parameter("tex_conc_arm", load(base + "concrete_panels/concrete_panels_arm_1k.jpg"))
		props_mat.set_shader_parameter("tex_sign_atlas", load(base + "signs_atlas.png"))
	return props_mat


func _props_mesh() -> void:
	var pd: Dictionary = data["props"] as Dictionary
	var mi: MeshInstance3D = _add_mesh("Props", get_props_material(), pd)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.shadow_quality >= 3 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _props_chunk(k: int) -> void:
	var pd: Dictionary = (data["props_chunks"] as Array)[k] as Dictionary
	var mi: MeshInstance3D = _add_mesh("Props_%d" % k, get_props_material(), pd)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.shadow_quality >= 3 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _props_glow() -> void:
	var gd: Dictionary = (data["props"] as Dictionary)["glow"] as Dictionary
	if props_glow_mat == null:
		props_glow_mat = _material("res://shaders/props_glow.gdshader")
	_add_mesh("PropsGlow", props_glow_mat, gd)


func _props_collider_chunk(k: int) -> void:
	var cs := CollisionShape3D.new()
	cs.name = "PropsShape_%d" % (k * 600)
	cs.shape = data["prop_shapes"][k]
	_add_collider(cs)


func _scatter_batch(i0: int, i1: int) -> void:
	Scatter.ensure_resources()
	var sc_root := get_node_or_null(^"Scatter") as Node3D
	if sc_root == null:
		sc_root = Node3D.new()
		sc_root.name = "Scatter"
		add_child(sc_root)
	var chunks: Array = data["scatter"]
	for ci: int in range(i0, i1):
		var ch: Dictionary = chunks[ci]
		var bufs: Array = ch["bufs"]
		for ti: int in Scatter.TYPE_COUNT:
			var buf: PackedFloat32Array = bufs[ti]
			if buf.is_empty():
				continue
			for lod_i: int in (2 if Scatter.HAS_LOD1[ti] == 1 else 1):
				var mm := MultiMesh.new()  # RIDs: main thread only (worker-side MultiMesh errors)
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = true
				mm.mesh = Scatter.get_lod0_mesh(ti) if lod_i == 0 else Scatter.get_lod1_mesh(ti)
				mm.instance_count = buf.size() / 16
				mm.buffer = buf
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.position = ch["pos"]
				mmi.custom_aabb = ch["aabb"]
				mmi.set_meta("scatter_type", ti)
				mmi.set_meta("scatter_lod", lod_i)
				Scatter.apply_settings_to_mmi(mmi)
				sc_root.add_child(mmi)


static func get_building_material() -> ShaderMaterial:
	if building_mat == null:
		var base: String = "res://assets/textures/buildings/"
		building_mat = _material("res://shaders/building.gdshader")
		building_mat.set_shader_parameter("atlas_diff", load(base + "atlas_diff.png"))
		building_mat.set_shader_parameter("atlas_nra", load(base + "atlas_nra.png"))
		building_mat.set_shader_parameter("normals_on", 0.0 if Settings.preset == "low" else 1.0)
	return building_mat


static func get_building_lod_material() -> ShaderMaterial:
	if building_lod_mat == null:
		building_lod_mat = _material("res://shaders/building_lod.gdshader")
		building_lod_mat.set_shader_parameter("atlas_diff", load("res://assets/textures/buildings/atlas_diff.png"))
	return building_lod_mat


static func _array_to_mesh(arr: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## One 256 m chunk of OSM buildings: merged facade mesh (LOD0), box mesh of the big ones (LOD1), a box occluder.
func _city_chunk(i: int) -> void:
	var e: Dictionary = (data["city"] as Array)[i]
	var low: bool = Settings.preset == "low"
	var lod0_end: float = 180.0 if low else 280.0
	var lod1_end: float = 700.0 if low else 900.0
	var m0 := MeshInstance3D.new()
	m0.name = "Buildings_LOD0_%d" % i
	m0.mesh = _array_to_mesh(e["lod0"] as Array)
	m0.material_override = get_building_material()
	m0.visibility_range_end = lod0_end
	m0.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.shadow_quality >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(m0)
	var arr1: Array = e["lod1"]
	if not arr1.is_empty():
		var m1 := MeshInstance3D.new()
		m1.name = "Buildings_LOD1_%d" % i
		m1.mesh = _array_to_mesh(arr1)
		m1.material_override = get_building_lod_material()
		m1.visibility_range_begin = lod0_end
		m1.visibility_range_end = lod1_end
		m1.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(m1)
	var occ_d: Array = e["occ"]
	if not occ_d.is_empty():
		var ao := ArrayOccluder3D.new()
		ao.set_arrays(occ_d[0] as PackedVector3Array, occ_d[1] as PackedInt32Array)
		var occ := OccluderInstance3D.new()
		occ.name = "Occluder_%d" % i
		occ.occluder = ao
		add_child(occ)


## Skyline prisms of the whole tile: the only city geometry past the LOD1 range (and on MID / FAR tiles).
func _city_sky() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Skyline_LOD2"
	mi.mesh = _array_to_mesh(data["city_sky"] as Array)
	mi.material_override = get_building_lod_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if lod == TileGen.FULL:
		mi.visibility_range_begin = 700.0 if Settings.preset == "low" else 900.0
	add_child(mi)


func _city_collider() -> void:
	var cs := CollisionShape3D.new()
	cs.name = "CityWalls"
	cs.shape = data["city_shape"]
	_add_collider(cs)


func _overlay_node() -> void:
	var path: String = str(data["overlay"])
	var ps: PackedScene = overlay_cache.get(path) as PackedScene
	if ps == null:
		ps = ResourceLoader.load(path) as PackedScene
		if ps != null:
			overlay_cache[path] = ps
	if ps != null:
		var inst: Node = ps.instantiate()
		inst.name = "Overlay"
		add_child(inst)


func _road_collider_chunk(k: int) -> void:
	var cs := CollisionShape3D.new()
	cs.name = "RoadShape_%d" % (k * 900)
	cs.shape = data["road_shapes"][k]
	_add_collider(cs)


static func make_terrain_shape(hm: PackedFloat32Array, grid_lod: int) -> HeightMapShape3D:
	var src_n: int = TileGen.GRID[grid_lod]
	if hm.size() != src_n * src_n:
		src_n = int(round(sqrt(float(hm.size()))))
	# FULL 129^2 cooks a heightmap past the stream frame budget. Keep every other
	# sample (65^2, 16 m). The drive slab is the road surface; this is the catch net.
	var stride: int = 2 if src_n > 65 else 1
	var n: int = (src_n - 1) / stride + 1
	_server_lock.lock()
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	if stride == 1:
		shape.map_data = hm
	else:
		var small := PackedFloat32Array()
		small.resize(n * n)
		for j: int in n:
			var sj: int = mini(j * stride, src_n - 1)
			for i: int in n:
				var si: int = mini(i * stride, src_n - 1)
				var lo: float = hm[sj * src_n + si]
				if OsmWorld.enabled:
					# Min of the 2x2, so a coarse chord cannot rise above the stamped road bench.
					var sj2: int = mini(sj + 1, src_n - 1)
					var si2: int = mini(si + 1, src_n - 1)
					lo = minf(lo, minf(hm[sj * src_n + si2], minf(hm[sj2 * src_n + si], hm[sj2 * src_n + si2])))
				small[j * n + i] = lo
		shape.map_data = small
	_server_lock.unlock()
	return shape


func _terrain_collider() -> void:
	var shape: HeightMapShape3D = data["terrain_shape"]
	var n: int = shape.map_width
	var cs := CollisionShape3D.new()
	cs.name = "TerrainShape"
	cs.shape = shape
	var cell: float = TileGen.TILE / (n - 1)
	cs.scale = Vector3(cell, 1.0, cell)
	cs.position = Vector3(TileGen.TILE * 0.5, 0.0, TileGen.TILE * 0.5)
	_add_collider(cs)


## Shapes stay disabled until the tile is the live one, so a FULL build does not
## stack on the MID collider it is about to replace.
func _add_collider(cs: CollisionShape3D) -> void:
	cs.disabled = true
	body().add_child(cs)


func arm_collision() -> void:
	_set_collision(true)


func disarm_collision() -> void:
	_set_collision(false)


func _set_collision(on: bool) -> void:
	var b: StaticBody3D = get_node_or_null(^"Body") as StaticBody3D
	if b == null:
		return
	for c: Node in b.get_children():
		var cs: CollisionShape3D = c as CollisionShape3D
		if cs != null:
			cs.disabled = not on
