class_name TileStreamer
extends Node3D
## Tile streaming (PLAN 2.2): rings around the target's centre tile, worker builds,
## budgeted main-thread apply, build-then-swap LOD changes, throttled frees.

const HYST: float = 96.0
const APPLY_BUDGET_US: int = 2000
const MAX_JOBS: int = 2  # leaves cores for the main thread; 3 caused apply hitches
const MAX_FREES: int = 2

class Slot:
	var want: int = -1
	var live: TileNode  # visible tile (any LOD)
	var next: TileNode  # hidden, being applied; replaces live when complete
	var job: int = 0  # id of the accepted in-flight build, 0 = none

var target: Node3D  # local coords; usually the car
var centre: Vector2i = Vector2i(1 << 20, 0)
var full_count: int = 0
var lod_count: int = 0
var queue_len: int = 0  # builds wanted or in flight + tiles being applied
var last_apply_ms: float = 0.0
var max_step_ms: float = 0.0
var max_job_ms: float = 0.0
var frame_ms: float = 0.0  # whole streamer cost this frame

var _slots: Dictionary[Vector2i, Slot] = {}
var _applying: Array[TileNode] = []
var _free_q: Array[TileNode] = []
var _last_w: Vector3 = Vector3(1e9, 0.0, 1e9)
var _jobs: Dictionary[int, int] = {}  # job id -> WorkerThreadPool task id
var _next_job: int = 1
var _mutex: Mutex = Mutex.new()
var _results: Array[Array] = []  # [job id, key, data], pushed by workers


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	Origin.shifted.connect(_on_shift)
	Settings.settings_changed.connect(_on_settings_changed)
	TileGen.GRID.size()  # make sure the statics are initialised on the main thread
	Scatter.ensure_resources()
	TileNode.get_terrain_material()
	TileNode.get_road_material()
	TileNode.get_water_material()
	TileNode.get_props_material()
	TileNode.get_building_material()
	TileNode.get_building_lod_material()
	if not OsmWorld.enabled:
		(load("res://world/hero/city_downtown.gd") as GDScript).call("prewarm")
	var hero_cfg: Dictionary = TerrainFn.def.get("hero_tiles", {})
	for k: String in hero_cfg:
		var ov: String = str((hero_cfg[k] as Dictionary).get("overlay", ""))
		if ov != "" and not TileNode.overlay_cache.has(ov):
			var ps := ResourceLoader.load(ov) as PackedScene
			if ps != null:
				TileNode.overlay_cache[ov] = ps


func _on_settings_changed() -> void:
	Scatter.update_shader_ranges()
	for c: Node in get_children():
		var sc: Node = c.get_node_or_null(^"Scatter")
		if sc != null:
			for mmi: Node in sc.get_children():
				if mmi is MultiMeshInstance3D:
					Scatter.apply_settings_to_mmi(mmi as MultiMeshInstance3D)


func _exit_tree() -> void:
	for task: int in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_jobs.clear()
	TileNode.overlay_cache.clear()


## True when the 3x3 FULL block around the centre is live.
func is_ready() -> bool:
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var s: Slot = _slots.get(centre + Vector2i(dx, dz))
			if s == null or s.live == null or s.live.lod != TileGen.FULL:
				return false
	return true


func is_live(key: Vector2i, lod: int) -> bool:
	var s: Slot = _slots.get(key)
	return s != null and s.live != null and s.live.lod == lod


func _physics_process(_dt: float) -> void:
	if target != null:
		Origin.maybe_shift(target.position)


func _on_shift(d: Vector3) -> void:
	for c: Node in get_children():
		(c as Node3D).position -= d


func _process(_dt: float) -> void:
	if target == null:
		return
	var t0: int = Time.get_ticks_usec()
	if _update_centre(Origin.to_world(target.position)):
		_update_wants()
	var t1: int = Time.get_ticks_usec()
	_collect()
	var t2: int = Time.get_ticks_usec()
	_submit()
	var t3: int = Time.get_ticks_usec()
	_apply()
	var t4: int = Time.get_ticks_usec()
	for i: int in mini(MAX_FREES, _free_q.size()):
		(_free_q.pop_back() as TileNode).queue_free()
	var t5: int = Time.get_ticks_usec()
	FpsLog.tiles_full = full_count
	FpsLog.tiles_lod = lod_count
	frame_ms = (t5 - t0) / 1000.0
	if t5 - t0 > 20000:
		print("streamer hitch (us): wants %d collect %d submit %d apply %d free %d" % [t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4])


