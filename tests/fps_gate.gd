extends Node
## Gate (fps, M1; windowed, not in run_gates.bat): autopilot drive from a fixed spawn through one region.
## Args: -- --spawn=x,z --autodrive --region=<name> [--preset=low|medium] [--warmup=s --seconds=s --cockpit --png=path --png_at=s]. Reports avg / 1% low FPS, draw calls
## and triangles against the Medium budget (PLAN 6.3). Warns only; M2/M3 fix the perf, then this will fail.

const MAX_DRAWS: Dictionary = {"low": 110, "medium": 165}
const MAX_TRIS: Dictionary = {"low": 110000, "medium": 200000}
const MIN_AVG: Dictionary = {"low": 48.0, "medium": 40.0}
const MIN_LOW: Dictionary = {"low": 30.0, "medium": 25.0}

var main: Node3D
var car: Car
var t: float = 0.0
var ft: PackedFloat32Array = []
var draws: float = 0.0
var max_draws: float = 0.0
var tris: float = 0.0
var max_tris: float = 0.0
var preset: String = Settings.arg_value("--preset", "medium")
var WARMUP: float = float(Settings.arg_value("--warmup", "8"))
var SECONDS: float = float(Settings.arg_value("--seconds", "14"))
var worst_dt: float = 0.0
var worst_t: float = 0.0
var shot: String = Settings.arg_value("--png", "")
var _cockpit_on: bool = false
var _shot_done: bool = false
var region: String = Settings.arg_value("--region", "?")
var _gpu_ms: float = 0.0
var _rcpu_ms: float = 0.0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	process_mode = Node.PROCESS_MODE_ALWAYS  # --map pauses the game behind the full map; the timer and --png still run
	get_window().size = Vector2i(1366, 768)
	Settings.apply_preset(preset)
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car
	_cockpit_on = false


func _process(dt: float) -> void:
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)  # Settings.apply_all re-enables the user's vsync; FPS is measured uncapped
	if car.freeze:
		return
	t += dt
	if Settings.has_arg("--cockpit") and not _cockpit_on and t > 2.0:
		_cockpit_on = true
		main.rig.set_mode(CameraRig.Mode.COCKPIT)
		main.car.set_cockpit_active(true)
	if shot != "" and not _shot_done and t >= float(Settings.arg_value("--png_at", str(WARMUP + SECONDS * 0.5))):
		_shot_done = true
		get_viewport().get_texture().get_image().save_png(shot)
	if t < WARMUP:
		return
	ft.append(dt)
	if dt > worst_dt:
		worst_dt = dt
		worst_t = t
	var d: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var p: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	draws += d
	if Settings.has_arg("--breakdown"):
		var vp: RID = get_viewport().get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp, true)
		_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		_rcpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
	tris += p
	max_draws = maxf(max_draws, d)
	max_tris = maxf(max_tris, p)
	if t >= WARMUP + SECONDS:
		_finish()


func _finish() -> void:
	set_process(false)
	var n: int = ft.size()
	if Settings.has_arg("--breakdown"):
		_breakdown()
		print("BREAKDOWN ms/frame: render cpu %.2f gpu %.2f" % [_rcpu_ms / n, _gpu_ms / n])
	var sorted: PackedFloat32Array = ft.duplicate()
	sorted.sort()
	var avg_fps: float = n / maxf(t - WARMUP, 0.001)
	var low_fps: float = 1.0 / maxf(sorted[mini(int(n * 0.99), n - 1)], 0.0001)
	var min_fps: float = 1.0 / maxf(sorted[n - 1], 0.0001)
	var avg_draws: float = draws / n
	var avg_tris: float = tris / n
	var warns: PackedStringArray = []
	if avg_fps < MIN_AVG[preset]: warns.append("avg fps")
	if low_fps < MIN_LOW[preset]: warns.append("1% low")
	if max_draws > MAX_DRAWS[preset]: warns.append("draw calls")
	if max_tris > MAX_TRIS[preset]: warns.append("triangles")
	var wp: Vector3 = Origin.to_world(car.position)
	print("FPS %s [%s] at %d,%d: avg %.1f, 1%% low %.1f, min %.1f | draws avg %.0f max %.0f | tris avg %.0fk max %.0fk | worst %.0f ms at t=%.1f | %s" % [region, preset, wp.x, wp.z, avg_fps, low_fps, min_fps, avg_draws, max_draws, avg_tris / 1000.0, max_tris / 1000.0, worst_dt * 1000.0, worst_t, "within budget" if warns.is_empty() else "WARN over budget: " + ", ".join(warns)])
	main.call("quit_game")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0)  # reports only for now


## Dev (--breakdown): triangles and instances in visibility range of the camera, by node-name prefix (no frustum cull).
func _breakdown() -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var by_tris: Dictionary = {}
	var cnt: Dictionary = {}
	var stack: Array[Node] = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var gi := n as GeometryInstance3D
		if gi == null or not gi.is_visible_in_tree():
			continue
		var d: float = cam.global_position.distance_to(gi.global_position)
		if gi.visibility_range_end > 0.0 and (d > gi.visibility_range_end + 400.0 or d < gi.visibility_range_begin - 400.0):
			continue
		var nt: int = 0
		var inst: int = 1
		var mesh: Mesh = null
		if gi is MeshInstance3D:
			mesh = (gi as MeshInstance3D).mesh
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh != null:
			var mm: MultiMesh = (gi as MultiMeshInstance3D).multimesh
			mesh = mm.mesh
			inst = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
		if mesh == null:
			continue
		for si: int in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(si)
			var ix: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			nt += (ix.size() if not ix.is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		var key: String = n.name.rstrip("0123456789_").left(18)
		by_tris[key] = int(by_tris.get(key, 0)) + nt * inst
		cnt[key] = int(cnt.get(key, 0)) + 1
	var keys: Array = by_tris.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return int(by_tris[a]) > int(by_tris[b]))
	for k: String in keys.slice(0, 14):
		print("BREAKDOWN %-18s tris %7dk nodes %d" % [k, int(by_tris[k]) / 1000, int(cnt[k])])
