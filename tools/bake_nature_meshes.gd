extends SceneTree
## Bakes centered, grounded, multi-LOD ArrayMesh .res files from CC0 glTF/GLB assets
## into res://assets/models/nature/baked/ for fast MultiMesh instancing.

const OUT_DIR: String = "res://assets/models/nature/baked"

var _done: bool = false


func _process(_dt: float) -> bool:
	if _done:
		return true
	_done = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# Quick path: re-bake only the pine (run with: -- pine_only)
	if OS.get_cmdline_user_args().has("pine_only"):
		_bake_glb_tree("res://assets/models/nature/free_cc0/pine_quat_a.glb", "tree_pine", 12.5)
		print("PINE BAKE DONE")
		quit(0)
		return true

	# User-supplied trees (run with: -- user_trees)
	if OS.get_cmdline_user_args().has("user_trees"):
		_bake_glb_tree("res://assets/models/staging/tree-lowpoly/source/Tree 1 and 2.fbx", "tree_conifer", 10.0, "Tree 2")
		_bake_glb_tree("res://assets/models/staging/mmc-trees/source/mmc-trees-flowers-grass.fbx", "tree_oak", 9.5, "tree-stylized-01")
		_bake_glb_tree("res://assets/models/staging/sakura/source/Sakura/Sakura/Sakura.fbx", "tree_sakura", 9.0)
		print("USER TREES BAKE DONE")
		quit(0)
		return true

	_bake_glb_tree("res://assets/models/staging/mmc-trees/source/mmc-trees-flowers-grass.fbx", "tree_pine", 12.5, "tree-stylized-04-green")
	_bake_glb_tree("res://assets/models/staging/tree-lowpoly/source/Tree 1 and 2.fbx", "tree_conifer", 10.0, "Tree 2")
	_bake_glb_tree("res://assets/models/staging/mmc-trees/source/mmc-trees-flowers-grass.fbx", "tree_oak", 9.5, "tree-stylized-01")
	_bake_ph_clump("res://assets/models/nature/shrub_03/shrub_03.gltf", "shrub", [0, 1], 1.35, 0.04, 0.14)
	_bake_ph_clump("res://assets/models/nature/fern_02/fern_02.gltf", "fern", [0], 0.95, 0.03, 0.22)
	_bake_grass_patch()
	_bake_ph_clump("res://assets/models/nature/rock_09/rock_09.gltf", "rock_a", [0], 0.95, 0.14, 0.45)

	print("BAKE DONE")
	quit(0)
	return true


## Bakes a CC0 GLB tree (wood + green materials) at target_height metres.
## LOD0 keeps the full mesh; LOD1 is a light decimation so the trees keep their shape at range.
func _bake_glb_tree(path: String, out_name: String, target_height: float, mesh_name: String = "") -> void:
	var ps: PackedScene = load(path) as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	# Surface 0 = bark (Wood), Surface 1 = foliage (Green)
	var surfs: Array[Dictionary] = [_empty_surf(), _empty_surf()]
	for mi: MeshInstance3D in mis:
		if mesh_name != "" and mi.name != mesh_name:
			continue  # one tree per file when mesh_name is given
		var xf: Transform3D = _rel_xf(root, mi)
		for si: int in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(si)
			var nm: String = mat.resource_name.to_lower() if mat != null else ""
			var is_bark: bool = "wood" in nm or "bark" in nm or "trunk" in nm
			_append_surface(surfs[0 if is_bark else 1], mi.mesh.surface_get_arrays(si), xf, Color.WHITE)
	root.free()
	var b: AABB = _aabb(surfs)
	var sc: float = target_height / maxf(b.size.y, 0.001)
	_center_and_ground(surfs, sc)
	var lod0 := _build_mesh([surfs[0], surfs[1]])
	var lod1 := _build_mesh([_decimate(surfs[0], 0.25), _decimate(surfs[1], 0.35)])
	ResourceSaver.save(lod0, OUT_DIR.path_join("%s_lod0.res" % out_name))
	ResourceSaver.save(lod1, OUT_DIR.path_join("%s_lod1.res" % out_name))
	print("%s: lod0=%d tris, lod1=%d tris, size=%s" % [out_name, _tri_count(lod0), _tri_count(lod1), _aabb(surfs).size])


