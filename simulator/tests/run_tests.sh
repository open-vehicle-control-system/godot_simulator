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
timeout "${TEST_TIMEOUT_S:-300}" "$GODOT" --headless --path . -s tests/run_tests.gd -- "$@" 2>&1 | tee "$output" || status=$?
if grep -q "SCRIPT ERROR" "$output"; then
	echo "FAIL a test raised a script error (see SCRIPT ERROR above)" >&2
	exit 1
fi
exit "$status"
