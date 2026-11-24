extends Node
## Gate (drive): boots main.tscn like play.bat, holds throttle for 6 s and requires the car
## to be on its wheels and moving. Prints DRIVE PASS / DRIVE FAIL: <reason>.

var main: Node3D
var car: Car
var f: int = 0
var t_boot: int = -1
var max_kmh: float = 0.0
var min_contact: int = 4


func _ready() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _physics_process(_dt: float) -> void:
	f += 1
	if t_boot < 0:
		if not car.freeze:
			t_boot = f
		elif f > 14400 and Time.get_ticks_msec() > 60000:  # tile jobs run on wall time; headless frames take ~0.3 ms
			_finish("boot timeout")
		return
	var k: int = f - t_boot
	if k == 30:
		Input.action_press("throttle")
	if k >= 30:
		min_contact = mini(min_contact, car.wheels_in_contact())
		max_kmh = maxf(max_kmh, car.speed_kmh)
	if k % 60 == 0:
		print("t=%.1fs %.1f km/h gear %d wheels %d" % [k / 60.0, car.speed_kmh, car.drivetrain.gear, car.wheels_in_contact()])
	if k == 330 and DisplayServer.get_name() != "headless":  # windowed run: proof screenshot
		get_viewport().get_texture().get_image().save_png("res://logs/drive_shot.png")
	if k == 390:
		Input.action_release("throttle")
		if max_kmh < 60.0:
			_finish("max %.1f km/h after 6 s throttle (wheels in contact min %d)" % [max_kmh, min_contact])
		elif min_contact < 2:
			_finish("car lost wheel contact on a straight launch")
		else:
			_finish("")


func _finish(fail: String) -> void:
	set_physics_process(false)
	Input.action_release("throttle")
	print("DRIVE PASS (max %.1f km/h)" % max_kmh if fail == "" else "DRIVE FAIL: " + fail)
	main.call("quit_game")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fail == "" else 1)
