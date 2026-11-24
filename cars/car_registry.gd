class_name CarRegistry
extends RefCounted
## Car list from data/cars.json. A new GLB car = one more entry (see mclaren_600lt); Car scenes read their def via meta "car_id".

const PATH: String = "res://data/cars.json"
const P1_MODEL: String = "mclaren_p1_vecarz"
static var _data: Dictionary = {}


static func _load() -> void:
	if _data.is_empty():
		_data = JSON.parse_string(FileAccess.get_file_as_string(PATH)) as Dictionary


static func all() -> Array:
	_load()
	return _data["cars"]


static func get_def(id: String) -> Dictionary:
	for d: Dictionary in all():
		if d["id"] == id:
			return d
	return {}


## A car is available when its scene (and GLB, if any) exists; assets_nc is git-ignored so a fresh clone lacks it.
static func is_available(id: String) -> bool:
	var d: Dictionary = get_def(id)
	return not d.is_empty() and ResourceLoader.exists(str(d["scene"])) and (not d.has("glb") or ResourceLoader.exists(str(d["glb"])))


## "p1" is the code-built fallback; saved settings that still say "p1" get the real model when its asset exists.
static func resolve(id: String) -> String:
	if id == "p1" and is_available(P1_MODEL):
		return P1_MODEL
	if is_available(id):
		return id
	return str(_data["default"]) if is_available(str(_data["default"])) else "p1"  # code-built P1 needs no assets


static func available_ids() -> PackedStringArray:
	var r := PackedStringArray()
	for d: Dictionary in all():
		if is_available(str(d["id"])) and resolve(str(d["id"])) == str(d["id"]):  # the code-built P1 is hidden while the real one exists
			r.append(str(d["id"]))
	return r


## Unparented Car for id (falls back to the default car). Caller adds it to the tree.
static func instantiate(id: String) -> Car:
	id = resolve(id)
	var car := (load(str(get_def(id)["scene"])) as PackedScene).instantiate() as Car
	car.set_meta("car_id", id)
	return car
