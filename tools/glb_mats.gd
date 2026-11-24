extends SceneTree
## Dev: list unique materials of a GLB with key props, plus Wheel1A_3D children. Usage: -s res://tools/glb_mats.gd -- path

func _init() -> void:
	var root: Node = (load(OS.get_cmdline_user_args()[0]) as PackedScene).instantiate()
	var seen := {}
	for mi: Node in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		for i: int in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(i) as BaseMaterial3D
			if mat == null or seen.has(mat.resource_name):
				continue
			seen[mat.resource_name] = true
			print("%s a=%s tex=%s tr=%d met=%.2f rough=%.2f emis=%s cc=%.1f" % [mat.resource_name, mat.albedo_color, mat.albedo_texture != null, mat.transparency, mat.metallic, mat.roughness, mat.emission_enabled, mat.clearcoat])
	var w: Node = root.find_child("Wheel1A_3D", true, false)
	if w == null:
		quit()
		return
	for c: Node in w.get_children():
		print("W1A ", c.name, " ", c.get_child_count())
	quit()
