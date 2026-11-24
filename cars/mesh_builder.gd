class_name MeshBuilder
extends RefCounted
## Tiny unindexed triangle builder with auto-winding (triangles face along their normals).
## Colours are given in sRGB (alpha = free channel) and stored linear.
## cur_uv is stamped on every vertex (car_paint.gdshader reads UV.y as a material id).

var v: PackedVector3Array = PackedVector3Array()
var n: PackedVector3Array = PackedVector3Array()
var c: PackedColorArray = PackedColorArray()
var uv: PackedVector2Array = PackedVector2Array()
var cur_uv: Vector2 = Vector2(0.0, -1.0)


func tri(a: Vector3, b: Vector3, d: Vector3, na: Vector3, nb: Vector3, nd: Vector3, col: Color) -> void:
	tri_uv(a, b, d, na, nb, nd, col, cur_uv, cur_uv, cur_uv)


func tri_uv(a: Vector3, b: Vector3, d: Vector3, na: Vector3, nb: Vector3, nd: Vector3, col: Color,
		ua: Vector2, ub: Vector2, ud: Vector2) -> void:
	var lin: Color = col.srgb_to_linear()
	if (b - a).cross(d - a).dot(na + nb + nd) > 0.0:  # Godot front faces are clockwise
		v.append_array([a, d, b])
		n.append_array([na, nd, nb])
		uv.append_array([ua, ud, ub])
	else:
		v.append_array([a, b, d])
		n.append_array([na, nb, nd])
		uv.append_array([ua, ub, ud])
	c.append_array([lin, lin, lin])


func quad(a: Vector3, b: Vector3, d: Vector3, e: Vector3, na: Vector3, nb: Vector3, nd: Vector3, ne: Vector3, col: Color) -> void:
	tri(a, b, d, na, nb, nd, col)
	tri(a, d, e, na, nd, ne, col)


## Flat quad a-b-d-e facing toward hint.
func flat(a: Vector3, b: Vector3, d: Vector3, e: Vector3, hint: Vector3, col: Color) -> void:
	var fn: Vector3 = (b - a).cross(e - a).normalized()
	if fn.dot(hint) < 0.0:
		fn = -fn
	quad(a, b, d, e, fn, fn, fn, fn, col)


func box(xf: Transform3D, size: Vector3, col: Color) -> void:
	var h: Vector3 = size * 0.5
	for axis: int in 3:
		var u: int = (axis + 1) % 3
		var w: int = (axis + 2) % 3
		for s: float in [-1.0, 1.0]:
			var p: Array[Vector3] = []
			for k: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var q: Vector3 = Vector3.ZERO
				q[axis] = s * h[axis]
				q[u] = k.x * h[u]
				q[w] = k.y * h[w]
				p.append(xf * q)
			var hint: Vector3 = Vector3.ZERO
			hint[axis] = s
			flat(p[0], p[1], p[2], p[3], xf.basis * hint, col)


func ellipsoid(centre: Vector3, r: Vector3, col: Color, lat: int = 8) -> void:
	for i: int in lat:
		for j: int in lat * 2:
			var p: Array[Vector3] = []
			var nn: Array[Vector3] = []
			for q: Vector2i in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]:
				var th: float = PI * q.x / lat
				var ph: float = PI * q.y / lat
				var d: Vector3 = Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
				p.append(centre + d * r)
				nn.append((d / r).normalized())
			quad(p[0], p[1], p[2], p[3], nn[0], nn[1], nn[2], nn[3], col)


## Surface of revolution around the X axis. profile: (x, radius) pairs. Normals point away from
## core (also an (x, radius) point). smooth blends normals across the profile as well as around.
func lathe(profile: PackedVector2Array, segs: int, col: Color, core: Vector2, smooth: bool = false) -> void:
	var sn: PackedVector2Array = PackedVector2Array()  # per-segment (x, radial) normals
	for i: int in profile.size() - 1:
		var t: Vector2 = (profile[i + 1] - profile[i]).normalized()
		var pn: Vector2 = Vector2(-t.y, t.x)
		if pn.dot((profile[i] + profile[i + 1]) * 0.5 - core) < 0.0:
			pn = -pn
		sn.append(pn)
	for i: int in profile.size() - 1:
		var p0: Vector2 = profile[i]
		var p1: Vector2 = profile[i + 1]
		var m0: Vector2 = sn[i]
		var m1: Vector2 = sn[i]
		if smooth:
			m0 = (sn[maxi(i - 1, 0)] + sn[i]).normalized()
			m1 = (sn[mini(i + 1, sn.size() - 1)] + sn[i]).normalized()
		for k: int in segs:
			var a0: float = TAU * k / segs
			var a1: float = TAU * (k + 1) / segs
			var r0: Vector3 = Vector3(0.0, cos(a0), sin(a0))
			var r1: Vector3 = Vector3(0.0, cos(a1), sin(a1))
			quad(Vector3(p0.x, 0, 0) + r0 * p0.y, Vector3(p1.x, 0, 0) + r0 * p1.y,
				Vector3(p1.x, 0, 0) + r1 * p1.y, Vector3(p0.x, 0, 0) + r1 * p0.y,
				Vector3(m0.x, 0, 0) + r0 * m0.y, Vector3(m1.x, 0, 0) + r0 * m1.y,
				Vector3(m1.x, 0, 0) + r1 * m1.y, Vector3(m0.x, 0, 0) + r1 * m0.y, col)


func mesh(material: Material = null) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = n
	arrays[Mesh.ARRAY_COLOR] = c
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		m.surface_set_material(0, material)
	return m
