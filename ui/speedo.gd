class_name Speedo
extends Control
## H1: Forza Horizon 5 style speedometer. The ring (arcs, ticks, needle, glows) is one analytic
## shader quad; text lives in two Control layers that only redraw when a value changes.
## Design units are 720p pixels; set_ui_scale() multiplies everything, so text stays crisp.

const F_NUM: Font = preload("res://assets/fonts/BarlowSemiCondensed-Bold.ttf")
const F_TXT: Font = preload("res://assets/fonts/BarlowSemiCondensed-SemiBold.ttf")
const BOX: float = 252.0
const RING_R: float = 104.0
const RPM_MAX: float = 9000.0
const SHIFT_RPM: float = 7800.0
const SPEED_HZ: float = 15.0
const GEAR_C: Vector2 = Vector2(0.0, 76.0)
const STATUS: PackedStringArray = ["ABS", "TCR", "DRS", "AIRBRAKE"]

var car: Car
var u: float = 1.0

var _ring: ColorRect
var _mat: ShaderMaterial
var _static: _Static
var _needle: float = 0.0  # fraction of RPM_MAX
var _needle_v: float = 0.0
var _speed_acc: float = 1.0
var _speed_target: float = 0.0
var _speed_shown: float = 0.0
var _text: String = "000"
var _prev_text: String = "000"
var _roll: PackedFloat32Array = PackedFloat32Array([1.0, 1.0, 1.0])
var _gear: String = "N"
var _gear_pop: float = 1.0
var _flash_t: float = 0.0
var _status: Array[bool] = [false, false, false, false]
var _ers_on: bool = false
var _dirty: bool = true
var _car_seen: Car = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://shaders/speedo_ring.gdshader")
	_ring = ColorRect.new()
	_ring.material = _mat
	_ring.show_behind_parent = true
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ring)
	_static = _Static.new()
	_static.show_behind_parent = true
	_static.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_static)
	set_ui_scale(u)


func set_ui_scale(s: float) -> void:
	u = s
	custom_minimum_size = Vector2(BOX, BOX) * u
	size = custom_minimum_size
	if _ring == null:
		return
	_ring.size = size
	_static.size = size
	_static.u = u
	_static.queue_redraw()
	_mat.set_shader_parameter("aa", 0.8 / u)
	_dirty = true


func set_car(c: Car) -> void:
	car = c


func _process(dt: float) -> void:
	if car == null or not visible:
		return
	if car != _car_seen:
		_car_seen = car
		_ers_on = car.find_child("Aero", true, false) != null
		_mat.set_shader_parameter("ers_on", 1.0 if _ers_on else 0.0)
	var dtr: Drivetrain = car.drivetrain
	# needle: underdamped spring, settles with a slight overshoot
	var target: float = clampf(dtr.rpm / RPM_MAX, 0.0, 1.0)
	var h: float = minf(dt, 0.05)
	_needle_v += ((target - _needle) * 620.0 - _needle_v * 24.0) * h
	_needle = clampf(_needle + _needle_v * h, 0.0, 1.0)
	_mat.set_shader_parameter("rpm_t", _needle)
	_mat.set_shader_parameter("ers", dtr.boost)
	# shift light
	var fl: float = 0.0
	if dtr.rpm >= SHIFT_RPM:
		_flash_t += dt
		fl = 0.5 + 0.5 * sin(_flash_t * 38.0)
	else:
		_flash_t = 0.0
	_mat.set_shader_parameter("flash", fl)
	# speed readout: eased value, sampled at ~15 Hz so digits do not flicker
	_speed_acc += dt
	if _speed_acc >= 1.0 / SPEED_HZ:
		_speed_acc = 0.0
		_speed_target = car.speed_kmh
	_speed_shown = lerpf(_speed_shown, _speed_target, 1.0 - exp(-22.0 * dt))
	var txt: String = "%03d" % clampi(roundi(_speed_shown), 0, 999)
	if txt != _text:
		_prev_text = _text
		for i: int in 3:
			if txt[i] != _text[i]:
				_roll[i] = 0.0
		_text = txt
		_dirty = true
	for i: int in 3:
		if _roll[i] < 1.0:
			_roll[i] = minf(_roll[i] + dt / 0.09, 1.0)
			_dirty = true
	var g: String = dtr.gear_label()
	if g != _gear:
		_gear = g
		_gear_pop = 0.0
	if _gear_pop < 1.0:
		_gear_pop = minf(_gear_pop + dt / 0.32, 1.0)
		_dirty = true
	var aero: ActiveAero = car.find_child("Aero", true, false) as ActiveAero
	var an: String = aero.state_name() if aero != null else ""
	var st: Array[bool] = [
		car.brake_now > 0.8 and car.speed_kmh > 30.0,
		car._tc < 0.99,
		an == "DRS",
		an == "AIRBRAKE",
	]
	if st != _status:
		_status = st
		_dirty = true
	if _dirty:
		_dirty = false
		queue_redraw()


