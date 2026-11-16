extends Node3D
## Dev track: stadium oval (3 km straights, 300 m radius ends) on an infinite ground plane.
## Start: origin, heading -Z.

const HALF_W: float = 7.0
const RADIUS: float = 300.0
const LENGTH: float = 3000.0


func _ready() -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	body.add_child(cs)
	add_child(body)
	var pm := PlaneMesh.new()
	pm.size = Vector2(12000.0, 12000.0)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.2, 0.36, 0.16)
	pm.material = gm
	var ground := MeshInstance3D.new()
	ground.mesh = pm
	add_child(ground)
	add_child(_road())


func _centreline() -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i: int in 301:
		pts.append(Vector3(0.0, 0.0, -LENGTH * i / 300.0))
	for i: int in range(1, 48):
		var a: float = PI * i / 48.0
		pts.append(Vector3(RADIUS - RADIUS * cos(a), 0.0, -LENGTH - RADIUS * sin(a)))
	for i: int in 301:
		pts.append(Vector3(2.0 * RADIUS, 0.0, -LENGTH + LENGTH * i / 300.0))
	for i: int in range(1, 49):
		var a: float = PI * i / 48.0
		pts.append(Vector3(RADIUS + RADIUS * cos(a), 0.0, RADIUS * sin(a)))
	return pts


func _road() -> MeshInstance3D:
	var pts: PackedVector3Array = _centreline()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var dist: float = 0.0
	var n: int = pts.size()
	for i: int in n:
		var dir: Vector3 = (pts[(i + 1) % n] - pts[(i + n - 1) % n]).normalized()
		var right: Vector3 = dir.cross(Vector3.UP)
		if i > 0:
			dist += pts[i].distance_to(pts[i - 1])
		for s: float in [-1.0, 1.0]:
			verts.append(pts[i] + right * s * HALF_W + Vector3(0.0, 0.02, 0.0))
			uvs.append(Vector2(s * HALF_W, dist))
			cols.append(Color(0.25, HALF_W / 16.0, 0.0))
			norms.append(Vector3.UP)
		if i > 0:
			var b: int = i * 2
			idx.append_array([b - 2, b, b - 1, b - 1, b, b + 1])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/road.gdshader")
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi
