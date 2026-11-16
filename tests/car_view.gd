extends Node3D
## Dev viewer: one frozen car on a plane; saves logs/car_<name>.png and quits.
## Args: --car=res://... --yaw=deg --pitch=deg --dist=m --pose=0..3 (aero state) --night --name=x

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
	var car := (load(Settings.arg_value("--car", "res://cars/p1/p1.tscn")) as PackedScene).instantiate() as Car
	car.player_controlled = false
	car.position.y = 0.01
	add_child(car)
	var aero: ActiveAero = car.get_node_or_null("Aero") as ActiveAero
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
	await get_tree().create_timer(0.6).timeout
	get_viewport().get_texture().get_image().save_png("res://logs/car_%s.png" % Settings.arg_value("--name", "view"))
	get_tree().quit()
