extends Node3D
## Medium-quality hill pass summit lay-by overlay (L2): parking pad, wooden barrier posts,
## viewpoint marker + night bollard lights using props.gdshader.
## Note: Fable's T22 upgrades this for High.

const SUMMIT_LOCAL: Vector3 = Vector3(440.0, 0.0, 420.0)


func _ready() -> void:
	var wx: float = -2.0 * TileGen.TILE + SUMMIT_LOCAL.x
	var wz: float = -6.0 * TileGen.TILE + SUMMIT_LOCAL.z
	var wy: float = TerrainFn.base_height(wx, wz)
	var np: Dictionary = RoadGraph.nearest_point(Vector3(wx, wy, wz), 80.0)
	if not np.is_empty():
		wy = (np["pos"] as Vector3).y
	var base := Vector3(SUMMIT_LOCAL.x, wy + 0.15, SUMMIT_LOCAL.z)
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()
	var idx := PackedInt32Array()
	var post_col := Color(0.32, 0.22, 0.13, 0.0).srgb_to_linear()
	var lamp_col := Color(1.0, 0.78, 0.42, 1.0)
	for i: int in 5:
		var px: float = base.x + (i - 2) * 3.5
		_box(Vector3(px, base.y + 0.55, base.z), Vector3(0.22, 1.1, 0.22), post_col, v, n, c, idx)
		if i == 0 or i == 4:
			_box(Vector3(px, base.y + 1.15, base.z), Vector3(0.26, 0.16, 0.26), lamp_col, v, n, c, idx)
	_box(Vector3(base.x, base.y + 0.85, base.z), Vector3(14.4, 0.16, 0.12), post_col, v, n, c, idx)
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_COLOR] = c
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/props.gdshader")
	m.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "ViewpointPosts"
	mi.mesh = m
	add_child(mi)


static func _box(c_pos: Vector3, sz: Vector3, col: Color, v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, idx: PackedInt32Array) -> void:
	var h: Vector3 = sz * 0.5
	var faces: Array = [
		[Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(0, 0, 1)],
		[Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(0, 0, -1)],
		[Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(1, 0, 0)],
		[Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-1, 0, 0)],
		[Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(0, 1, 0)],
	]
	for f: Array in faces:
		var b: int = v.size()
		v.append_array([c_pos + f[0], c_pos + f[1], c_pos + f[2], c_pos + f[3]])
		var nrm: Vector3 = f[4]
		n.append_array([nrm, nrm, nrm, nrm])
		c.append_array([col, col, col, col])
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
