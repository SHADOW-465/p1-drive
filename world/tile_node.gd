class_name TileNode
extends Node3D
## Main-thread side of a tile (PLAN 2.2): turns TileGen data into meshes/shapes in small steps.

static var terrain_mat: ShaderMaterial

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


## Runs one apply step; false when the tile is complete.
func step() -> bool:
	if not _steps.is_empty():
		(_steps.pop_front() as Callable).call()
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


func _terrain_mesh() -> void:
	if terrain_mat == null:
		terrain_mat = ShaderMaterial.new()
		terrain_mat.shader = load("res://shaders/terrain.gdshader") as Shader
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = data["verts"]
	arr[Mesh.ARRAY_NORMAL] = data["norms"]
	arr[Mesh.ARRAY_COLOR] = data["cols"]
	arr[Mesh.ARRAY_INDEX] = data["idx"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, terrain_mat)
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


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
