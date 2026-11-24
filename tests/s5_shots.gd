extends Node
## Dev (not a gate): S5 screenshots on the real road. Saves logs/s5_p1_front.png and logs/s5_p1_airbrake.png, then quits.

var main: Node3D
var car: Car
var cam: Camera3D
var k: int = 0
var phase: int = 0


func _ready() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.1


func _physics_process(_dt: float) -> void:
	if cam.get_parent() == null:
		if car.freeze:
			return
		car.add_child(cam)
		cam.position = Vector3(3.0, 1.0, -5.0)
		cam.look_at(car.global_position + Vector3(0.0, 0.5, 0.0))
		cam.current = true
		k = 0
	k += 1
	if phase == 0 and k == 150:
		get_viewport().get_texture().get_image().save_png("res://logs/s5_p1_front.png")
		phase = 1
		cam.position = Vector3(-3.2, 1.7, 5.2)
		cam.look_at(car.global_position + Vector3(0.0, 0.6, 0.0), Vector3.UP)
		Input.action_press("throttle")
	elif phase == 1 and car.speed_kmh > 150.0:
		Input.action_release("throttle")
		Input.action_press("brake")
		phase = 2
	elif phase == 2:
		var a: ActiveAero = car.find_child("Aero", true, false) as ActiveAero
		if a == null:
			print("NOAERO ", car.get_meta("car_id"), " ", car.get_children())
			get_tree().quit()
			return
		cam.look_at(car.global_position + Vector3(0.0, 0.6, 0.0), Vector3.UP)
		if a.wing_angle_deg > 52.0:
			get_viewport().get_texture().get_image().save_png("res://logs/s5_p1_airbrake.png")
			Input.action_release("brake")
			main.call("quit_game")
			get_tree().quit()
