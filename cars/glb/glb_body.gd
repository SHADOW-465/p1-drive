class_name GlbBody
extends Node3D
## Generic GLB car (data/cars.json): fits the model to real size, moves tyre/rim meshes onto the
## VehicleWheel3D nodes (so they spin + steer), builds PBR/emissive materials, applies the def's tuning.

const PROXY_CELL: float = 0.12  ## m, shadow-proxy vertex grid
const STATIC_SAG: float = 0.04  ## m, suspension compression at rest; sets how the body sits on the springs
const CONTACT_SLOP: float = 0.028  ## m, Jolt settles the wheel this far into the road; added to wheel_radius so the visible tyre touches

var def: Dictionary
var _car: Car
var _wheels: Array[VehicleWheel3D] = []
var _calipers: Array[Node3D] = []
var _glass: Array[StandardMaterial3D] = []
var _mat_cache := {}
var _scale: float = 1.0  ## model units -> metres
var _head: StandardMaterial3D
var _tail: StandardMaterial3D


## _enter_tree, not _ready: VehicleWheel3D captures its connection point when it enters the tree (runs after us, we are first child).
func _enter_tree() -> void:
	_car = get_parent() as Car
	def = CarRegistry.get_def(str(_car.get_meta("car_id", "mclaren_600lt")))
	var model: Node3D = (load(str(def["glb"])) as PackedScene).instantiate() as Node3D
	model.rotation.y = deg_to_rad(float(def.get("model_yaw_deg", 0.0)))
	add_child(model)
	var meshes: Array[MeshInstance3D] = []
	for n: Node in model.find_children("*", "MeshInstance3D", true, false):
		meshes.append(n as MeshInstance3D)

	# real size: uniform scale from length, bottom on y=0
	var bb: AABB = _bounds(meshes)
	var s: float = float(def["length"]) / bb.size.z
	model.scale = Vector3.ONE * s
	_scale = s
	model.position.y = -bb.position.y * s

	# Calipers live under the wheel assembly (Wheel1A) but must not be moved with the rims.
	# _move() bakes _rel(); a second move, after the mesh is parented to VehicleWheel3D, walks
	# up through the car and bakes the car's world pose into the caliper, so it floats off the hub.
	var cal_m: Array[MeshInstance3D] = _matching(meshes, def.get("caliper_match", []))
	var cal_set: Dictionary = {}
	for m: MeshInstance3D in cal_m:
		cal_set[m] = true
	var wheel_m: Array[MeshInstance3D] = []
	for m: MeshInstance3D in _matching(meshes, def["wheel_match"]):
		if not cal_set.has(m):
			wheel_m.append(m)
	var mid_z: float = _bounds(wheel_m).get_center().z
	model.position.z -= mid_z  # origin at the middle of the wheelbase

	_wheels = [_car.get_node("WheelFL"), _car.get_node("WheelFR"), _car.get_node("WheelRL"), _car.get_node("WheelRR")]
	var buckets: Array = [[], [], [], []]
	var cal_buckets: Array = [[], [], [], []]
	for m: MeshInstance3D in wheel_m:
		buckets[_corner(m)].append(m)
	for m: MeshInstance3D in cal_m:
		var b: AABB = _car_bb(m)
		var thin: float = minf(b.size.x, minf(b.size.y, b.size.z))
		var wide: float = maxf(b.size.x, maxf(b.size.y, b.size.z))
		# A disc in the caliper group is the rotor: it spins with the rim. The caliper body does not.
		if thin < 0.04 and wide > 0.22:
			buckets[_corner(m)].append(m)
		else:
			cal_buckets[_corner(m)].append(m)
	for i: int in 4:
		var w: VehicleWheel3D = _wheels[i]
		var tb: AABB = _bounds(buckets[i])
		var hub := Vector3((-1.0 if i % 2 == 0 else 1.0) * float(def["track_front" if i < 2 else "track_rear"]) * 0.5, tb.get_center().y, tb.get_center().z)
		w.wheel_radius = tb.size.y * 0.5 + CONTACT_SLOP
		var cal := Node3D.new()
		cal.name = "Caliper" + String(w.name).substr(5)
		add_child(cal)
		_calipers.append(cal)
		_move(buckets[i], w, hub)
		_move(cal_buckets[i], cal, hub)
		w.position = hub + Vector3(0.0, w.wheel_rest_length - STATIC_SAG, 0.0)

	if def.has("wing_match"):
		_build_aero(meshes)

	for m: MeshInstance3D in _matching(meshes, def.get("hide_match", [])):  # e.g. the fastened seat belt across the driver's view
		m.get_parent().remove_child(m)
		m.queue_free()

	_setup_lights()
	_materials(self)  # model + calipers + wing (wheels follow)
	for w: VehicleWheel3D in _wheels:  # wheel/rim/tyre meshes live under the wheels now, not the model
		_materials(w)
	_merge_meshes()
	_tune()


