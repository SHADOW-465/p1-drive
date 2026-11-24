extends SceneTree
## Dev: per-group (first child of the model root chain) merged AABB of a GLB. Usage: -s res://tools/glb_dump.gd -- path

func _init() -> void:
	var ps := load(OS.get_cmdline_user_args()[0]) as PackedScene
	var root: Node = ps.instantiate()
	var n: Node = root
	while n.get_child_count() == 1:
		n = n.get_child(0)
	print("root=", n.name, " children=", n.get_child_count())
	var all := AABB()
	var first := true
	for g: Node in n.get_children():
		var bb: AABB = _bb(g, _xf(n, root) * (g as Node3D).transform)
		if String(g.name).contains("Wheel") or String(g.name).contains("Steer") or String(g.name).contains("Interior") or String(g.name).contains("Glass") or String(g.name).contains("Chassis6"): print("%s  c=(%.2f,%.2f,%.2f) sz=(%.2f,%.2f,%.2f)" % [String(g.name), bb.get_center().x*100, bb.get_center().y*100, bb.get_center().z*100, bb.size.x*100, bb.size.y*100, bb.size.z*100])
		all = bb if first else all.merge(bb)
		first = false
	print("ALL pos=", all.position, " size=", all.size)
	quit()


func _xf(n: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c: Node = n
	while c != null:
		if c is Node3D:
			t = (c as Node3D).transform * t
		c = c.get_parent()
	return t


func _bb(n: Node, xf: Transform3D) -> AABB:
	var r := AABB()
	var has := false
	if n is MeshInstance3D:
		r = xf * (n as MeshInstance3D).get_aabb()
		has = true
	for c: Node in n.get_children():
		if c is Node3D:
			var b: AABB = _bb(c, xf * (c as Node3D).transform)
			if b.size != Vector3.ZERO or b.position != Vector3.ZERO:
				r = b if not has else r.merge(b)
				has = true
	return r
