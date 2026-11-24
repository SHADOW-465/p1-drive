extends SceneTree
## Dev: every MeshInstance3D with its root-space AABB and surface materials. Usage: -s res://tools/glb_tree.gd -- path

func _init() -> void:
	var root: Node = (load(OS.get_cmdline_user_args()[0]) as PackedScene).instantiate()
	for n: Node in root.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var p: Node = m
		while p != null:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b: AABB = xf * m.get_aabb()
		var mats := []
		for i: int in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(i)
			mats.append(mat.resource_name if mat else "-")
		print("%s/%s c=(%.2f,%.2f,%.2f) s=(%.2f,%.2f,%.2f) %s" % [m.get_parent().name, m.name, b.get_center().x, b.get_center().y, b.get_center().z, b.size.x, b.size.y, b.size.z, mats])
	quit()