## Collapse the model's hundreds of MeshInstance3Ds into one per (parent node, shadow flag): one surface per material.
## Keeps node names the aero/wheel/caliper code and the cockpit's steering-wheel adoption rely on.
func _merge_meshes() -> void:
	var keep: Array = def.get("cockpit", {}).get("steer_match", ["SteeringWheel"])
	var parents: Array[Node] = [self]
	parents.append_array(_wheels)
	parents.append_array(_calipers)
	for n: String in ["WingPivot", "Struts"]:
		var a: Node = find_child(n, true, false)
		if a != null:
			parents.append(a)
	for p: Node in parents:
		var groups := {}  # cast_shadow -> {material -> SurfaceTool}
		var olds: Array[MeshInstance3D] = []
		for n: Node in p.find_children("*", "MeshInstance3D", true, false):
			var m := n as MeshInstance3D
			if _group_matches(m, keep) or (p == self and m.get_parent() != p and _under_other(m, parents, p)):
				continue
			olds.append(m)
			var xf: Transform3D = _rel(m) if p == self else _rel_to(m, p)
			var g: Dictionary = groups.get(m.cast_shadow, {})
			groups[m.cast_shadow] = g
			for i: int in m.mesh.get_surface_count():
				var mat: Material = m.get_surface_override_material(i)
				if mat == null:
					mat = m.mesh.surface_get_material(i)
				if not g.has(mat):
					g[mat] = SurfaceTool.new()
				(g[mat] as SurfaceTool).append_from(m.mesh, i, xf)
		for m: MeshInstance3D in olds:
			m.get_parent().remove_child(m)
			m.free()
		for cs: int in groups:
			var am := ArrayMesh.new()
			for mat: Material in groups[cs]:
				(groups[cs][mat] as SurfaceTool).commit(am)
				am.surface_set_material(am.get_surface_count() - 1, mat)
			var mi := MeshInstance3D.new()
			mi.name = "Merged"
			mi.mesh = am
			mi.layers = 2
			mi.cast_shadow = cs as GeometryInstance3D.ShadowCastingSetting
			p.add_child(mi)
			if cs != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and Settings.shadow_quality < 3:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # Low/Medium: a coarse proxy casts instead of ~200k tris
				if p != self:
					continue  # wheels/calipers: no shadow on Low/Medium (keeps the car at <= 12 nodes)
				var px := MeshInstance3D.new()
				px.name = "ShadowProxy"
				px.mesh = _proxy_mesh(am)
				px.layers = 2
				px.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				p.add_child(px)


## Vertex-clustered copy of the opaque surfaces (PROXY_CELL grid), for the shadow pass only.
func _proxy_mesh(src: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	var ids := {}
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for si: int in src.get_surface_count():
		var mat := src.surface_get_material(si) as BaseMaterial3D
		if mat != null and mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		var a: Array = src.surface_get_arrays(si)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var ix: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(v.size()))
		var map := PackedInt32Array()
		map.resize(v.size())
		for k: int in v.size():
			var key := Vector3i((v[k] / PROXY_CELL).floor())
			if not ids.has(key):
				ids[key] = verts.size()
				verts.append(v[k])
			map[k] = ids[key]
		for t: int in range(0, ix.size() - 2, 3):
			var i0: int = map[ix[t]]
			var i1: int = map[ix[t + 1]]
			var i2: int = map[ix[t + 2]]
			if i0 != i1 and i1 != i2 and i0 != i2:
				idx.append_array([i0, i1, i2])
	if idx.is_empty():
		return out
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return out


## Pose of m relative to ancestor `to`.
func _rel_to(m: Node3D, to: Node) -> Transform3D:
	var xf: Transform3D = m.transform
	var p: Node = m.get_parent()
	while p != to:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


## True if m sits under one of the other merge parents (wheels, wing...) rather than directly in the model.
func _under_other(m: Node, parents: Array[Node], self_p: Node) -> bool:
	var n: Node = m.get_parent()
	while n != self_p and n != null:
		if parents.has(n):
			return true
		n = n.get_parent()
	return false