func _update_centre(w: Vector3) -> bool:
	var teleported: bool = w.distance_squared_to(_last_w) > 10000.0
	_last_w = w
	var t := Vector2i(floori(w.x / TileGen.TILE), floori(w.z / TileGen.TILE))
	if t == centre:
		return false
	if not teleported:
		var lo: Vector2 = Vector2(centre) * TileGen.TILE - Vector2(HYST, HYST)
		var hi: Vector2 = lo + Vector2.ONE * (TileGen.TILE + 2.0 * HYST)
		if w.x > lo.x and w.x < hi.x and w.z > lo.y and w.z < hi.y:
			return false
	centre = t
	return true


func _update_wants() -> void:
	for key: Vector2i in _slots.keys():
		var d: Vector2i = (key - centre).abs()
		if maxi(d.x, d.y) > 3:
			var s: Slot = _slots[key]
			_retire(s.live)
			_retire(s.next)
			_slots.erase(key)  # an in-flight result finds no slot and is dropped
	for dz: int in range(-3, 4):
		for dx: int in range(-3, 4):
			var key: Vector2i = centre + Vector2i(dx, dz)
			var s: Slot = _slots.get(key)
			if s == null:
				s = Slot.new()
				_slots[key] = s
			var want: int = maxi(maxi(absi(dx), absi(dz)) - 1, 0)
			if want != s.want:
				s.want = want
				s.job = 0
				_retire(s.next)
				s.next = null


func _retire(t: TileNode) -> void:
	if t != null:
		_applying.erase(t)
		_free_q.append(t)


func _collect() -> void:
	_mutex.lock()
	var res: Array[Array] = _results
	_results = []
	_mutex.unlock()
	for r: Array in res:
		if not WorkerThreadPool.is_task_completed(_jobs[r[0]]):
			_mutex.lock()  # result pushed but the task has not returned yet: next frame, no blocking
			_results.append(r)
			_mutex.unlock()
			continue
		WorkerThreadPool.wait_for_task_completion(_jobs[r[0]])
		_jobs.erase(r[0])
		var data: Dictionary = r[2]
		max_job_ms = maxf(max_job_ms, data["ms"])
		var s: Slot = _slots.get(r[1])
		if s == null or s.job != r[0]:
			continue  # stale
		s.job = 0
		var t := TileNode.new()
		t.setup(data)
		t.visible = false
		t.position = Origin.to_local(Vector3(t.tx, 0.0, t.tz) * TileGen.TILE)
		add_child(t)
		s.next = t
		_applying.append(t)


func _dist(key: Vector2i) -> int:
	var d: Vector2i = (key - centre).abs()
	return maxi(d.x, d.y) * 8 + mini(d.x, d.y)


func _submit() -> void:
	if _jobs.size() >= MAX_JOBS:
		queue_len = _jobs.size() + _applying.size() + 1
		return
	var todo: Array[Vector2i] = []
	for key: Vector2i in _slots:
		var s: Slot = _slots[key]
		if s.job == 0 and s.next == null and (s.live == null or s.live.lod != s.want):
			todo.append(key)
	queue_len = todo.size() + _jobs.size() + _applying.size()
	if todo.is_empty():
		return
	todo.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _dist(a) < _dist(b))
	for key: Vector2i in todo:
		if _jobs.size() >= MAX_JOBS:
			break
		var id: int = _next_job
		_next_job += 1
		_slots[key].job = id
		_jobs[id] = WorkerThreadPool.add_task(_job.bind(id, key, _slots[key].want))


## Worker thread: pure data in, pure data out.
func _job(id: int, key: Vector2i, lod: int) -> void:
	var data: Dictionary = TileGen.build(key.x, key.y, lod)
	_mutex.lock()
	_results.append([id, key, data])
	_mutex.unlock()


func _apply() -> void:
	last_apply_ms = 0.0
	if not _applying.is_empty():
		var t0: int = Time.get_ticks_usec()
		var now: int = t0
		while not _applying.is_empty() and now - t0 < APPLY_BUDGET_US:
			var best: int = 0
			for i: int in range(1, _applying.size()):
				if _dist(Vector2i(_applying[i].tx, _applying[i].tz)) < _dist(Vector2i(_applying[best].tx, _applying[best].tz)):
					best = i
			var t: TileNode = _applying[best]
			if not t.step():
				_applying.remove_at(best)
				var s: Slot = _slots[Vector2i(t.tx, t.tz)]
				if s.live != null:
					s.live.disarm_collision()
					_free_q.append(s.live)
				t.arm_collision()
				t.visible = true
				s.live = t
				s.next = null
			var then: int = now
			now = Time.get_ticks_usec()
			max_step_ms = maxf(max_step_ms, (now - then) / 1000.0)
			if now - then > 1500:
				break
		last_apply_ms = (now - t0) / 1000.0
	full_count = 0
	lod_count = 0
	for s: Slot in _slots.values():
		if s.live != null:
			if s.live.lod == TileGen.FULL:
				full_count += 1
			else:
				lod_count += 1