func _bake_scots_pine() -> void:
	var ps: PackedScene = load("res://assets/models/nature/scots_pine.glb") as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)

	# Surface 0 = bark, Surface 1 = foliage
	var surfs: Array[Dictionary] = [_empty_surf(), _empty_surf()]
	for mi: MeshInstance3D in mis:
		var xf: Transform3D = _rel_xf(root, mi)
		for si: int in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(si)
			var is_fol: bool = mat != null and "foliage" in mat.resource_name.to_lower()
			var dst_i: int = 1 if is_fol else 0
			_append_surface(surfs[dst_i], mi.mesh.surface_get_arrays(si), xf, Color.WHITE)
	root.free()

	# Scale from 18m to ~12.5m natural average height
	var sc: float = 12.5 / 18.0
	_center_and_ground(surfs, sc)
	var lod0 := _build_mesh([
		_decimate(surfs[0], 0.55),
		_decimate(surfs[1], 0.72),
	])
	var lod1 := _build_mesh([
		_decimate(surfs[0], 1.75),
		_decimate(surfs[1], 2.25),
	])
	ResourceSaver.save(lod0, OUT_DIR.path_join("tree_pine_lod0.res"))
	ResourceSaver.save(lod1, OUT_DIR.path_join("tree_pine_lod1.res"))
	print("tree_pine: lod0=%d tris, lod1=%d tris" % [_tri_count(lod0), _tri_count(lod1)])


func _bake_conifer() -> void:
	var ps: PackedScene = load("res://assets/models/nature/conifer_tree.glb") as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	var surfs: Array[Dictionary] = [_empty_surf(), _empty_surf()]
	for mi: MeshInstance3D in mis:
		var xf: Transform3D = _rel_xf(root, mi)
		for si: int in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(si)
			var is_bark: bool = mat != null and "bark" in mat.resource_name.to_lower()
			_append_surface(surfs[0 if is_bark else 1], mi.mesh.surface_get_arrays(si), xf, Color.WHITE)
	root.free()
	_center_and_ground(surfs, 1.25)  # 8m -> 10m
	var lod0 := _build_mesh([
		_decimate(surfs[0], 0.45),
		_decimate(surfs[1], 0.75),
	])
	var lod1 := _build_mesh([
		_decimate(surfs[0], 1.65),
		_decimate(surfs[1], 2.20),
	])
	ResourceSaver.save(lod0, OUT_DIR.path_join("tree_conifer_lod0.res"))
	ResourceSaver.save(lod1, OUT_DIR.path_join("tree_conifer_lod1.res"))
	print("tree_conifer: lod0=%d tris, lod1=%d tris" % [_tri_count(lod0), _tri_count(lod1)])


func _bake_oak() -> void:
	var ps: PackedScene = load("res://assets/models/nature/oak_tree.glb") as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	var surfs: Array[Dictionary] = [_empty_surf(), _empty_surf()]
	for mi: MeshInstance3D in mis:
		var xf: Transform3D = _rel_xf(root, mi)
		for si: int in mi.mesh.get_surface_count():
			var mat: Material = mi.get_active_material(si)
			var is_bark: bool = mat != null and "bark" in mat.resource_name.to_lower()
			_append_surface(surfs[0 if is_bark else 1], mi.mesh.surface_get_arrays(si), xf, Color.WHITE)
	root.free()
	_center_and_ground(surfs, 1.08)  # ~9.5m
	var lod0 := _build_mesh([
		_decimate(surfs[0], 0.55),
		_decimate(surfs[1], 0.85),
	])
	var lod1 := _build_mesh([
		_decimate(surfs[0], 1.75),
		_decimate(surfs[1], 2.35),
	])
	ResourceSaver.save(lod0, OUT_DIR.path_join("tree_oak_lod0.res"))
	ResourceSaver.save(lod1, OUT_DIR.path_join("tree_oak_lod1.res"))
	print("tree_oak: lod0=%d tris, lod1=%d tris" % [_tri_count(lod0), _tri_count(lod1)])


