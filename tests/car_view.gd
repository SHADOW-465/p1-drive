extends Node3D
## Dev viewer: one frozen car on a plane; saves logs/car_<name>.png and quits.
## Args: --car=<id from data/cars.json> --yaw=deg --pitch=deg --dist=m --pose=0..3 (aero state) --night --name=x

func _ready() -> void:
	add_child((load("res://world/day_night.gd") as GDScript).new())
	var pm := PlaneMesh.new()
	pm.size = Vector2(60.0, 60.0)
	var sb := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	sb.add_child(cs)
	add_child(sb)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.25, 0.27)
	pm.material = gm
	var ground := MeshInstance3D.new()
	ground.mesh = pm
	add_child(ground)
	var car := CarRegistry.instantiate(Settings.arg_value("--car", "p1"))
	car.player_controlled = false
	car.position.y = 0.01
	add_child(car)
	var aero: ActiveAero = car.find_child("Aero", true, false) as ActiveAero
	var pose: int = int(Settings.arg_value("--pose", "0"))
	if aero != null and pose > 0:
		aero.set_physics_process(false)
		aero.wing_pivot.position.y += ActiveAero.POSE[pose * 5]
		aero.struts.position.y = aero.wing_pivot.position.y
		aero.wing_pivot.rotation.x = -deg_to_rad(ActiveAero.POSE[pose * 5 + 1])
		for f: Node3D in aero.flaps:
			f.rotation.x = deg_to_rad(ActiveAero.POSE[pose * 5 + 2])
	if Settings.has_arg("--night"):
		DayNight.night_factor = 1.0
		(get_child(0) as DayNight).sun.light_energy = 0.05
		(get_child(0) as DayNight).env.background_energy_multiplier = 0.05
		(get_child(0) as DayNight).env.ambient_light_energy = 0.08
		car.in_brake = 1.0
	var cam := Camera3D.new()
	add_child(cam)
	var b: Basis = Basis(Vector3.UP, deg_to_rad(float(Settings.arg_value("--yaw", "150")))) * Basis(Vector3.RIGHT, -deg_to_rad(float(Settings.arg_value("--pitch", "14"))))
	cam.position = Vector3(0.0, 0.5, 0.0) + b * Vector3(0.0, 0.0, float(Settings.arg_value("--dist", "6.5")))
	cam.look_at(Vector3(0.0, 0.5, 0.0))
	cam.fov = 50.0
	if Settings.has_arg("--eye"):  # driver eye view, --look=yaw deg, --pitch is ignored
		car.set_cockpit_active(true)
		cam.position = car.global_transform * car.cockpit_cam
		if Settings.arg_value("--pos", "") != "":
			var pp: PackedStringArray = Settings.arg_value("--pos", "").split(",")
			cam.position = Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
		cam.rotation = Vector3(deg_to_rad(float(Settings.arg_value("--tilt", "-4"))), deg_to_rad(float(Settings.arg_value("--look", "0"))), 0.0)
		cam.fov = 75.0
		cam.near = 0.035
		car.in_steer = float(Settings.arg_value("--steer", "0"))
	await get_tree().create_timer(0.6).timeout
	if Settings.arg_value("--probe", "") != "":  # --probe=KeyA,KeyB: print car-space AABBs of meshes whose ancestor names match
		var keys: PackedStringArray = Settings.arg_value("--probe", "").split(",")
		var inv: Transform3D = car.global_transform.affine_inverse()
		for mi: Node in car.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			var grp: String = ""
			var n: Node = m
			while n != car:
				grp += String(n.name) + "/"
				n = n.get_parent()
			for k: String in keys:
				if grp.contains(k):
					var pb: AABB = inv * m.global_transform * m.get_aabb()
					var mats: String = ""
					for i: int in m.mesh.get_surface_count():
						var mt := m.mesh.surface_get_material(i)
						mats += (mt.resource_name.left(26) if mt != null else "-") + " "
					print("PROBE %s c=(%.2f %.2f %.2f) s=(%.2f %.2f %.2f) %s" % [grp.get_slice("/", 0).left(24), pb.get_center().x, pb.get_center().y, pb.get_center().z, pb.size.x, pb.size.y, pb.size.z, mats])
					break
	if Settings.has_arg("--dbg"):
		for w: VehicleWheel3D in car.find_children("*", "VehicleWheel3D", false, false):
			print("DBG ", w.name, w.position, w.get_child_count(), (w.get_child(0) as Node3D).global_position if w.get_child_count() > 0 else "-", w.is_in_contact(), car.global_position)
	get_viewport().get_texture().get_image().save_png("res://logs/car_%s.png" % Settings.arg_value("--name", "view"))
	get_tree().quit()
