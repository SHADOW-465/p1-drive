extends Node
## Dev (not a gate): H1 HUD proof. Run windowed with `-- --autodrive [--shots] [--hudoff]`.
## Prints average uncapped FPS in chase view over 10 s at speed; with --shots also saves
## logs/h1_hud_chase.png (about 150 km/h, GPS route active) and logs/h1_hud_cockpit.png.

var main: Node3D
var car: Car
var k: int = 0
var t_speed: float = -1.0
var frames: int = 0
var elapsed: float = 0.0
var phase: int = 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if Settings.has_arg("--hd"):
		get_window().size = Vector2i(1920, 1080)
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _process(dt: float) -> void:
	if car.freeze:
		return
	k += 1
	if k == 5:
		var ad: Autodrive = main.get("_autodrive") as Autodrive
		var ahead: Vector3 = ad._ahead_pos(4000.0)
		var cw: Vector3 = Origin.to_world(car.global_position)
		GpsRoute.place(Vector2(cw.x, cw.z), Vector2(ahead.x, ahead.z))
		if Settings.has_arg("--hudoff"):
			main.hud.visible = false
	if phase == 0:
		if car.speed_kmh >= 150.0 or k > 3600:
			phase = 1
			t_speed = 0.0
			print("at %.0f km/h after %d frames, route active=%s" % [car.speed_kmh, k, GpsRoute.active])
		return
	if phase == 1:
		t_speed += dt
		if t_speed < 1.0:
			return
		if Settings.has_arg("--shots"):
			get_viewport().get_texture().get_image().save_png("res://logs/h1_hud_chase.png")
			main.rig.set_mode(CameraRig.Mode.COCKPIT)
			main.car.set_cockpit_active(true)
		phase = 2
		t_speed = 0.0
		return
	if phase == 2:
		t_speed += dt
		if t_speed < 1.5:
			return
		if Settings.has_arg("--shots"):
			get_viewport().get_texture().get_image().save_png("res://logs/h1_hud_cockpit.png")
			main.rig.set_mode(CameraRig.Mode.CHASE)
			main.car.set_cockpit_active(false)
		phase = 3
		t_speed = 0.0
		return
	if phase == 3:
		t_speed += dt
		if t_speed < 2.0:
			return
		phase = 4
		elapsed = 0.0
		frames = 0
		return
	frames += 1
	elapsed += dt
	if elapsed >= 10.0:
		print("FPS avg %.1f (%.2f ms/frame) speed %.0f km/h" % [frames / elapsed, 1000.0 * elapsed / frames, car.speed_kmh])
		main.call("quit_game")
		get_tree().quit()
