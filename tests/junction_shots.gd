extends Node
## Dev (not a gate, M5): bird's-eye proof shot of road junctions. Run windowed:
## `-- --spawn=x,z --node=<id>[,<id>...] [--png=res://logs/m5_junction.png] [--cam=back,up]`
## Waits for the tiles, then frames each node from `back` m behind / `up` m above its first arm and saves
## logs/junction_<id>.png (or --png for a single node). The HUD is hidden.

var main: Node3D
var car: Car
var nodes: PackedInt32Array = []
var k: int = -1
var wait: int = 0
var cam: Camera3D


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().size = Vector2i(1366, 768)
	for s: String in Settings.arg_value("--node", "0").split(","):
		nodes.append(int(s))
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _process(_dt: float) -> void:
	if car.freeze:
		return
	car.freeze = true  # parked: only the camera moves
	(main.get("hud") as CanvasItem).visible = false
	wait += 1
	if cam == null:
		cam = Camera3D.new()
		cam.far = 3000.0
		add_child(cam)
	if wait == 30 or (wait > 30 and wait % 90 == 0):
		if k >= 0:
			var path: String = Settings.arg_value("--png", "") if nodes.size() == 1 and Settings.arg_value("--png", "") != "" else "res://logs/junction_%d.png" % nodes[k]
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
		k += 1
		if k >= nodes.size():
			main.call("quit_game")
			get_tree().quit()
			return
		var n: int = nodes[k]
		var c: Vector3 = RoadGraph.nodes[n]
		var arm: Vector3 = RoadMesher._out_dir_xz(RoadGraph.node_edges[n][0], n)
		var cv: PackedStringArray = Settings.arg_value("--cam", "38,30").split(",")
		var eye: Vector3 = c + arm * float(cv[0]) + Vector3.UP * float(cv[1])
		cam.global_position = Origin.to_local(eye)
		cam.look_at(Origin.to_local(c), Vector3.UP)
		cam.make_current()
