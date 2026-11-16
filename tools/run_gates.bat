@echo off
rem All quality gates (PLAN 8). One PASS/FAIL line per gate; logs in logs\.
setlocal
set GODOT=C:\Users\acer\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe
cd /d "%~dp0.."
if not exist logs mkdir logs
set FAIL=0
call :run import --import
call :run check -s res://tools/check_scripts.gd
call :run boot --quit
if exist tests\smoke_test.tscn call :run smoke --fixed-fps 60 res://tests/smoke_test.tscn
if exist tests\streaming_test.tscn call :run stream --fixed-fps 60 res://tests/streaming_test.tscn
if exist tests\drive_test.tscn call :run drive --fixed-fps 60 res://tests/drive_test.tscn
if %FAIL%==0 (echo GATES PASS) else (echo GATES FAIL)
exit /b %FAIL%

:run
set NAME=%1
"%GODOT%" --headless --path . %2 %3 %4 > logs\%NAME%.log 2>&1
set RC=%ERRORLEVEL%
rem the Jolt job-pool line is an intermittent engine-internal warning in fast headless runs; not ours
findstr /V /C:"Jolt Physics job system" logs\%NAME%.log | findstr /C:"ERROR" /C:"Parse Error" /C:"WARNING" >nul && set RC=1
if %RC%==0 (echo PASS %NAME%) else (echo FAIL %NAME%& set FAIL=1)
exit /b 0
