#!/usr/bin/env bash
# Runs the simulator's tests headless: ./simulator/tests/run_tests.sh [NAME_FILTER]
# A script error inside a test aborts it without a failed assertion: the run fails on one too.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GODOT:=godot}"
# The first headless start imports the project and registers its classes.
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
status=0
# Each frame steps 1/60 s of simulated time as fast as the machine runs it: a test of a
# minute's driving takes what the machine needs, not a minute.
timeout "${TEST_TIMEOUT_S:-300}" "$GODOT" --headless --fixed-fps 60 --path . -s tests/run_tests.gd -- "$@" 2>&1 | tee "$output" || status=$?
if grep -q "SCRIPT ERROR" "$output"; then
	echo "FAIL a test raised a script error (see SCRIPT ERROR above)" >&2
	exit 1
fi
exit "$status"
