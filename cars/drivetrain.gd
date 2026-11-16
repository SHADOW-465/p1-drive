class_name Drivetrain
extends RefCounted
## Gears, rpm, boost, shift cut (PLAN 6.2). Pure logic, no nodes.

const IDLE_RPM: float = 900.0
const REDLINE: float = 8250.0
const UPSHIFT_RPM: float = 8000.0
const DOWNSHIFT_RPM: float = 4200.0
const SHIFT_TIME: float = 0.12

var gear_tops: PackedFloat32Array = PackedFloat32Array([78, 124, 170, 220, 270, 315, 360])  # km/h at redline
var gear: int = 1
var rpm: float = IDLE_RPM
var boost: float = 0.0
var shift_t: float = 0.0
var reverse: bool = false
var blow_off: bool = false  # true for the one update where the throttle was lifted on boost
var _prev_throttle: float = 0.0


func update(dt: float, kmh: float, throttle: float, rev: bool) -> void:
	reverse = rev
	shift_t = maxf(shift_t - dt, 0.0)
	if rev:
		gear = 1
	elif shift_t <= 0.0:
		var r: float = REDLINE * kmh / gear_tops[gear - 1]
		if r >= UPSHIFT_RPM and gear < gear_tops.size():
			gear += 1
			shift_t = SHIFT_TIME
		elif r < DOWNSHIFT_RPM and gear > 1:
			gear -= 1
			shift_t = SHIFT_TIME
	rpm = maxf(IDLE_RPM, REDLINE * kmh / gear_tops[gear - 1])
	if gear == 1:  # launch slip so first gear does not sound dead
		rpm = maxf(rpm, IDLE_RPM + throttle * 3500.0 * clampf(1.0 - kmh / 40.0, 0.0, 1.0))
	rpm = minf(rpm, REDLINE)
	var target: float = throttle * clampf((rpm - 2500.0) / 3000.0, 0.0, 1.0)
	blow_off = _prev_throttle - throttle > 0.3 and boost > 0.6
	_prev_throttle = throttle
	boost += (target - boost) * (1.0 - exp(-dt / (0.35 if target > boost else 0.15)))


func force_scale() -> float:
	return 0.3 if shift_t > 0.0 else 1.0


func gear_label() -> String:
	return "R" if reverse else str(gear)
