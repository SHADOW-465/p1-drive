extends Node3D
## Composes world + car + camera + UI; boot/respawn flow; dev args.

@onready var car: Car = $P1
var rig: CameraRig
var debug: Label
var spawn: Transform3D
var _frames: int = 0
var _shot_at: int = 0


func _ready() -> void:
	spawn = car.global_transform
	rig = CameraRig.new()
	rig.car = car
	add_child(rig)
	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	debug = Label.new()
	debug.position = Vector2(16.0, 12.0)
	ui.add_child(debug)
	_shot_at = int(Settings.arg_value("--shot", "0"))


func _physics_process(_dt: float) -> void:
	if Input.is_action_just_pressed("respawn"):
		car.teleport(spawn)
		rig.snap()


func _process(_dt: float) -> void:
	debug.text = "%d km/h  G%s  %d rpm  %s" % [car.speed_kmh, car.drivetrain.gear_label(), car.drivetrain.rpm, (car.get_node("Aero") as ActiveAero).state_name()]
	_frames += 1
	if _shot_at > 0 and _frames == _shot_at:  # dev: --shot=<frame> saves logs/shot.png and quits
		get_viewport().get_texture().get_image().save_png("res://logs/shot.png")
		get_tree().quit()