func _bake_ph_clump(path: String, out_name: String, pick_indices: Array[int], target_height: float, lod0_cell: float, lod1_cell: float) -> void:
	var ps: PackedScene = load(path) as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	var s := _empty_surf()
	for pi: int in pick_indices.size():
		var idx_mi: int = clampi(pick_indices[pi], 0, mis.size() - 1)
		var mi: MeshInstance3D = mis[idx_mi]
		var cs := _empty_surf()
		for si: int in mi.mesh.get_surface_count():
			_append_surface(cs, mi.mesh.surface_get_arrays(si), Transform3D.IDENTITY, Color.WHITE)
		_center_and_ground([cs], 1.0)
		var rot := Transform3D(Basis(Vector3.UP, pi * 1.9), Vector3(pi * 0.08, 0.0, pi * -0.06))
		_append_surface(s, _surf_to_arrays(cs), rot, Color.WHITE)
	root.free()

	var b: AABB = _aabb([s])
	var sc: float = target_height / maxf(b.size.y, 0.001)
	_center_and_ground([s], sc)
	var s0: Dictionary = _decimate(s, lod0_cell) if lod0_cell > 0.0 else s
	var s1: Dictionary = _decimate(s, lod1_cell)
	var lod0 := _build_mesh([s0])
	var lod1 := _build_mesh([s1])
	ResourceSaver.save(lod0, OUT_DIR.path_join("%s_lod0.res" % out_name))
	ResourceSaver.save(lod1, OUT_DIR.path_join("%s_lod1.res" % out_name))
	print("%s: lod0=%d tris, lod1=%d tris, size=%s" % [out_name, _tri_count(lod0), _tri_count(lod1), _aabb([s0]).size])


func _bake_grass_patch() -> void:
	var ps: PackedScene = load("res://assets/models/nature/grass_bermuda_01/grass_bermuda_01.gltf") as PackedScene
	var root: Node = ps.instantiate()
	var mis: Array[MeshInstance3D] = []
	_collect(root, mis)
	var s := _empty_surf()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	# Cluster 9 grass tufts tightly in a ~0.9m patch (~400 tris total)
	for k: int in 9:
		var mi: MeshInstance3D = mis[(k * 2) % mis.size()]
		var cs := _empty_surf()
		for si: int in mi.mesh.get_surface_count():
			_append_surface(cs, mi.mesh.surface_get_arrays(si), Transform3D.IDENTITY, Color.WHITE)
		_center_and_ground([cs], 1.0)
		var ang: float = rng.randf() * TAU
		var rad: float = sqrt(rng.randf()) * 0.11 if k > 0 else 0.0
		var sc: float = rng.randf_range(0.85, 1.25)
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc), Vector3(cos(ang) * rad, 0.0, sin(ang) * rad))
		_append_surface(s, _surf_to_arrays(cs), xf, Color.WHITE)
	root.free()
	var b: AABB = _aabb([s])
	var scale_h: float = 0.42 / maxf(b.size.y, 0.001)
	_center_and_ground([s], scale_h)
	var lod0 := _build_mesh([s])
	var lod1 := _build_mesh([_decimate(s, 0.045)])
	ResourceSaver.save(lod0, OUT_DIR.path_join("grass_lod0.res"))
	ResourceSaver.save(lod1, OUT_DIR.path_join("grass_lod1.res"))
	print("grass: lod0=%d tris, lod1=%d tris, size=%s" % [_tri_count(lod0), _tri_count(lod1), _aabb([s]).size])


func _empty_surf() -> Dictionary:
	return {
		"v": PackedVector3Array(),
		"n": PackedVector3Array(),
		"u": PackedVector2Array(),
		"c": PackedColorArray(),
		"i": PackedInt32Array(),
	}


func _append_surface(dst: Dictionary, arr: Array, xf: Transform3D, tint: Color) -> void:
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var u: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var dv: PackedVector3Array = dst["v"]
	var dn: PackedVector3Array = dst["n"]
	var du: PackedVector2Array = dst["u"]
	var dc: PackedColorArray = dst["c"]
	var di: PackedInt32Array = dst["i"]
	var base: int = dv.size()
	var n_basis: Basis = xf.basis.inverse().transposed()
	for k: int in v.size():
		dv.append(xf * v[k])
		var nrm: Vector3 = (n_basis * n[k]).normalized() if k < n.size() else Vector3.UP
		dn.append(nrm)
		du.append(u[k] if k < u.size() else Vector2.ZERO)
		dc.append(tint)
	if not idx.is_empty():
		for id: int in idx:
			di.append(base + id)
	else:
		for k: int in v.size():
			di.append(base + k)


