class_name EngineAudio
extends Node
## Drives the baked loops from the drivetrain (PLAN 6.5): two crossfaded engine layers,
## turbo whistle, blow-off, wind.

var _low: AudioStreamPlayer
var _high: AudioStreamPlayer
var _whistle: AudioStreamPlayer
var _blow: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _rpm: float = 900.0
var _thr: float = 0.0
# the dummy audio driver never releases playbacks (leak report at exit), so stay silent headless
var _audible: bool = DisplayServer.get_name() != "headless"
@onready var car: Car = get_parent() as Car


func _ready() -> void:
	var t0: int = Time.get_ticks_msec()
	# V8 firing frequency f = rpm / 15; partials at f/4 .. 4f, integer Hz so the loops are seamless
	_low = _player(AudioBake.tones("eng_low", [33, 66, 132, 198, 264, 396, 528], [0.3, 0.5, 1.0, 0.45, 0.5, 0.25, 0.15], 1.5))
	_high = _player(AudioBake.tones("eng_high", [100, 200, 400, 600, 800, 1200, 1600, 2400], [0.15, 0.25, 0.8, 0.3, 0.7, 0.5, 0.35, 0.2], 1.8))
	_whistle = _player(AudioBake.noise("whistle", 1.0, 0.9, 3200.0, true))
	_wind = _player(AudioBake.noise("wind", 2.0, 0.08, 0.0, true))
	_blow = _player(AudioBake.noise("blow", 0.35, 0.5, 0.0, false), false)
	if Settings.has_arg("--fps-log"):
		print("audio bake %d ms" % (Time.get_ticks_msec() - t0))


func _player(stream: AudioStream, autoplay: bool = true) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = &"SFX"
	p.volume_linear = 0.0
	add_child(p)
	if autoplay and _audible:
		p.play()
	return p


func _process(dt: float) -> void:
	var d: Drivetrain = car.drivetrain
	_rpm = lerpf(_rpm, d.rpm, 1.0 - exp(-18.0 * dt))
	_thr = lerpf(_thr, maxf(car.in_throttle, car.in_brake if car.reversing else 0.0), 1.0 - exp(-12.0 * dt))
	var x: float = smoothstep(3000.0, 5500.0, _rpm)
	var gain: float = lerpf(0.4, 0.63, _thr)  # +4 dB on throttle
	_low.pitch_scale = _rpm / 2000.0
	_high.pitch_scale = _rpm / 6000.0
	_low.volume_linear = gain * cos(x * PI * 0.5)
	_high.volume_linear = gain * sin(x * PI * 0.5)
	_whistle.pitch_scale = 0.7 + 0.6 * d.boost
	_whistle.volume_linear = 0.22 * d.boost * d.boost
	_wind.volume_linear = 0.5 * minf(car.speed_kmh / 330.0, 1.0) ** 2
	_wind.pitch_scale = 0.8 + car.speed_kmh / 600.0
	if d.blow_off and _audible:
		_blow.volume_linear = 0.5
		_blow.play()


func _exit_tree() -> void:  # playing players leak their playbacks at quit otherwise
	for p: AudioStreamPlayer in [_low, _high, _whistle, _blow, _wind]:
		p.stop()
