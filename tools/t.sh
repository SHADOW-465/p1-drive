#!/bin/sh
# Dev helper: re-import (new class_names), then run Godot headless with the given args; filtered tail.
G=/c/Users/acer/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe
cd "$(dirname "$0")/.."
"$G" --headless --path . --import 2>&1 | grep -E "ERROR|Parse Error|WARNING" | head -10
timeout ${T:-110} "$G" --headless --path . "$@" 2>&1 | grep -vE "^\s*$|^Godot Engine" | tail -${N:-15}
