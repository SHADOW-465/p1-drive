extends Node3D
## Composes world + car + camera + UI; boot/respawn flow; dev args (T19).

@onready var car: Car = $P1
@onready var world: TileStreamer = $World
@onready var sky: DayNight = $Sky
var rig: CameraRig
var debug: Label
var pause_menu: PauseMenu
var _fade: ColorRect
var _boot_ready: bool = false
var _fade_a: float = 1.0
var _autodrive: Autodrive = null
var spawn: Transform3D
var _frames: int = 0
var _shot_at: int = 0


func _ready() -> void:
	get_tree().auto_accept_quit = false
	Origin.reset()
	var spawn_w: Vector3 = Vector3(0.0, 20.0, 0.0)
	var spawn_fwd: Vector3 = Vector3.FORWARD
	if not RoadGraph.e_pts.is_empty():
		var pts: PackedVector3Array = RoadGraph.e_pts[0]
		var idx: int = mini(10, pts.size() - 1)
		spawn_w = pts[idx]
		spawn_fwd = RoadGraph.tangent(0, idx)
	Origin.offset = Vector3(floorf(spawn_w.x / TileGen.TILE), 0.0, floorf(spawn_w.z / TileGen.TILE)) * TileGen.TILE
	spawn_fwd.y = 0.0
	if spawn_fwd.length_squared() < 1e-4:
		spawn_fwd = Vector3.FORWARD
	spawn = Transform3D(Basis.looking_at(spawn_fwd.normalized(), Vector3.UP), Origin.to_local(spawn_w) + Vector3(0.0, 0.38, 0.0))
	car.freeze = true
	car.teleport(spawn)
	world.target = car

	rig = CameraRig.new()
	rig.car = car
	add_child(rig)
	rig.snap()

	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	debug = Label.new()
	debug.position = Vector2(16.0, 12.0)
	ui.add_child(debug)
	pause_menu = (preload("res://ui/pause_menu.tscn") as PackedScene).instantiate() as PauseMenu
	pause_menu.respawn_requested.connect(_respawn)
	pause_menu.quit_requested.connect(quit_game)
	pause_menu.time_set_requested.connect(sky.set_time)
	ui.add_child(pause_menu)

	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(_fade)

	if Settings.has_arg("--autodrive"):
		car.player_controlled = false
		_autodrive = Autodrive.new()
		_autodrive.sync_to_world(spawn_w)

	_shot_at = int(Settings.arg_value("--shot", "0"))
	Settings.apply_all(self)


func _respawn() -> void:
	var wpos: Vector3 = Origin.to_world(car.position)
	var np: Dictionary = RoadGraph.nearest_point(wpos)
	var xf: Transform3D = spawn
	if not np.is_empty():
		var fwd: Vector3 = np["tangent"]
		fwd.y = 0.0
		if fwd.length_squared() < 1e-4:
			fwd = Vector3.FORWARD
		xf = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), Origin.to_local(np["pos"]) + Vector3(0.0, 0.45, 0.0))
	car.teleport(xf)
	rig.snap()
	if _autodrive != null:
		_autodrive.sync_to_world(Origin.to_world(car.position))


func _physics_process(_dt: float) -> void:
	if not _boot_ready:
		if world.is_ready():
			_boot_ready = true
			car.teleport(spawn)
			car.freeze = false
			rig.snap()
		return
	if Input.is_action_just_pressed("respawn"):
		_respawn()
	if _autodrive != null:
		_autodrive.drive(car)


func _process(dt: float) -> void:
	if _boot_ready and _fade_a > 0.0:
		_fade_a = maxf(_fade_a - dt * 2.5, 0.0)
		_fade.color.a = _fade_a
		if _fade_a <= 0.0:
			_fade.visible = false
	var d_tag: String = "  DRIFT" if car.drift_mode else ""
	debug.text = "%d km/h  G%s  %d rpm  %s%s" % [car.speed_kmh, car.drivetrain.gear_label(), car.drivetrain.rpm, (car.get_node("Aero") as ActiveAero).state_name(), d_tag]
	if _boot_ready:
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