## Rear wing meshes -> an ActiveAero (wing_match tilts/rises, strut_match only rises) so the existing aero logic animates them.
func _build_aero(meshes: Array[MeshInstance3D]) -> void:
	var struts_m: Array[MeshInstance3D] = _matching(meshes, def.get("strut_match", []))
	var wing_m: Array[MeshInstance3D] = []
	for m: MeshInstance3D in _matching(meshes, def["wing_match"]):
		if not struts_m.has(m):
			wing_m.append(m)
	if wing_m.is_empty():
		return
	var hinge: Vector3 = _bounds(wing_m).get_center()
	var aero := Node3D.new()
	aero.name = "Aero"
	aero.set_script(load("res://cars/active_aero.gd"))
	var pivot := Node3D.new()
	pivot.name = "WingPivot"
	var struts := Node3D.new()
	struts.name = "Struts"
	for n: Node3D in [pivot, struts]:
		aero.add_child(n)
		_move(wing_m if n == pivot else struts_m, n, hinge)
	for fl: String in ["FlapL", "FlapR"]:  # the model has no flaps; ActiveAero expects the nodes
		var f := Node3D.new()
		f.name = fl
		aero.add_child(f)
	add_child(aero)


## Reparent keeping the car-space pose; parent sits at hub (w is not in the tree yet, so no reparent()).
func _move(list: Array, to: Node3D, hub: Vector3) -> void:
	for m: MeshInstance3D in list:
		var xf: Transform3D = Transform3D(Basis.IDENTITY, -hub) * _rel(m)
		m.get_parent().remove_child(m)
		to.add_child(m)
		m.transform = xf
	to.position = hub


func _process(_dt: float) -> void:
	for i: int in 4:  # calipers ride with the hub but do not spin
		_calipers[i].position = _wheels[i].position
		_calipers[i].rotation.y = _wheels[i].steering


## 0 FL, 1 FR, 2 RL, 3 RR (origin is the wheelbase midpoint, front is -Z).
func _corner(m: MeshInstance3D) -> int:
	var c: Vector3 = _car_bb(m).get_center()
	return (0 if c.z < 0.0 else 2) + (0 if c.x < 0.0 else 1)


## Pose relative to the car (Body sits at the car origin); no global_transform, we are still entering the tree.
func _rel(n: Node3D) -> Transform3D:
	var xf: Transform3D = n.transform
	var p: Node = n.get_parent()
	while p is Node3D and p != self:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


func _car_bb(m: MeshInstance3D) -> AABB:
	return _rel(m) * m.get_aabb()


func _bounds(list: Array) -> AABB:
	var r := AABB()
	for i: int in list.size():
		var b: AABB = _car_bb(list[i] as MeshInstance3D)
		r = b if i == 0 else r.merge(b)
	return r


func _matching(meshes: Array[MeshInstance3D], keys: Array) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for m: MeshInstance3D in meshes:
		if _group_matches(m, keys):
			out.append(m)
	return out


func _group_matches(m: Node, keys: Array) -> bool:
	var n: Node = m
	while n != null and n != self:
		for k: String in keys:
			if String(n.name).contains(k):
				return true
		n = n.get_parent()
	return false


func _setup_lights() -> void:
	_head = _glow(Color(0.96, 0.98, 1.0), 1.6)
	_tail = _glow(Color(1.0, 0.04, 0.02), 0.45)
	var head := _head
	var tail := _tail
	var lights := _car.get_node("Lights") as CarLights
	lights.head_mat = head
	lights.tail_mat = tail
	lights.rev_mat = _glow(Color(1.0, 1.0, 1.0), 0.0)
	lights.spot_pos = _v3(def["head_lamp"])
	lights.trail_anchor = _v3(def["tail_lamp"])
	lights.tail_pos = Vector3(0.0, _v3(def["tail_lamp"]).y, _v3(def["tail_lamp"]).z + 0.1)


func _materials(model: Node) -> void:
	var head := _head
	var tail := _tail
	var cache := _mat_cache
	for mi: Node in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.layers = 2  # car renders into main camera, excluded from its own ReflectionProbe cubemap
		var is_head: bool = _group_matches(m, def["head_match"])
		var is_tail: bool = _group_matches(m, def["tail_match"])
		var hidden_inside: bool = def.has("no_shadow_mats")  # interior parts sit inside the shell; casting sun shadows only costs draw calls
		for i: int in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				hidden_inside = false
				continue
			var nm: String = src.resource_name
			if not _name_in(nm, def.get("no_shadow_mats", [])):
				hidden_inside = false
			if (is_head or is_tail) and _name_in(nm, def.get("light_mats", ["Light_Max", "LightGlass_Red"])):
				m.set_surface_override_material(i, head if is_head else tail)
			elif _name_in(nm, def.get("glass_mats", ["Glass_Window"])) and not nm.contains("Surround"):
				if not cache.has(nm):
					cache[nm] = _make_glass()
					_glass.append(cache[nm])
				m.set_surface_override_material(i, cache[nm])
			else:
				if not cache.has(nm):
					cache[nm] = _paint(src) if _name_in(nm, def["paint_match"]) else _fix(src, nm)
				if cache[nm] != null:
					m.set_surface_override_material(i, cache[nm])
		if hidden_inside:
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Meshes whose group name matches keys, detached from the model with car-space transforms (for the cockpit to adopt).
func take_meshes(keys: Array) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n: Node in find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if _group_matches(m, keys):
			out.append(m)
	for m: MeshInstance3D in out:
		var xf: Transform3D = _rel(m)
		m.get_parent().remove_child(m)
		m.transform = xf
	return out


