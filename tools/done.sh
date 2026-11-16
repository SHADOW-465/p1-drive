#!/bin/sh
# Dev helper: run gates, tick the task in PROGRESS.md, commit. Usage: tools/done.sh T02 "note" "summary"
cd "$(dirname "$0")/.."
if ! cmd //c "tools\run_gates.bat"; then
	grep -hE "ERROR|WARNING|FAIL|Parse Error" logs/*.log | head -20
	exit 1
fi
python tools/tick.py "$1" "$2"
git add -A
git commit -qm "$1: $3

Co-Authored-By: Claude <noreply@anthropic.com>"
git log --oneline -1