func _surf_to_arrays(s: Dictionary) -> Array:
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = s["v"]
	arr[Mesh.ARRAY_NORMAL] = s["n"]
	arr[Mesh.ARRAY_TEX_UV] = s["u"]
	arr[Mesh.ARRAY_COLOR] = s["c"]
	arr[Mesh.ARRAY_INDEX] = s["i"]
	return arr


func _aabb(surfs: Array) -> AABB:
	var a := AABB()
	var first: bool = true
	for s: Dictionary in surfs:
		for p: Vector3 in (s["v"] as PackedVector3Array):
			if first:
				a = AABB(p, Vector3.ZERO)
				first = false
			else:
				a = a.expand(p)
	return a


func _center_and_ground(surfs: Array, sc: float) -> void:
	var a: AABB = _aabb(surfs)
	var cx: float = a.position.x + a.size.x * 0.5
	var cz: float = a.position.z + a.size.z * 0.5
	var y0: float = a.position.y
	for s: Dictionary in surfs:
		var v: PackedVector3Array = s["v"]
		for k: int in v.size():
			v[k] = Vector3((v[k].x - cx) * sc, (v[k].y - y0) * sc, (v[k].z - cz) * sc)


func _decimate(s: Dictionary, cell: float) -> Dictionary:
	var v: PackedVector3Array = s["v"]
	var n: PackedVector3Array = s["n"]
	var u: PackedVector2Array = s["u"]
	var c: PackedColorArray = s["c"]
	var idx: PackedInt32Array = s["i"]
	if cell <= 0.0 or v.is_empty():
		return s
	var cells: Dictionary = {}  # Vector3i -> [sum_v, sum_n, sum_c, first_u, count, new_id]
	var v_map := PackedInt32Array()
	v_map.resize(v.size())
	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_u := PackedVector2Array()
	var out_c := PackedColorArray()
	var next_id: int = 0
	for k: int in v.size():
		var p: Vector3 = v[k]
		var key := Vector3i(floori(p.x / cell), floori(p.y / cell), floori(p.z / cell))
		if not cells.has(key):
			cells[key] = [p, n[k], c[k], u[k], 1, next_id]
			v_map[k] = next_id
			next_id += 1
		else:
			var acc: Array = cells[key]
			acc[0] = (acc[0] as Vector3) + p
			acc[1] = (acc[1] as Vector3) + n[k]
			acc[2] = (acc[2] as Color) + c[k]
			acc[4] = int(acc[4]) + 1
			v_map[k] = int(acc[5])
	out_v.resize(next_id)
	out_n.resize(next_id)
	out_u.resize(next_id)
	out_c.resize(next_id)
	for key: Vector3i in cells:
		var acc: Array = cells[key]
		var cnt: float = float(acc[4])
		var id: int = int(acc[5])
		out_v[id] = (acc[0] as Vector3) / cnt
		var nn: Vector3 = acc[1] as Vector3
		out_n[id] = nn.normalized() if nn.length_squared() > 1e-6 else Vector3.UP
		out_u[id] = acc[3] as Vector2
		out_c[id] = (acc[2] as Color) / cnt
	var out_i := PackedInt32Array()
	for t: int in range(0, idx.size(), 3):
		var a: int = v_map[idx[t]]
		var b: int = v_map[idx[t + 1]]
		var d: int = v_map[idx[t + 2]]
		if a != b and b != d and a != d:
			out_i.append_array([a, b, d])
	return {"v": out_v, "n": out_n, "u": out_u, "c": out_c, "i": out_i}


func _build_mesh(surfs: Array) -> ArrayMesh:
	var m := ArrayMesh.new()
	for s: Dictionary in surfs:
		if (s["i"] as PackedInt32Array).is_empty():
			continue
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surf_to_arrays(s))
	return m


func _tri_count(m: ArrayMesh) -> int:
	var t: int = 0
	for si: int in m.get_surface_count():
		var arr: Array = m.surface_get_arrays(si)
		t += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return t


func _collect(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n as MeshInstance3D)
	for c: Node in n.get_children():
		_collect(c, out)


func _rel_xf(root: Node, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf
