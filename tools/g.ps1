# Dev helper: run Godot headless on a scene/script, print the last 25 lines without engine banner noise.
$g = 'C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe'
& $g --headless --path "$PSScriptRoot\.." @args 2>&1 | Where-Object { "$_" -notmatch '^(Godot Engine|\s*$)' } | Select-Object -Last 25
