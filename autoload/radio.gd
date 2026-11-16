extends Node
## Local music radio (T30 / PLAN §10): scans Settings.music_dir for .mp3/.ogg,
## loads bytes on a worker thread, auto-advances, N/B/M keys. Graceful when empty/missing.

signal track_changed(text: String)

var tracks: PackedStringArray = []
var current_idx: int = -1
var playing: bool = true

var _player: AudioStreamPlayer
var _audible: bool = DisplayServer.get_name() != "headless"
var _dir_loaded: String = ""
var _mutex: Mutex = Mutex.new()
var _task_id: int = -1
var _load_seq: int = 0
var _loaded: Dictionary = {}  # {seq, idx, ext, bytes}


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = &"Music"
	_player.finished.connect(_on_finished)
	add_child(_player)
	Settings.settings_changed.connect(_check_dir)
	rescan()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("radio_next"):
		next_track()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("radio_prev"):
		prev_track()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("radio_toggle"):
		toggle_play()
		get_viewport().set_input_as_handled()


func _check_dir() -> void:
	if Settings.music_dir != _dir_loaded:
		rescan()


func rescan() -> void:
	_dir_loaded = Settings.music_dir
	tracks = PackedStringArray()
	current_idx = -1
	if _dir_loaded != "" and DirAccess.dir_exists_absolute(_dir_loaded):
		var files: PackedStringArray = DirAccess.get_files_at(_dir_loaded)
		files.sort()
		for fn: String in files:
			var ext: String = fn.get_extension().to_lower()
			if ext == "mp3" or ext == "ogg":
				tracks.append(_dir_loaded.path_join(fn))
	if not tracks.is_empty():
		current_idx = 0
		if playing:
			_start_load(current_idx)
	track_changed.emit(status_text())


func status_text() -> String:
	if tracks.is_empty():
		return "No music"
	var title: String = tracks[clampi(current_idx, 0, tracks.size() - 1)].get_file().get_basename()
	return title if playing else "Paused (%s)" % title


func next_track() -> void:
	if tracks.is_empty():
		track_changed.emit(status_text())
		return
	current_idx = (current_idx + 1) % tracks.size()
	playing = true
	_start_load(current_idx)
	track_changed.emit(status_text())


func prev_track() -> void:
	if tracks.is_empty():
		track_changed.emit(status_text())
		return
	current_idx = (current_idx - 1 + tracks.size()) % tracks.size()
	playing = true
	_start_load(current_idx)
	track_changed.emit(status_text())


func toggle_play() -> void:
	if tracks.is_empty():
		track_changed.emit(status_text())
		return
	playing = not playing
	if playing:
		if _player.stream == null:
			_start_load(current_idx)
		elif _audible:
			_player.stream_paused = false
			if not _player.playing:
				_player.play()
	else:
		_player.stream_paused = true
	track_changed.emit(status_text())


func _on_finished() -> void:
	if playing and not tracks.is_empty():
		next_track()


func _start_load(idx: int) -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	_load_seq += 1
	var seq: int = _load_seq
	var path: String = tracks[idx]
	_task_id = WorkerThreadPool.add_task(_read_worker.bind(seq, idx, path))


func _read_worker(seq: int, idx: int, path: String) -> void:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
	_mutex.lock()
	_loaded = {"seq": seq, "idx": idx, "ext": path.get_extension().to_lower(), "bytes": bytes}
	_mutex.unlock()


func _process(_dt: float) -> void:
	if _task_id < 0 or not WorkerThreadPool.is_task_completed(_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_mutex.lock()
	var item: Dictionary = _loaded
	_loaded = {}
	_mutex.unlock()
	if item.is_empty() or int(item["seq"]) != _load_seq:
		return
	var bytes: PackedByteArray = item["bytes"]
	if bytes.is_empty():
		return
	var stream: AudioStream = null
	if str(item["ext"]) == "mp3":
		stream = AudioStreamMP3.load_from_buffer(bytes)
	elif str(item["ext"]) == "ogg":
		stream = AudioStreamOggVorbis.load_from_buffer(bytes)
	if stream != null:
		_player.stream = stream
		_player.stream_paused = false
		if playing and _audible:
			_player.play()
		track_changed.emit(status_text())


func _exit_tree() -> void:
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	if _player != null:
		_player.stop()
