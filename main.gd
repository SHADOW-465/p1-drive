extends Node3D
## Composes world + car + camera + UI; boot/respawn flow; dev args (T19).

@onready var car: Car = $P1
@onready var world: TileStreamer = $World
@onready var sky: DayNight = $Sky
var rig: CameraRig
var hud: HUD
var pause_menu: PauseMenu
var full_map: FullMap
var _fade: ColorRect
var _boot_ready: bool = false
var _fade_a: float = 1.0
var _autodrive: Autodrive = null
var spawn: Transform3D
var _frames: int = 0
var _shot_at: int = 0
var fall_count: int = 0
var _fall_cool: float = 0.0


func _ready() -> void:
	get_tree().auto_accept_quit = false
	Origin.reset()
	car.set_meta("car_id", "p1")
	_install_car(Settings.arg_value("--car", Settings.car_id))
	var spawn_w: Vector3 = Vector3(0.0, 20.0, 0.0)
	var spawn_fwd: Vector3 = Vector3.FORWARD
	# Every spawn goes through RoadMesher.spawn_pose: a lane of a real road stretch, never a junction pad or a sidewalk.
	var pose: Dictionary = {}
	if RoadGraph.spawn_edge >= 0:
		pose = RoadMesher.spawn_pose(RoadGraph.spawn_pos, RoadGraph.spawn_fwd.dot(RoadGraph.tangent(RoadGraph.spawn_edge, RoadGraph.spawn_i)))
	elif not RoadGraph.e_pts.is_empty():
		pose = RoadMesher.spawn_pose(RoadGraph.e_pts[0][mini(10, RoadGraph.e_pts[0].size() - 1)])
	var arg_sp: String = Settings.arg_value("--spawn", "")
	if arg_sp != "":
		var sp_parts: PackedStringArray = arg_sp.split(",")
		if sp_parts.size() >= 2:
			# --spawn=x,z[,dir[,y]]: dir -1 drives against the edge order; y picks the deck of stacked roads.
			var sp_y: float = float(sp_parts[3]) if sp_parts.size() >= 4 else 0.0
			var sp_pose: Dictionary = RoadMesher.spawn_pose(Vector3(float(sp_parts[0]), sp_y, float(sp_parts[1])), -1.0 if sp_parts.size() >= 3 and float(sp_parts[2]) < 0.0 else 1.0)
			if not sp_pose.is_empty():
				pose = sp_pose
	if not pose.is_empty():
		spawn_w = pose["pos"]
		spawn_fwd = pose["fwd"]
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
	var arg_cam: String = Settings.arg_value("--cam", "")
	if arg_cam == "cockpit":
		rig.set_mode(CameraRig.Mode.COCKPIT)
	elif arg_cam == "hood":
		rig.set_mode(CameraRig.Mode.HOOD)
	add_child(rig)
	rig.snap()

	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)
	hud = (preload("res://ui/hud.tscn") as PackedScene).instantiate() as HUD
	hud.car = car
	hud.sky = sky
	ui.add_child(hud)
	pause_menu = (preload("res://ui/pause_menu.tscn") as PackedScene).instantiate() as PauseMenu
	pause_menu.respawn_requested.connect(_respawn)
	pause_menu.car_selected.connect(_swap_car)
	pause_menu.quit_requested.connect(quit_game)
	pause_menu.time_set_requested.connect(sky.set_time)
	ui.add_child(pause_menu)
	full_map = FullMap.new()
	full_map.name = "FullMap"
	full_map.car = car
	ui.add_child(full_map)

	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(_fade)

	if Settings.has_arg("--autodrive"):
		car.player_controlled = false
		_autodrive = Autodrive.new()
		_autodrive.sync_to_world(spawn_w, spawn_fwd)

	_shot_at = int(Settings.arg_value("--shot", "0"))
	Settings.apply_all(self)
	var arg_w: String = Settings.arg_value("--weather", "")
	if arg_w != "":
		Settings.weather_mode = arg_w
	var arg_h: String = Settings.arg_value("--hour", "")
	if arg_h != "":
		sky.set_time(float(arg_h))
	var wp_arg: String = Settings.arg_value("--waypoint", "")
	if wp_arg != "":
		var wp_parts: PackedStringArray = wp_arg.split(",")
		if wp_parts.size() >= 2:
			var car_w: Vector3 = Origin.to_world(car.global_position)
			GpsRoute.place(Vector2(car_w.x, car_w.z), Vector2(float(wp_parts[0]), float(wp_parts[1])))


## Replace the player car with CarRegistry id (before refs are wired). Keeps the node name "P1" for tests.
func _install_car(id: String) -> void:
	id = CarRegistry.resolve(id)
	if str(car.get_meta("car_id", "p1")) == id:
		return
	var old: Car = car
	var nc: Car = CarRegistry.instantiate(id)
	nc.name = "P1"
	nc.transform = old.transform
	nc.freeze = old.freeze
	remove_child(old)
	old.queue_free()
	add_child(nc)
	car = nc


