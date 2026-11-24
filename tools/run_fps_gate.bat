@echo off
rem FPS / render budget report (PLAN 9.2): windowed, vsync off, per region and preset. Reports only (warns).
rem Usage: tools\run_fps_gate.bat [low|medium ...]   (default: medium)
setlocal
set GODOT=C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64.exe
cd /d "%~dp0.."
if not exist logs mkdir logs
set PRESETS=%*
if "%PRESETS%"=="" set PRESETS=medium
del logs\fps_gate.log 2>nul
for %%P in (%PRESETS%) do (
  rem Horizon Triland city routes (meta.json spawns tk_spawn_3, mc_spawn_1, db_spawn_1; x,z,dir,y): Shuto C1 Tokyo, Monaco harbour, Downtown Dubai
  call :one %%P tokyo "9777,-1692,-1,18.6"
  call :one %%P monaco "-8057.4,241.2,1,36.4"
  call :one %%P dubai "-553,5500,-1,6.1"
)
findstr /C:"FPS " logs\fps_gate.log
exit /b 0

:one
"%GODOT%" --path . res://tests/fps_gate.tscn -- --autodrive --preset=%1 --region=%2 "--spawn=%~3" %4 %5 >> logs\fps_gate.log 2>&1
exit /b 0
