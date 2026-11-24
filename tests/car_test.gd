extends Node
## Gate (cars): boots main.tscn, swaps to every available car via the settings-menu path, drives 4 s each and requires
## wheels on the ground, motion and a spinning/steering wheel hub. Prints CARS PASS / CARS FAIL: <reason>.

var main: Node3D
var ids: PackedStringArray = CarRegistry.available_ids()
var idx: int = -1
var k: int = 0
var booted: bool = false
var car: Car
var min_contact: int = 4
var max_kmh: float = 0.0
var spun: float = 0.0
var last_rot: float = 0.0
var aero: ActiveAero
var max_wing_h: float = 0.0
var max_wing_a: float = 0.0
var cal_spin: float = 0.0


func _ready() -> void:
	main = (load("res://main.tscn") as PackedScene).instantiate() as Node3D
	add_child(main)
	car = main.get_node("P1") as Car


func _physics_process(_dt: float) -> void:
	if not booted:
		booted = not car.freeze
		return
	if k == 0:
		idx += 1
		if idx >= ids.size():
			for need: String in ["koenigsegg_gemera", "bentley_exp10_speed6"]:  # assets_nc is git-ignored: enforced only where the files exist
				if ResourceLoader.exists(str(CarRegistry.get_def(need)["glb"])) and not ids.has(need):
					_finish("%s has assets but is not in the car picker" % need)
					return
			var dflt: String = str(CarRegistry.get_def(str(CarRegistry._data["default"])).get("id", ""))
			if ids.has(dflt) and CarRegistry.resolve("no_such_car") != dflt:
				_finish("fallback for an unknown id is not the default car")
				return
			_finish("")
			return
		main.call("_swap_car", ids[idx])
		car = main.get_node("P1") as Car
		if str(car.get_meta("car_id")) != ids[idx]:
			_finish("swap to %s gave %s" % [ids[idx], car.get_meta("car_id")])
			return
		min_contact = 4
		max_kmh = 0.0
		spun = 0.0
		max_wing_h = 0.0
		max_wing_a = 0.0
		cal_spin = 0.0
		aero = car.find_child("Aero", true, false) as ActiveAero
	k += 1
	if k == 90:
		Input.action_press("throttle")
	if k > 150:
		min_contact = mini(min_contact, car.wheels_in_contact())
		max_kmh = maxf(max_kmh, car.speed_kmh)
		var w: Node3D = car.get_node("WheelFL")
		spun += absf(wrapf(w.rotation.x - last_rot, -PI, PI))
		last_rot = w.rotation.x
		if aero != null:
			max_wing_h = maxf(max_wing_h, aero.wing_height)
			var cal: Node3D = car.find_child("CaliperFL", true, false)
			cal_spin += absf(cal.rotation.x)  # calipers follow the hub but must not roll
	if k == 480 and aero != null:  # active wing: stand on the brakes, the wing must tilt up as an airbrake
		Input.action_release("throttle")
		Input.action_press("brake")
	if aero != null and k > 480:
		max_wing_a = maxf(max_wing_a, aero.wing_angle_deg)
	if k == 480 and aero != null:
		return
	if k == 550 or (k == 330 and aero == null):
		Input.action_release("brake")
		Input.action_release("throttle")
		print("wing %s: %.0f km/h, max rise %.2f m, airbrake %.0f deg, caliper roll %.3f" % [ids[idx], max_kmh, max_wing_h, max_wing_a, cal_spin])
		if aero != null and (max_wing_h < 0.15 or max_wing_a < 40.0 or cal_spin > 0.01):
			_finish("%s: wing rise %.2f, airbrake %.0f deg, caliper roll %.3f" % [ids[idx], max_wing_h, max_wing_a, cal_spin])
			return
		print("car %s: max %.1f km/h, min contact %d, spin %.1f rad" % [ids[idx], max_kmh, min_contact, spun])
		if max_kmh < 50.0 or min_contact < 3 or spun < 5.0:
			_finish("%s: max %.1f km/h, min contact %d, spin %.1f" % [ids[idx], max_kmh, min_contact, spun])
			return
		k = 0


func _finish(fail: String) -> void:
	set_physics_process(false)
	Input.action_release("throttle")
	print("CARS PASS (%s)" % ",".join(ids) if fail == "" else "CARS FAIL: " + fail)
	main.call("quit_game")
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(0 if fail == "" else 1)
