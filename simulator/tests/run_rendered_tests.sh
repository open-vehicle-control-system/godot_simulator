#!/usr/bin/env bash
# Runs the tests that render, in a window: ./simulator/tests/run_rendered_tests.sh [NAME_FILTER]
# They need a display and a GPU; run_tests.sh runs the others headless.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GODOT:=godot}"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
status=0
timeout "${TEST_TIMEOUT_S:-120}" "$GODOT" --path . --resolution 320x180 \
	-s tests/rendered/run_rendered_tests.gd -- "$@" 2>&1 | tee "$output" || status=$?
if grep -q "SCRIPT ERROR" "$output"; then
	echo "FAIL a test raised a script error (see SCRIPT ERROR above)" >&2
	exit 1
fi
exit "$status"
