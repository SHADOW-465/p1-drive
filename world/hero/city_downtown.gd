extends Node3D
## Medium-quality city downtown blockout (L2): 4x4 blocks inside tile (5, 5) around
## tile-local (512, 20, 512), 1 MultiMesh draw call + BoxShape3D colliders.
## Note: Fable's T24 upgrades this for High realism.

const GRID_ORIGIN: Vector2 = Vector2(512.0, 512.0)  # tile-local center of tile (5, 5)
const PITCH: float = 140.0
const GROUND_Y: float = TerrainFn.CITY_Y
const ROAD_CLEAR: float = 13.5  # half street width + sidewalk + margin

static var _box_mesh: ArrayMesh
static var _mat: ShaderMaterial
static var _cached_buf: PackedFloat32Array
static var _cached_boxes: Array[Array] = []  # [pos: Vector3, size: Vector3]

var _body: StaticBody3D
var _col_idx: int = 0


func _ready() -> void:
	_ensure_data()
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Towers"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _box_mesh
	mm.instance_count = _cached_buf.size() / 16
	mm.buffer = _cached_buf
	mmi.multimesh = mm
	mmi.material_override = _mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if Settings.shadow_quality >= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

	_body = StaticBody3D.new()
	_body.name = "CityColliders"
	add_child(_body)


func _process(_dt: float) -> void:
	if _col_idx >= _cached_boxes.size():
		set_process(false)
		return
	var end_i: int = mini(_col_idx + 12, _cached_boxes.size())
	for i: int in range(_col_idx, end_i):
		var b: Array = _cached_boxes[i]
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = b[1]
		cs.shape = sh
		cs.position = b[0]
		_body.add_child(cs)
	_col_idx = end_i


static func _ensure_data() -> void:
	if _box_mesh != null:
		return
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/building.gdshader")
	_box_mesh = _make_uv_box()

	var rng := RandomNumberGenerator.new()
	rng.seed = 202611
	var palette: PackedColorArray = [
		Color(0.24, 0.26, 0.30).srgb_to_linear(),
		Color(0.32, 0.31, 0.29).srgb_to_linear(),
		Color(0.20, 0.24, 0.28).srgb_to_linear(),
		Color(0.36, 0.32, 0.28).srgb_to_linear(),
		Color(0.18, 0.20, 0.24).srgb_to_linear(),
	]
	var instances: Array[Array] = []
	for bz: int in range(-2, 2):
		for bx: int in range(-2, 2):
			var cx: float = GRID_ORIGIN.x + (bx + 0.5) * PITCH
			var cz: float = GRID_ORIGIN.y + (bz + 0.5) * PITCH
			var inner: float = PITCH - 2.0 * ROAD_CLEAR  # ~113 m usable block
			var is_core: bool = (bx >= -1 and bx <= 0 and bz >= -1 and bz <= 0)
			if bx == -2 and bz == 1:
				# Small low-rise plaza block for variety
				_add_bldg(instances, Vector3(cx, GROUND_Y, cz), Vector3(44.0, 11.0, 44.0), palette[1], rng.randf())
				continue
			# 2x2 sub-lots per block
			var lot: float = inner * 0.44
			for sz: int in 2:
				for sx: int in 2:
					if rng.randf() < 0.14:
						continue
					var lx: float = cx + (sx - 0.5) * (inner * 0.50)
					var lz: float = cz + (sz - 0.5) * (inner * 0.50)
					var w: float = rng.randf_range(lot * 0.62, lot * 0.92)
					var d: float = rng.randf_range(lot * 0.62, lot * 0.92)
					var h: float = rng.randf_range(38.0, 105.0) if is_core else rng.randf_range(14.0, 48.0)
					var col: Color = palette[rng.randi() % palette.size()]
					_add_bldg(instances, Vector3(lx, GROUND_Y, lz), Vector3(w, h, d), col, rng.randf())

	_cached_buf = PackedFloat32Array()
	_cached_buf.resize(instances.size() * 16)
	for i: int in instances.size():
		var it: Array = instances[i]
		var pos: Vector3 = it[0]
		var sz: Vector3 = it[1]
		var col: Color = it[2]
		var o: int = i * 16
		_cached_buf[o] = sz.x
		_cached_buf[o + 1] = 0.0
		_cached_buf[o + 2] = 0.0
		_cached_buf[o + 3] = pos.x
		_cached_buf[o + 4] = 0.0
		_cached_buf[o + 5] = sz.y
		_cached_buf[o + 6] = 0.0
		_cached_buf[o + 7] = pos.y + sz.y * 0.5
		_cached_buf[o + 8] = 0.0
		_cached_buf[o + 9] = 0.0
		_cached_buf[o + 10] = sz.z
		_cached_buf[o + 11] = pos.z
		_cached_buf[o + 12] = col.r
		_cached_buf[o + 13] = col.g
		_cached_buf[o + 14] = col.b
		_cached_buf[o + 15] = it[3]


static func _add_bldg(instances: Array[Array], base: Vector3, sz: Vector3, col: Color, seed_a: float) -> void:
	instances.append([base, sz, col, seed_a])
	_cached_boxes.append([Vector3(base.x, base.y + sz.y * 0.5, base.z), sz])


static func _make_uv_box() -> ArrayMesh:
	# Unit cube [-0.5..0.5] with UV scaled ~32 m so windows tile nicely on average towers.
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var u := PackedVector2Array()
	var idx := PackedInt32Array()
	var faces: Array = [
		[Vector3(-0.5, -0.5, 0.5), Vector3(0.5, -0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(-0.5, 0.5, 0.5), Vector3(0, 0, 1)],
		[Vector3(0.5, -0.5, -0.5), Vector3(-0.5, -0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0, 0, -1)],
		[Vector3(0.5, -0.5, 0.5), Vector3(0.5, -0.5, -0.5), Vector3(0.5, 0.5, -0.5), Vector3(0.5, 0.5, 0.5), Vector3(1, 0, 0)],
		[Vector3(-0.5, -0.5, -0.5), Vector3(-0.5, -0.5, 0.5), Vector3(-0.5, 0.5, 0.5), Vector3(-0.5, 0.5, -0.5), Vector3(-1, 0, 0)],
		[Vector3(-0.5, 0.5, 0.5), Vector3(0.5, 0.5, 0.5), Vector3(0.5, 0.5, -0.5), Vector3(-0.5, 0.5, -0.5), Vector3(0, 1, 0)],
	]
	for f: Array in faces:
		var b: int = v.size()
		v.append_array([f[0], f[1], f[2], f[3]])
		var nrm: Vector3 = f[4]
		n.append_array([nrm, nrm, nrm, nrm])
		u.append_array([Vector2(0.0, 0.0), Vector2(32.0, 0.0), Vector2(32.0, 48.0), Vector2(0.0, 48.0)])
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = u
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m
