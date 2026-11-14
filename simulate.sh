#!/usr/bin/env bash
# Runs the simulator: ./simulate.sh --track=ID --vehicle=ID [--packs=DIR] [--link=HOST[:PORT]] ...
# Options are SimulatorOptions' (simulator/simulator_options.gd).
set -euo pipefail
: "${GODOT:=godot}"
here="$(dirname "$(readlink -f "$0")")"
arguments=()
for argument in "$@"; do
	case "$argument" in
	# Godot runs from the project directory: paths become absolute first.
	--packs=* | --stereo-record=* | --screenshot=*) arguments+=("${argument%%=*}=$(realpath -m "${argument#*=}")") ;;
	*) arguments+=("$argument") ;;
	esac
done
exec "$GODOT" --path "$here/simulator" -- "${arguments[@]}"
