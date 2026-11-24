class_name CarMirror
extends Node3D
## Working mirror: a tiny SubViewport camera looks backwards from cam_pos (car space) and the image is shown,
## flipped, on a quad at the mirror glass. Renders only while the cockpit view is active, every `every` frames,
## and not at all on the Low preset (then the quad is a flat sky-grey).

const SHADER_CODE: String = """shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
uniform sampler2D tex : source_color, filter_linear;
uniform vec3 tint = vec3(0.92, 0.95, 1.0);
void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float vig = 1.0 - 0.22 * dot(q, q);
	ALBEDO = texture(tex, vec2(1.0 - UV.x, UV.y)).rgb * tint * vig;
}
"""
static var _shader: Shader

var every: int = 2
var _car: Car
var _sv: SubViewport
var _cam: Camera3D
var _cam_local: Transform3D
var _n: int = 0
var _on: bool = false


## quad_pos/normal: glass centre and the direction it faces (toward the driver), all in car space.
func setup(car: Car, quad_pos: Vector3, quad_normal: Vector3, size: Vector2, cam_pos: Vector3, cam_yaw_deg: float, res: Vector2i, fov: float, every_n: int) -> void:
	_car = car
	every = every_n
	_cam_local = Transform3D(Basis(Vector3.UP, deg_to_rad(cam_yaw_deg)), cam_pos)
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var qm := QuadMesh.new()
	qm.size = size
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	var mi := MeshInstance3D.new()
	mi.name = "Glass"
	mi.mesh = qm
	mi.material_override = mat
	mi.layers = 2
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(Basis.looking_at(-quad_normal, Vector3.UP), quad_pos)
	add_child(mi)
	if Settings.preset == "low":
		mat.set_shader_parameter("tint", Vector3(0.55, 0.6, 0.65))
		return
	_sv = SubViewport.new()
	_sv.size = res
	_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sv.msaa_3d = Viewport.MSAA_DISABLED
	_sv.positional_shadow_atlas_size = 0
	add_child(_sv)
	_cam = Camera3D.new()
	_cam.fov = fov
	_cam.near = 0.4
	_cam.far = 700.0 if Settings.preset == "high" else 350.0
	_cam.cull_mask = 1  # not the car itself (layer 2)
	_sv.add_child(_cam)
	mat.set_shader_parameter("tex", _sv.get_texture())


func set_active(on: bool) -> void:
	_on = on
	visible = on
	if _sv != null and not on:
		_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _process(_dt: float) -> void:
	if not _on or _sv == null:
		return
	_n += 1
	if _n % every != 0:
		return
	_cam.global_transform = _car.get_global_transform_interpolated() * _cam_local
	_sv.render_target_update_mode = SubViewport.UPDATE_ONCE
