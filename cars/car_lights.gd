class_name CarLights
extends Node3D
## Brake/reverse lights, disc heat glow, headlights, tail trail ribbon (PLAN 6.4).
## Expects Head/Tail/Reverse mesh children (from the car's mesh builder) and Wheel*/Disc.

const TAIL_ENERGY: float = 0.4
const BRAKE_ENERGY: float = 4.0
const TRAIL_POINTS: int = 24
const TRAIL_DT: float = 0.035

@export var trail_anchor: Vector3 = Vector3(0.74, 0.62, 2.03)  ## right lamp; mirrored for the left

var headlights: bool = false
var auto_headlights: bool = true  # follow DayNight.night_factor
var heat: float = 0.0
var brake_energy: float = 0.0

var _tail: StandardMaterial3D
var _rev: StandardMaterial3D
var _head: StandardMaterial3D
var _disc: StandardMaterial3D
var _spot: SpotLight3D
var _trail: MeshInstance3D
var _im: ImmediateMesh = ImmediateMesh.new()
var _pts: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
var _trail_t: float = 0.0
@onready var car: Car = get_parent() as Car


func _ready() -> void:
	_tail = ($Tail as MeshInstance3D).material_override as StandardMaterial3D
	_rev = ($Reverse as MeshInstance3D).material_override as StandardMaterial3D
	_head = ($Head as MeshInstance3D).material_override as StandardMaterial3D
	_disc = (car.get_node("WheelFL/Disc") as MeshInstance3D).material_override as StandardMaterial3D
	_spot = SpotLight3D.new()
	_spot.position = Vector3(0.0, 0.62, -2.1)
	_spot.rotation_degrees.x = -4.0
	_spot.spot_range = 70.0
	_spot.spot_angle = 38.0
	_spot.spot_attenuation = 0.8
	_spot.light_energy = 5.0
	_spot.light_color = Color(1.0, 0.96, 0.88)
	_spot.visible = false
	add_child(_spot)
	_trail = MeshInstance3D.new()
	_trail.top_level = true
	_trail.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.mesh = _im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail.material_override = m
	add_child(_trail)
	_trail.global_transform = Transform3D.IDENTITY


func _physics_process(dt: float) -> void:
	var night: float = DayNight.night_factor
	if Settings.auto_headlights and auto_headlights:
		headlights = night > 0.5
	elif not Settings.auto_headlights:
		headlights = false
	brake_energy = BRAKE_ENERGY if car.brake_now > 0.05 else TAIL_ENERGY * (1.0 if headlights else 0.25)
	_tail.emission_energy_multiplier = brake_energy
	_rev.emission_energy_multiplier = 3.0 if car.reversing else 0.0
	_head.emission_energy_multiplier = 4.0 if headlights else 0.6
	_spot.visible = headlights
	heat += car.brake_now * (car.speed_kmh / 3.6 / 90.0) * 0.9 * dt
	heat = clampf(heat - heat * 0.35 * dt, 0.0, 1.0)
	_disc.emission_energy_multiplier = heat * heat * 5.0


func _process(dt: float) -> void:
	var on: bool = DayNight.night_factor > 0.4 and car.speed_kmh > 60.0
	if not on:
		if _pts[0].size() > 0:
			_pts[0].clear()
			_pts[1].clear()
			_im.clear_surfaces()
		return
	var xf: Transform3D = car.get_global_transform_interpolated()
	_trail_t += dt
	var push: bool = _trail_t >= TRAIL_DT or _pts[0].is_empty()
	if push:
		_trail_t = 0.0
	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for side: int in 2:
		var head: Vector3 = xf * Vector3(trail_anchor.x * (1.0 if side == 0 else -1.0), trail_anchor.y, trail_anchor.z)
		var pts: PackedVector3Array = _pts[side]
		if push:
			pts.insert(0, head)
			if pts.size() > TRAIL_POINTS:
				pts.resize(TRAIL_POINTS)
			_pts[side] = pts
		var prev: Vector3 = head
		for i: int in pts.size():
			var a0: float = 0.5 * (1.0 - float(i) / TRAIL_POINTS)
			var a1: float = 0.5 * (1.0 - float(i + 1) / TRAIL_POINTS)
			var up: Vector3 = Vector3(0.0, 0.025, 0.0)
			var c0: Color = Color(a0, a0 * 0.06, a0 * 0.03)
			var c1: Color = Color(a1, a1 * 0.06, a1 * 0.03)
			for q: Array in [[prev - up, c0], [prev + up, c0], [pts[i] + up, c1], [prev - up, c0], [pts[i] + up, c1], [pts[i] - up, c1]]:
				_im.surface_set_color(q[1])
				_im.surface_add_vertex(q[0])
			prev = pts[i]
	_im.surface_end()


## Floating-origin shift: keep the ribbon attached.
func shift(d: Vector3) -> void:
	for side: int in 2:
		for i: int in _pts[side].size():
			_pts[side][i] -= d
