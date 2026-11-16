extends Node3D
## Composes world + car + camera + UI; boot/respawn flow; dev args.

@onready var car: Car = $P1
var rig: CameraRig
var debug: Label
var pause_menu: PauseMenu
var spawn: Transform3D
var _frames: int = 0
var _shot_at: int = 0


func _ready() -> void:
	get_tree().auto_accept_quit = false
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
	pause_menu = (preload("res://ui/pause_menu.tscn") as PackedScene).instantiate() as PauseMenu
	pause_menu.respawn_requested.connect(_respawn)
	pause_menu.quit_requested.connect(quit_game)
	ui.add_child(pause_menu)
	_shot_at = int(Settings.arg_value("--shot", "0"))
	Settings.apply_all(self)


func _respawn() -> void:
	car.teleport(spawn)
	rig.snap()


func _physics_process(_dt: float) -> void:
	if Input.is_action_just_pressed("respawn"):
		_respawn()


func _process(_dt: float) -> void:
	debug.text = "%d km/h  G%s  %d rpm  %s" % [car.speed_kmh, car.drivetrain.gear_label(), car.drivetrain.rpm, (car.get_node("Aero") as ActiveAero).state_name()]
	_frames += 1
	if _shot_at > 0 and _frames == _shot_at:  # dev: --shot=<frame> saves logs/shot.png and quits
		get_viewport().get_texture().get_image().save_png("res://logs/shot.png")
		quit_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


## Stops audio first: quitting with playing streams reports leaked playbacks.
func quit_game() -> void:
	get_tree().paused = false
	for p: Node in find_children("*", "AudioStreamPlayer", true, false):
		(p as AudioStreamPlayer).stop()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()