## Live swap from the settings menu: new car, refs rewired, put back on the road.
func _swap_car(id: String) -> void:
	if str(car.get_meta("car_id", "p1")) == CarRegistry.resolve(id):
		return
	_install_car(id)
	world.target = car
	rig.car = car
	hud.set_car(car)
	full_map.car = car
	if _autodrive != null:
		car.player_controlled = false
	car.set_cockpit_active(rig.mode == CameraRig.Mode.COCKPIT)
	_respawn()


func _respawn() -> void:
	var wpos: Vector3 = Origin.to_world(car.position)
	var xf: Transform3D = spawn
	var to_car: Vector3 = car.global_transform.basis.z * -1.0
	var pose: Dictionary = RoadMesher.spawn_pose(wpos, 1.0)
	if not pose.is_empty():
		# keep the heading the car had: respawn into the lane that runs that way
		if (pose["fwd"] as Vector3).dot(to_car) < 0.0:
			pose = RoadMesher.spawn_pose(wpos, -1.0)
		var fwd: Vector3 = pose["fwd"]
		fwd.y = 0.0
		if fwd.length_squared() < 1e-4:
			fwd = Vector3.FORWARD
		xf = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), Origin.to_local(pose["pos"]) + Vector3(0.0, 0.45, 0.0))
	car.teleport(xf)
	rig.snap()
	if _autodrive != null:
		_autodrive.sync_to_world(Origin.to_world(car.position))


## Offset from the road centreline into the right-hand lane (clears the highway median).
func _lane_shift(edge: int, fwd: Vector3, i: int = -1) -> Vector3:
	var flat := Vector3(fwd.x, 0.0, fwd.z)
	if flat.length_squared() < 1e-4:
		return Vector3.ZERO
	var dir: int = 1 if i < 0 or flat.dot(RoadGraph.tangent(edge, i)) >= 0.0 else -1
	return flat.normalized().cross(Vector3.UP) * RoadGraph.lane_offset(edge, i, dir)


func _physics_process(dt: float) -> void:
	if not _boot_ready:
		if world.is_ready():
			_boot_ready = true
			car.teleport(spawn)
			car.freeze = false
			rig.snap()
		return
	if Input.is_action_just_pressed("respawn"):
		_respawn()
	elif _fall_cool > 0.0:
		_fall_cool -= dt
	elif not car.freeze:
		_fall_guard()
	if _autodrive != null:
		_autodrive.drive(car)


## Road deck when we are on one (including a river road built above the carve);
## otherwise the sculpted terrain. Tunnels and bridges use the deck only while
## the car is still up on it.
func surface_y(wpos: Vector3) -> float:
	var terrain_y: float = TerrainFn.base_height(wpos.x, wpos.z)
	var np: Dictionary = RoadGraph.nearest_point(wpos, 45.0)
	if np.is_empty():
		return terrain_y
	var rp: Vector3 = np["pos"]
	var horiz: float = Vector2(wpos.x - rp.x, wpos.z - rp.z).length()
	if horiz > 26.0:
		return terrain_y
	var road_y: float = rp.y
	var on_deck: bool = RoadGraph.e_elev[int(np["edge"])] == 1 or RoadGraph.e_kind[int(np["edge"])] == RoadGraph.KIND_TUNNEL
	if on_deck and wpos.y < road_y - 2.0:
		return terrain_y
	return road_y


func _fall_guard() -> void:
	var wpos: Vector3 = Origin.to_world(car.position)
	if wpos.y < surface_y(wpos) - 2.4:
		fall_count += 1
		_fall_cool = 1.0
		_respawn()


func _process(dt: float) -> void:
	if _boot_ready and _fade_a > 0.0:
		_fade_a = maxf(_fade_a - dt * 2.5, 0.0)
		_fade.color.a = _fade_a
		if _fade_a <= 0.0:
			_fade.visible = false
	if _boot_ready:
		_frames += 1
		if _frames == 2 and Settings.has_arg("--map") and full_map != null:
			full_map.open_map()
		if _shot_at > 0 and _frames == _shot_at:  # dev: --shot=<frame> saves logs/shot.png and quits
			get_viewport().get_texture().get_image().save_png("res://logs/shot.png")
			quit_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game()


## Stops audio first: quitting with playing streams reports leaked playbacks.
func quit_game() -> void:
	get_tree().paused = false
	MapData.shutdown_bg()
	for p: Node in find_children("*", "AudioStreamPlayer", true, false):
		(p as AudioStreamPlayer).stop()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()
