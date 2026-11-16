extends Node
## --fps-log: prints FPS + frame-time max every second.

var tiles_full: int = 0  # set by the tile streamer
var tiles_lod: int = 0
var _t: float = 0.0
var _max_ms: float = 0.0


func _ready() -> void:
	set_process(Settings.has_arg("--fps-log"))


func _process(delta: float) -> void:
	_max_ms = maxf(_max_ms, delta * 1000.0)
	_t += delta
	if _t >= 1.0:
		print("FPS %d max_ms %.1f tiles %d/%d" % [Engine.get_frames_per_second(), _max_ms, tiles_full, tiles_lod])
		_t = 0.0
		_max_ms = 0.0
