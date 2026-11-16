extends Node3D
## Gate 4 (PLAN 8.4): drags the frozen car around a closed route at SPEED (wall clock, so
## worker builds get real time), then checks a live origin shift with the car at rest.
## Prints STREAM PASS / STREAM FAIL: <reason>.

const SPEED: float = 350.0  # m/s; 3.6x the car's top speed
const ROUTE: PackedVector2Array = [Vector2(-5000, -6500), Vector2(5500, -5200), Vector2(-2500, 3500)]

var car: Car
var world: TileStreamer
var pts: PackedVector2Array
var seg: int = 0
var seg_d: float = 0.0
var wpos: Vector3
var phase: int = 0
var f: int = 0
var last_us: int = 0
var visited: Dictionary[Vector2i, bool] = {}
var stalls: int = 0
var stalled: bool = false
var frame_ms: PackedFloat32Array = []
var max_full: int = 0
var max_total: int = 0
var max_nodes: int = 0
var mem0: float = 0.0
var nodes0: float = 0.0
var rest_w: Vector3
var fail: String = ""


func _ready() -> void:
	Engine.max_fps = 60
	Origin.reset()
	pts = ROUTE.duplicate()
	pts.append(ROUTE[0])
	wpos = Vector3(pts[0].x, 0.0, pts[0].y)
	Origin.offset = Vector3(roundf(wpos.x / 1024.0), 0.0, roundf(wpos.z / 1024.0)) * 1024.0
	car = (load("res://cars/p1/p1.tscn") as PackedScene).instantiate() as Car
	car.player_controlled = false
	car.freeze = true
	add_child(car)
	world = TileStreamer.new()
	world.target = car
	add_child(world)
	Origin.shifted.connect(_on_shift)
	_place()


func _place() -> void:
	wpos.y = TerrainFn.base_height(wpos.x, wpos.z) + 0.5
	car.position = Origin.to_local(wpos)


func _on_shift(_d: Vector3) -> void:
	# listeners run in connect order: the car has already moved itself
	if Origin.to_world(car.position).distance_to(wpos) > 0.01:
		fail = "car world position jumped across an origin shift"


func _process(_dt: float) -> void:
	var now: int = Time.get_ticks_usec()
	var dt: float = minf((now - last_us) / 1e6, 0.05)
	last_us = now
	f += 1
	max_full = maxi(max_full, world.full_count)
	max_total = maxi(max_total, world.full_count + world.lod_count)
	max_nodes = maxi(max_nodes, world.get_child_count())
	if maxf(absf(car.position.x), absf(car.position.z)) > 3100.0:
		fail = "car local position beyond 3100 m"
	match phase:
		0:  # warm-up: wait for the full 7x7 set
			if world.is_ready() and world.queue_len == 0 and f > 30:
				mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
				nodes0 = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
				phase = 1
			elif f > 3600:
				fail = "warm-up timeout"
		1:  # out and back
			frame_ms.append(world.frame_ms)
			var tile := Vector2i(floori(wpos.x / 1024.0), floori(wpos.z / 1024.0))
			visited[tile] = true
			var inside: float = minf(minf(wpos.x - tile.x * 1024.0, (tile.x + 1) * 1024.0 - wpos.x), minf(wpos.z - tile.y * 1024.0, (tile.y + 1) * 1024.0 - wpos.z))
			if inside > 300.0 and not world.is_live(tile, TileGen.FULL):
				if not stalled:
					stalls += 1
					stalled = true
				return
			stalled = false
			var a: Vector2 = pts[seg]
			var b: Vector2 = pts[seg + 1]
			seg_d += SPEED * dt
			if seg_d >= a.distance_to(b):
				seg_d = 0.0
				seg += 1
				a = b
				if seg == pts.size() - 1:
					phase = 2
					f = 0
			var p: Vector2 = a.move_toward(pts[mini(seg + 1, pts.size() - 1)], seg_d)
			wpos = Vector3(p.x, 0.0, p.y)
			_place()
		2:  # settle at the start point, then compare memory
			if world.queue_len == 0 and world.get_child_count() <= 49 and f > 60:
				var mem: float = Performance.get_monitor(Performance.MEMORY_STATIC)
				var nodes: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
				print("memory %.1f -> %.1f MB, nodes %d -> %d" % [mem0 / 1e6, mem / 1e6, nodes0, nodes])
				if mem > mem0 * 1.15 or nodes > nodes0 * 1.15:
					fail = "memory or node count grew"
				if world.full_count != 9 or world.lod_count != 40:
					fail = "idle tile counts %d/%d" % [world.full_count, world.lod_count]
				car.freeze = false
				car.in_handbrake = true
				phase = 3
				f = 0
			elif f > 1200:
				fail = "settle timeout"
		3:  # car at rest on the terrain, then a forced origin shift
			if f == 150:
				rest_w = Origin.to_world(car.position)
				wpos = rest_w
				Origin.shift_by(Vector3(1024.0, 0.0, -1024.0))
			elif f == 240:
				var moved: float = Origin.to_world(car.position).distance_to(rest_w)
				print("rest shift: moved %.3f m, wheels %d" % [moved, car.wheels_in_contact()])
				if moved > 0.1 or car.wheels_in_contact() < 4 or car.global_basis.y.y < 0.7:
					fail = "car disturbed by an origin shift at rest"
				phase = 4
		4:
			_finish()
			return
	if fail != "":
		_finish()


func _finish() -> void:
	set_process(false)
	frame_ms.sort()
	var n: int = frame_ms.size()
	if n > 0:
		var sum: float = 0.0
		for v: float in frame_ms:
			sum += v
		print("streamer frame ms: avg %.2f p99 %.2f max %.2f | max step %.2f, max job %.0f ms" % [sum / n, frame_ms[int(n * 0.99)], frame_ms[n - 1], world.max_step_ms, world.max_job_ms])
		print("tiles visited %d, origin shifts %d, stalls %d, max full %d, max total %d, max nodes %d" % [visited.size(), Origin.shifts, stalls, max_full, max_total, max_nodes])
		if fail == "":
			if frame_ms[int(n * 0.99)] > 8.0 or frame_ms[n - 1] > 25.0:
				fail = "streamer frame time over budget"
			elif stalls > 0:
				fail = "%d stalls" % stalls
			elif visited.size() < 24:
				fail = "only %d tiles visited" % visited.size()
			elif Origin.shifts < 3:
				fail = "too few origin shifts"
			elif max_full > 14 or max_total > 49 or max_nodes > 70:
				fail = "tile counts unbounded"
			elif Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) > 0:
				fail = "orphan nodes"
	print("STREAM PASS" if fail == "" else "STREAM FAIL: " + fail)
	get_tree().quit(0 if fail == "" else 1)