func _draw() -> void:
	var c: Vector2 = Vector2(BOX, BOX) * 0.5 * u
	var white := Color(1.0, 1.0, 1.0, 0.98)
	# speed digits with roll
	var sz: int = roundi(64.0 * u)
	var cell: float = 33.0 * u
	var x0: float = c.x - cell * 1.5
	# Draw box wider than the cell: the digit 4 is ~35 px at this size and Godot drops text wider than its box.
	var dw: float = cell * 1.3
	var dpad: float = (dw - cell) * 0.5
	var lead: bool = true
	for i: int in 3:
		var ch: String = _text[i]
		var is_lead: bool = lead and ch == "0" and i < 2
		if ch != "0":
			lead = false
		var a_new: float = 0.2 if is_lead else 1.0
		var r: float = _roll[i]
		var e: float = 1.0 - pow(1.0 - r, 3.0)
		var base_y: float = c.y - 7.0 * u + 0.35 * sz
		if r < 1.0:  # only the new digit slides in: never overlay old+new (that read as a mash like "1765")
			_text_at(F_NUM, ch, Vector2(x0 + cell * i - dpad, base_y + (1.0 - e) * 6.0 * u), dw, sz, Color(1, 1, 1, a_new * (0.6 + 0.4 * e)))
		else:
			_text_at(F_NUM, ch, Vector2(x0 + cell * i - dpad, base_y), dw, sz, Color(1, 1, 1, a_new))
	# gear in its circle (pop on change)
	var gc: Vector2 = c + GEAR_C * u
	var pop: float = sin(_gear_pop * PI) * (1.0 - _gear_pop * 0.4)
	var gs: int = roundi(24.0 * u * (1.0 + 0.5 * pop))
	_text_at(F_NUM, _gear, Vector2(gc.x - 20.0 * u, gc.y + 0.35 * gs), 40.0 * u, gs, white)
	if _gear_pop < 1.0:
		var k: float = 1.0 - _gear_pop
		draw_arc(gc, (16.0 + 7.0 * _gear_pop) * u, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.7 * k), 1.6 * u, true)
		draw_arc(gc, 16.0 * u, 0.0, TAU, 40, Color(1.0, 0.5, 0.65, 0.5 * k), 3.0 * u, true)
	# lit status labels
	var ss: int = roundi(11.0 * u)
	for i: int in 4:
		if _status[i]:
			var col: Color = Color(1.0, 0.36, 0.45) if i == 0 or i == 3 else (Color(1.0, 0.78, 0.25) if i == 1 else Color(0.35, 0.88, 1.0))
			var p: Vector2 = c + Vector2(_Static.STATUS_X[i], 106.0) * u
			draw_string(F_TXT, p + Vector2(-30.0 * u, 0.35 * ss + 1.0), STATUS[i], HORIZONTAL_ALIGNMENT_CENTER, 60.0 * u, ss, Color(col, 0.35))
			_text_at(F_TXT, STATUS[i], p + Vector2(-30.0 * u, 0.35 * ss), 60.0 * u, ss, col)


## Centered text with a soft drop shadow. pos is the baseline-left of the cell.
static func shadow_text(ci: CanvasItem, font: Font, s: String, pos: Vector2, w: float, size_px: int, col: Color, scale: float) -> void:
	ci.draw_string(font, pos + Vector2(0.0, 2.0 * scale), s, HORIZONTAL_ALIGNMENT_CENTER, w, size_px, Color(0.0, 0.0, 0.0, 0.45 * col.a))
	ci.draw_string(font, pos + Vector2(0.0, 0.8 * scale), s, HORIZONTAL_ALIGNMENT_CENTER, w, size_px, Color(0.0, 0.0, 0.0, 0.25 * col.a))
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_CENTER, w, size_px, col)


func _text_at(font: Font, s: String, pos: Vector2, w: float, size_px: int, col: Color) -> void:
	shadow_text(self, font, s, pos, w, size_px, col, u)


class _Static extends Control:
	const STATUS_X: Array[float] = [-66.0, -30.0, 8.0, 54.0]
	var u: float = 1.0

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var ns: int = roundi(13.0 * u)
		for i: int in 10:
			var a: float = deg_to_rad(-135.0 + 30.0 * i)
			var p: Vector2 = c + Vector2(sin(a), -cos(a)) * 80.0 * u
			var col := Color(1.0, 0.45, 0.55, 0.95) if i >= 8 else Color(1.0, 1.0, 1.0, 0.88)
			Speedo.shadow_text(self, Speedo.F_TXT, str(i), p + Vector2(-10.0 * u, 0.35 * ns), 20.0 * u, ns, col, u)
		var us: int = roundi(12.0 * u)
		Speedo.shadow_text(self, Speedo.F_TXT, "KM/H", c + Vector2(-30.0 * u, 29.0 * u + 0.35 * us), 60.0 * u, us, Color(1, 1, 1, 0.78), u)
		# gear circle
		var gc: Vector2 = c + Speedo.GEAR_C * u
		draw_circle(gc, 17.0 * u, Color(0.0, 0.0, 0.0, 0.34))
		draw_arc(gc, 16.0 * u, 0.0, TAU, 40, Color(1.0, 1.0, 1.0, 0.75), 1.4 * u, true)
		# dim status labels
		var ss: int = roundi(11.0 * u)
		for i: int in 4:
			Speedo.shadow_text(self, Speedo.F_TXT, Speedo.STATUS[i], c + Vector2(STATUS_X[i] - 30.0, 106.0) * u + Vector2(0.0, 0.35 * ss), 60.0 * u, ss, Color(1, 1, 1, 0.45), u)
