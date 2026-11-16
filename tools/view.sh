#!/bin/sh
# Dev helper: windowed car viewer shots. Usage: tools/view.sh name yaw pitch [extra args]
G=/c/Users/acer/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe
cd "$(dirname "$0")/.."
n=$1; y=$2; p=$3; shift 3
timeout 60 "$G" --path . res://tests/car_view.tscn -- --name=$n --yaw=$y --pitch=$p "$@" 2>&1 | grep -E "ERROR|WARNING|Parse" | head
