#!/usr/bin/env bash
# Runs the simulator: ./simulate.sh --track=ID --vehicle=ID [--packs=DIR] [--link=HOST[:PORT]] ...
# Options are SimulatorOptions' (simulator/simulator_options.gd).
set -euo pipefail
: "${GODOT:=godot}"
here="$(dirname "$(readlink -f "$0")")"
arguments=()
engine_arguments=()
for argument in "$@"; do
	case "$argument" in
	# --record runs in Godot's movie mode, which steps simulated time frame by frame whatever
	# the wall clock says, and writes what the window shows, kept small, next to the recording.
	--record=*)
		mkdir -p "$(realpath -m "${argument#*=}")"
		engine_arguments=(--write-movie "$(realpath -m "${argument#*=}")/window.avi" --fixed-fps 60 --resolution 640x360)
		;;
	esac
	case "$argument" in
	# Godot runs from the project directory: paths become absolute first.
	--packs=* | --stereo-record=* | --screenshot=* | --record=* | --drive-log=*) arguments+=("${argument%%=*}=$(realpath -m "${argument#*=}")") ;;
	*) arguments+=("$argument") ;;
	esac
done
exec "$GODOT" --path "$here/simulator" "${engine_arguments[@]}" -- "${arguments[@]}"
