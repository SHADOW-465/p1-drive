class_name CarLights
extends Node3D
## Brake/reverse lights, disc heat glow, headlights, tail trail ribbon (PLAN 6.4).
## Expects Head/Tail/Reverse mesh children (from the car's mesh builder) and Wheel*/Disc.

const TAIL_ENERGY: float = 0.45
const BRAKE_ENERGY: float = 5.5
const TRAIL_POINTS: int = 24
const TRAIL_DT: float = 0.035

@export var trail_anchor: Vector3 = Vector3(0.74, 0.62, 2.03)  ## right lamp; mirrored for the left

## Set by a GLB car body before _ready; the P1 uses its Head/Tail/Reverse mesh children instead.
var head_mat: StandardMaterial3D
var tail_mat: StandardMaterial3D
var rev_mat: StandardMaterial3D
var spot_pos: Vector3 = Vector3(0.68, 0.56, -2.18)
var tail_pos: Vector3 = Vector3(0.0, 0.58, 2.22)

var headlights: bool = false
var auto_headlights: bool = true  # follow DayNight.night_factor
var heat: float = 0.0
var brake_energy: float = 0.0

var _tail: StandardMaterial3D
var _rev: StandardMaterial3D
var _head: StandardMaterial3D
var _disc_std: StandardMaterial3D
var _disc_sh: ShaderMaterial
var _spot_l: SpotLight3D
var _spot_r: SpotLight3D
var _tail_light: OmniLight3D
var _trail: MeshInstance3D
var _im: ImmediateMesh = ImmediateMesh.new()
var _pts: Array[PackedVector3Array] = [PackedVector3Array(), PackedVector3Array()]
var _trail_t: float = 0.0
@onready var car: Car = get_parent() as Car


func _make_spot(pos: Vector3, yaw_deg: float) -> SpotLight3D:
	var sp := SpotLight3D.new()
	sp.position = pos
	sp.rotation_degrees = Vector3(-3.5, yaw_deg, 0.0)
	sp.spot_range = 92.0
	sp.spot_angle = 38.0
	sp.spot_attenuation = 0.75
	sp.light_energy = 4.2
	sp.light_color = Color(0.95, 0.97, 1.0)
	sp.visible = false
	add_child(sp)
	return sp


func _ready() -> void:
	_tail = tail_mat if tail_mat != null else ($Tail as MeshInstance3D).material_override as StandardMaterial3D
	_rev = rev_mat if rev_mat != null else ($Reverse as MeshInstance3D).material_override as StandardMaterial3D
	_head = head_mat if head_mat != null else ($Head as MeshInstance3D).material_override as StandardMaterial3D
	var disc := car.get_node_or_null("WheelFL/Disc") as MeshInstance3D
	if disc != null:
		_disc_std = disc.material_override as StandardMaterial3D
		_disc_sh = disc.material_override as ShaderMaterial
	_spot_l = _make_spot(Vector3(-spot_pos.x, spot_pos.y, spot_pos.z), 2.5)
	_spot_r = _make_spot(spot_pos, -2.5)
	_tail_light = OmniLight3D.new()
	_tail_light.position = tail_pos
	_tail_light.omni_range = 5.0
	_tail_light.omni_attenuation = 1.4
	_tail_light.light_color = Color(1.0, 0.08, 0.03)
	_tail_light.light_energy = 0.0
	_tail_light.visible = false
	add_child(_tail_light)
	_trail = MeshInstance3D.new()
	_trail.top_level = true
	_trail.layers = 2
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
		headlights = night > 0.45
	elif not Settings.auto_headlights:
		headlights = false
	brake_energy = BRAKE_ENERGY if car.brake_now > 0.05 else TAIL_ENERGY * (1.2 if headlights else 0.3)
	_tail.emission_energy_multiplier = brake_energy
	_rev.emission_energy_multiplier = 3.2 if car.reversing else 0.0
	_head.emission_energy_multiplier = 4.8 if headlights else 1.2
	var is_low: bool = Settings.preset == "low"
	_spot_l.position.x = 0.0 if is_low else -spot_pos.x
	_spot_l.light_energy = 5.4 if is_low else 4.2
	_spot_l.visible = headlights
	_spot_r.visible = headlights and not is_low
	_tail_light.visible = (not is_low) and (headlights or car.brake_now > 0.05)
	_tail_light.light_energy = clampf(brake_energy * 0.24, 0.0, 1.4)
	heat += car.brake_now * (car.speed_kmh / 3.6 / 90.0) * 0.95 * dt
	heat = clampf(heat - heat * 0.35 * dt, 0.0, 1.0)
	if _disc_sh != null:
		_disc_sh.set_shader_parameter("heat", heat)
	elif _disc_std != null:
		_disc_std.emission_energy_multiplier = heat * heat * 5.0


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
