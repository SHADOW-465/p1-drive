extends Node3D
## Dev scene (T12): static 3x3 FULL block built synchronously. Checks collider vs visual surface,
## tile seams and a resting car, prints TILE PASS/FAIL. Windowed: drive around (--shot=N works).
## Args: --tile=tx,tz (default 0,-3 = hills)

var car: Car
var rig: CameraRig
var hms: Dictionary = {}  # Vector2i tile -> collider heights
var centre: Vector2i
var f: int = 0
var _shot_at: int = 0
var step_ms: Dictionary[int, float] = {}


func _ready() -> void:
	var t: PackedStringArray = Settings.arg_value("--tile", "0,-3").split(",")
	centre = Vector2i(int(t[0]), int(t[1]))
	Origin.reset()
	Origin.offset = Vector3(centre.x + 0.5, 0.0, centre.y + 0.5) * TileGen.TILE
	add_child(DayNight.new())
	var ms: float = 0.0
	for dz: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var d: Dictionary = TileGen.build(centre.x + dx, centre.y + dz, TileGen.FULL)
			ms += d["ms"]
			hms[Vector2i(centre.x + dx, centre.y + dz)] = d["hm"]
			var tile := TileNode.new()
			tile.setup(d)
			tile.position = Origin.to_local(Vector3(tile.tx, 0.0, tile.tz) * TileGen.TILE)
			add_child(tile)
			var more: bool = true
			var k: int = 0
			while more:
				var t0: int = Time.get_ticks_usec()
				more = tile.step()
				step_ms[k] = maxf(step_ms.get(k, 0.0), (Time.get_ticks_usec() - t0) / 1000.0)
				k += 1
	print("tile build avg %.1f ms; max apply ms per step %s" % [ms / 9.0, step_ms])
	car = (load("res://cars/p1/p1.tscn") as PackedScene).instantiate() as Car
	car.position = Vector3(0.0, surface(Origin.offset.x, Origin.offset.z) + 0.6, 0.0)
	add_child(car)
	rig = CameraRig.new()
	rig.car = car
	add_child(rig)
	_shot_at = int(Settings.arg_value("--shot", "0"))


## Visual surface height at world x/z: the mesh triangle under the point.
func surface(wx: float, wz: float) -> float:
	var tile := Vector2i(floori(wx / TileGen.TILE), floori(wz / TileGen.TILE))
	var hm: PackedFloat32Array = hms[tile]
	var n: int = TileGen.GRID[0]
	var fx: float = (wx - tile.x * TileGen.TILE) / 8.0
	var fz: float = (wz - tile.y * TileGen.TILE) / 8.0
	var i: int = mini(int(fx), n - 2)
	var j: int = mini(int(fz), n - 2)
	fx -= i
	fz -= j
	var h00: float = hm[j * n + i]
	var h10: float = hm[j * n + i + 1]
	var h01: float = hm[(j + 1) * n + i]
	var h11: float = hm[(j + 1) * n + i + 1]
	if fx + fz <= 1.0:
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	return h11 + (h01 - h11) * (1.0 - fx) + (h10 - h11) * (1.0 - fz)


func _check() -> String:
	# seams: shared edges identical
	var n: int = TileGen.GRID[0]
	for tile: Vector2i in hms:
		var a: PackedFloat32Array = hms[tile]
		if hms.has(tile + Vector2i(1, 0)):
			var b: PackedFloat32Array = hms[tile + Vector2i(1, 0)]
			for j: int in n:
				if a[j * n + n - 1] != b[j * n]:
					return "seam x at %s" % tile
		if hms.has(tile + Vector2i(0, 1)):
			var b: PackedFloat32Array = hms[tile + Vector2i(0, 1)]
			for i: int in n:
				if a[(n - 1) * n + i] != b[i]:
					return "seam z at %s" % tile
	# collider vs visual surface
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var worst: float = 0.0
	for k: int in 400:
		var p := Vector3(rng.randf_range(-1500.0, 1500.0), 0.0, rng.randf_range(-1500.0, 1500.0))
		if k < 40:  # some right on a tile border
			p.x = 512.0
		var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2000.0, p + Vector3.DOWN * 500.0)
		q.exclude = [car.get_rid()]
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return "no ground at %s" % p
		var w: Vector3 = Origin.to_world(p)
		worst = maxf(worst, absf((hit["position"] as Vector3).y - surface(w.x, w.z)))
	print("collider vs mesh: worst %.3f m" % worst)
	if worst > 0.05:
		return "collider off by %.2f m" % worst
	var cw: Vector3 = Origin.to_world(car.position)
	var rest: float = car.position.y - surface(cw.x, cw.z)
	print("car rest height above surface %.3f m, wheels %d" % [rest, car.wheels_in_contact()])
	if car.wheels_in_contact() < 4 or absf(rest) > 0.3 or car.global_basis.y.y < 0.8:
		return "car not resting on the terrain"
	return ""


func _physics_process(_dt: float) -> void:
	f += 1
	if f < 240:
		car.in_handbrake = true
		car.player_controlled = false
	elif f == 240:
		var msg: String = _check()
		print("TILE PASS" if msg == "" else "TILE FAIL: " + msg)
		car.player_controlled = true
		if DisplayServer.get_name() == "headless":
			get_tree().quit(0 if msg == "" else 1)
	if _shot_at > 0 and f == _shot_at:
		get_viewport().get_texture().get_image().save_png("res://logs/shot.png")
		get_tree().quit()
