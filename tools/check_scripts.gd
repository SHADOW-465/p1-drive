extends SceneTree
## Gate 1: loads every script/scene/shader under res:// so everything compiles,
## then runs the self-checks. Exit code 1 on any failure.

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var bad: int = _scan("res://")
	bad += _self_checks()
	print("CHECK %s" % ("PASS" if bad == 0 else "FAIL (%d)" % bad))
	quit(1 if bad > 0 else 0)
	return true


func _scan(dir: String) -> int:
	var bad: int = 0
	for d: String in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			bad += _scan(dir.path_join(d))
	for f: String in DirAccess.get_files_at(dir):
		if f.get_extension() in ["gd", "tscn", "gdshader", "tres"]:
			var path: String = dir.path_join(f)
			if path == "res://tools/check_scripts.gd":
				continue
			if load(path) == null:
				print("CHECK FAIL load: ", path)
				bad += 1
	return bad


## Each entry: script path with a static self_check() -> String ("" = ok).
func _self_checks() -> int:
	var bad: int = 0
	for path: String in ["res://world/terrain_fn.gd"]:
		var msg: String = (load(path) as GDScript).call("self_check")
		if msg != "":
			print("CHECK FAIL %s: %s" % [path, msg])
			bad += 1
	return bad