## Cockpit view: windows nearly clear (from outside they stay tinted).
func set_cockpit(on: bool) -> void:
	for g: StandardMaterial3D in _glass:
		g.albedo_color.a = 0.07 if on else 0.32


func _name_in(nm: String, keys: Array) -> bool:
	for k: String in keys:
		if nm.contains(k):
			return true
	return false


## Cars whose import gave flat/emissive materials (FBX) list per-material PBR fixes in def["mats"] (rough, metal, nm, occ in tex_dir).
func _fix(src: BaseMaterial3D, nm: String) -> StandardMaterial3D:
	var o: Dictionary = def.get("mats", {}).get(nm, def.get("mats_default", {}))
	if o.is_empty() or o.get("skip", false):
		return null
	var m := src.duplicate() as StandardMaterial3D
	m.emission_enabled = bool(o.get("emit", false))
	if o.get("opaque", false):
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	m.roughness = float(o.get("rough", 0.6))
	m.metallic = float(o.get("metal", 0.0))
	m.albedo_color = Color(1.0, 1.0, 1.0) * float(o.get("tint", 1.0))
	m.albedo_color.a = 1.0
	if o.has("weave_m"):  # the weave tile ignores the model's UV islands: object-space triplanar at a real-world pitch
		m.uv1_triplanar = true
		m.uv1_scale = Vector3.ONE * _scale / float(o["weave_m"])
	if o.has("nm") and ResourceLoader.exists(str(def["tex_dir"]) + str(o["nm"]) + ".png"):
		m.normal_enabled = true
		m.normal_texture = load(str(def["tex_dir"]) + str(o["nm"]) + ".png") as Texture2D
	if o.has("occ") and ResourceLoader.exists(str(def["tex_dir"]) + str(o["occ"]) + ".png"):
		m.ao_enabled = true
		m.ao_texture = load(str(def["tex_dir"]) + str(o["occ"]) + ".png") as Texture2D
		m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	return m


func _paint(src: BaseMaterial3D) -> StandardMaterial3D:
	var m := src.duplicate() as StandardMaterial3D
	if def.has("paint_color") and src.albedo_texture == null and not src.resource_name.contains("Black"):
		m.albedo_color = Color(float(def["paint_color"][0]), float(def["paint_color"][1]), float(def["paint_color"][2]))
	m.emission_enabled = false
	m.metallic = 0.55
	m.metallic_specular = 0.7
	m.roughness = 0.28
	m.clearcoat_enabled = true
	m.clearcoat = 1.0
	m.clearcoat_roughness = 0.04
	return m


static func _make_glass() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.03, 0.045, 0.06, 0.32)
	m.metallic_specular = 1.0
	m.roughness = 0.03
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _glow(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col * 0.5
	m.roughness = 0.3
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


static func _v3(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## Apply the def's real-world numbers to the Car controller (P1 values scaled by mass).
func _tune() -> void:
	var mass: float = float(def["mass"])
	_car.mass = mass
	_car.max_power = float(def["power_ps"]) * 735.5 * 0.9
	_car.max_force = mass * 9.81 * 0.95
	_car.brake_front = mass * 3.83
	_car.brake_rear = mass * 2.55
	_car.handbrake_force = mass * 4.1
	_car.limiter_kmh = float(def["top_speed_kmh"])
	var tops := PackedFloat32Array()
	for g: Variant in def["gear_tops"]:
		tops.append(float(g))
	_car.gear_tops = tops
	_car.hood_cam = _v3(def["hood_cam"])
	_car.cockpit_cam = _v3(def["cockpit_cam"])
	if str(def.get("drivetrain", "RWD")) == "AWD":
		_car.get_node("WheelFL").use_as_traction = true
		_car.get_node("WheelFR").use_as_traction = true
	var shape := _car.get_node("CollisionShape3D") as CollisionShape3D
	(shape.shape as BoxShape3D).size = Vector3(float(def["width"]) - 0.06, 0.62, float(def["length"]) - 0.3)
	shape.position = Vector3(0.0, 0.52, 0.0)
