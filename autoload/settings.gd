extends Node
## Input map (PLAN §5) registered in code; user settings added in T29.

const KEYS: Dictionary = {
	"throttle": [KEY_W, KEY_UP], "brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT], "steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE], "drs": [KEY_SHIFT], "camera_toggle": [KEY_C],
	"respawn": [KEY_R], "radio_next": [KEY_N], "radio_prev": [KEY_B], "radio_toggle": [KEY_M],
	"time_skip": [KEY_T], "fps_toggle": [KEY_F3], "pause": [KEY_ESCAPE], "companion_toggle": [KEY_P],
}
const PAD_BUTTONS: Dictionary = {
	"handbrake": 0, "drs": 10, "camera_toggle": 3, "respawn": 4, "radio_next": 14,
	"radio_prev": 13, "radio_toggle": 11, "time_skip": 12, "pause": 6,
}
# action -> [axis, sign]
const PAD_AXES: Dictionary = {
	"throttle": [5, 1.0], "brake": [4, 1.0], "steer_left": [0, -1.0], "steer_right": [0, 1.0],
}


func _init() -> void:
	for action: String in KEYS:
		InputMap.add_action(action, 0.15)
		for key: int in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key as Key
			InputMap.action_add_event(action, ev)
	for action: String in PAD_BUTTONS:
		var ev := InputEventJoypadButton.new()
		ev.button_index = PAD_BUTTONS[action] as JoyButton
		InputMap.action_add_event(action, ev)
	for action: String in PAD_AXES:
		var ev := InputEventJoypadMotion.new()
		ev.axis = PAD_AXES[action][0] as JoyAxis
		ev.axis_value = PAD_AXES[action][1]
		InputMap.action_add_event(action, ev)


## True if the flag was passed either as a user arg (after --) or a plain arg.
func has_arg(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag) or OS.get_cmdline_args().has(flag)


## Value of "--name=value" from the command line, or def.
func arg_value(flag: String, def: String) -> String:
	for a: String in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return def
