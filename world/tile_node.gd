class_name TileNode
extends Node3D
## Main-thread side of a tile (PLAN 2.2): turns TileGen data into meshes/shapes in small steps.

static var terrain_mat: ShaderMaterial
static var road_mat: ShaderMaterial
static var props_mat: ShaderMaterial
static var props_glow_mat: ShaderMaterial
static var overlay_cache: Dictionary[String, PackedScene] = {}
static var step_ms: Dictionary[StringName, float] = {}  # worst time per apply step (dev stat)

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
	if d.has("road"):
		_steps.append(_road_mesh)
	if d.has("road_faces"):
		var rf: PackedVector3Array = d["road_faces"]
		for i: int in range(0, rf.size(), 3000):
			_steps.append(_road_collider_chunk.bind(i, mini(i + 3000, rf.size())))
	if d.has("props"):
		_steps.append(_props_mesh)
	if d.has("prop_faces"):
		var pf: PackedVector3Array = d["prop_faces"]
		for i: int in range(0, pf.size(), 3000):
			_steps.append(_props_collider_chunk.bind(i, mini(i + 3000, pf.size())))
	if d.has("scatter"):
		var chunks: Array = d["scatter"]
		for i: int in range(0, chunks.size(), 4):
			_steps.append(_scatter_batch.bind(i, mini(i + 4, chunks.size())))
	if d.has("overlay"):
		_steps.append(_overlay_node)


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


## MeshInstance3D child from a {verts, norms, cols, idx[, uvs]} dictionary.
func _add_mesh(node_name: String, a: Dictionary, mat: Material) -> MeshInstance3D:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = a["verts"]
	arr[Mesh.ARRAY_NORMAL] = a["norms"]
	arr[Mesh.ARRAY_COLOR] = a["cols"]
	arr[Mesh.ARRAY_INDEX] = a["idx"]
	if a.has("uvs"):
		arr[Mesh.ARRAY_TEX_UV] = a["uvs"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _terrain_mesh() -> void:
	if terrain_mat == null:
		terrain_mat = _material("res://shaders/terrain.gdshader")
	_add_mesh("Terrain", data, terrain_mat)


func _road_mesh() -> void:
	if road_mat == null:
		road_mat = _material("res://shaders/road.gdshader")
	_add_mesh("Road", data["road"], road_mat)


func _props_mesh() -> void:
	if props_mat == null:
		props_mat = _material("res://shaders/props.gdshader")
	var pd: Dictionary = data["props"]
	var mi: MeshInstance3D = _add_mesh("Props", pd, props_mat)
	if pd.has("glow"):
		if props_glow_mat == null:
			props_glow_mat = _material("res://shaders/props_glow.gdshader")
		var gd: Dictionary = pd["glow"]
		var arr: Array = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = gd["verts"]
		arr[Mesh.ARRAY_NORMAL] = gd["norms"]
		arr[Mesh.ARRAY_TEX_UV] = gd["uvs"]
		arr[Mesh.ARRAY_COLOR] = gd["cols"]
		arr[Mesh.ARRAY_INDEX] = gd["idx"]
		var mesh := mi.mesh as ArrayMesh
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(1, props_glow_mat)


func _props_collider_chunk(i0: int, i1: int) -> void:
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	var pf: PackedVector3Array = data["prop_faces"]
	shape.set_faces(pf if i0 == 0 and i1 == pf.size() else pf.slice(i0, i1))
	var cs := CollisionShape3D.new()
	cs.name = "PropsShape_%d" % i0
	cs.shape = shape
	body().add_child(cs)


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
		for ti: int in 3:
			var buf: PackedFloat32Array = bufs[ti]
			if buf.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = Scatter._meshes[ti]
			mm.instance_count = buf.size() / 16
			mm.buffer = buf
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.position = ch["pos"]
			mmi.custom_aabb = ch["aabb"]
			mmi.material_override = Scatter._mat
			Scatter.apply_settings_to_mmi(mmi)
			sc_root.add_child(mmi)


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


func _road_collider_chunk(i0: int, i1: int) -> void:
	var shape := ConcavePolygonShape3D.new()
	var rf: PackedVector3Array = data["road_faces"]
	shape.set_faces(rf if i0 == 0 and i1 == rf.size() else rf.slice(i0, i1))
	var cs := CollisionShape3D.new()
	cs.name = "RoadShape_%d" % i0
	cs.shape = shape
	body().add_child(cs)


func _terrain_collider() -> void:
	var n: int = TileGen.GRID[TileGen.FULL]
	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = data["hm"]
	var cs := CollisionShape3D.new()
	cs.name = "TerrainShape"
	cs.shape = shape
	var cell: float = TileGen.TILE / (n - 1)
	cs.scale = Vector3(cell, 1.0, cell)
	cs.position = Vector3(TileGen.TILE * 0.5, 0.0, TileGen.TILE * 0.5)
	body().add_child(cs)
