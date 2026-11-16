class_name ActiveAero
extends Node3D
## Active aero state machine + spring-animated wing/flaps (PLAN 6.3).
## Coefficients follow the animated pose, so physics changes as the wing moves.

enum State { LOW, HIGH, DRS, AIRBRAKE }
const NAMES: PackedStringArray = ["LOW", "HIGH", "DRS", "AIRBRAKE"]
# per state: wing height m, wing angle deg, flap angle deg, k_drag, k_down
const POSE: PackedFloat32Array = [
	0.0, 2.0, 0.0, 0.60, 0.60,
	0.22, 14.0, 10.0, 0.72, 1.50,
	0.22, 0.0, 0.0, 0.48, 0.70,
	0.30, 58.0, 24.0, 1.90, 1.90,
]

@export var has_airbrake: bool = true

var state: State = State.LOW
var wing_height: float = 0.0
var wing_angle_deg: float = 2.0
var flap_deg: float = 0.0
var k_drag: float = 0.6
var k_down: float = 0.6

var _x: PackedFloat32Array = POSE.slice(0, 5)
var _v: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0, 0.0]
var _omega: float = 9.0
var _release_t: float = 0.0
var _wing_y: float = 0.0
@onready var car: Car = get_parent() as Car
@onready var wing_pivot: Node3D = $WingPivot
@onready var flaps: Array[Node3D] = [$FlapL as Node3D, $FlapR as Node3D]


func _ready() -> void:
	_wing_y = wing_pivot.position.y


func _physics_process(dt: float) -> void:
	var kmh: float = car.speed_kmh
	var brake: float = car.brake_now
	var next: State = state
	if state == State.AIRBRAKE:
		_release_t = _release_t + dt if brake < 0.05 else 0.0
		if _release_t > 0.4 or kmh < 50.0:
			next = State.HIGH if kmh >= 80.0 else State.LOW
	elif has_airbrake and brake > 0.6 and kmh > 110.0:
		next = State.AIRBRAKE
	elif state == State.LOW:
		if kmh >= 100.0:
			next = State.HIGH
	elif kmh < 80.0:
		next = State.LOW
	else:
		next = State.DRS if car.in_drs and brake <= 0.0 else State.HIGH
	if next != state:
		_omega = 16.0 if next == State.AIRBRAKE else (5.0 if state == State.AIRBRAKE else 9.0)
		_release_t = 0.0
		state = next

	for i: int in 5:  # critically damped springs
		_v[i] += (_omega * _omega * (POSE[state * 5 + i] - _x[i]) - 2.0 * _omega * _v[i]) * dt
		_x[i] += _v[i] * dt
	wing_height = _x[0]
	wing_angle_deg = _x[1]
	flap_deg = _x[2]
	k_drag = _x[3]
	k_down = _x[4]
	car.k_drag = k_drag
	car.k_down = k_down
	wing_pivot.position.y = _wing_y + wing_height
	wing_pivot.rotation.x = -deg_to_rad(wing_angle_deg)  # trailing edge up
	for f: Node3D in flaps:
		f.rotation.x = deg_to_rad(flap_deg)


func state_name() -> String:
	return NAMES[state]
