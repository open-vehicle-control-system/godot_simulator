class_name SimulatorOptions
extends RefCounted
## The command-line options, after `--`:
##
##   --track=ID              the track pack to load (default_track by default)
##   --vehicle=ID            the vehicle pack to load (default_car by default)
##   --packs=DIR             a directory of packs, searched first; repeatable
##   --link=HOST[:PORT]      the OVCS simulator link to connect to (port 7400 by default);
##                           without it the vehicle stands still
##   --keyboard              drive with the arrow keys instead, without OVCS
##   --hold=KM_H,STEERING_DEG
##                           hold this speed and front wheel angle (positive left) instead,
##                           without OVCS: what a screenshot of a moving vehicle needs
##   --camera=VIEW           chase, cockpit, bonnet, side or front (chase by default)
##   --stereo-record=DIR     record stereo pairs, poses and calibration into DIR
##   --ground-truth          with --stereo-record, record each pair's depth, disparity and
##                           segmentation too
##   --record=DIR            record the stereo pair and its ground truth into DIR frame by
##                           frame at a fixed simulated rate, so that two runs record the
##                           same: needs Godot's --fixed-fps, which simulate.sh passes
##   --record-seconds=S      how long --record lasts, in simulated seconds (the length of the
##                           drive log when left out), after which the simulator quits
##   --drive-log=FILE        drive as this CSV tells over time instead, without OVCS: columns
##                           time_s, speed_m_s, steering_rad, as a recording's poses.csv
##   --show-stereo           show the stereo pair at start (V toggles it)
##   --spawn=X,Y,Z,YAW_DEG   start there instead of at the track's spawn: metres and degrees in
##                           the track's frame, as `spawn` in its pack.json
##   --eye=X,Y,Z             look at the vehicle from this fixed point of the track's frame
##   --screenshot=FILE       save the window as a PNG once the world has rendered, then quit
##   --upscale=LEVEL         draw the window smaller and upscale it with FSR 2: quality,
##                           balanced or performance; the stereo cameras are not upscaled
##   --set=PATH=VALUE        override a field of the vehicle's or the track's pack.json for this
##                           run, before the pack is checked: PATH from `vehicle.` or `track.`
##                           (`--set=vehicle.dynamics.brake_bias_front=0.65`), VALUE as JSON;
##                           repeatable, applied in order
##   --timing                report when the first frame was drawn and, every few seconds,
##                           the worst frame time, the GPU time and what was drawn

const DEFAULT_LINK_PORT := 7400

## The bundled packs (main.gd searches res://default_packs), so a clean clone runs as it is.
const DEFAULT_TRACK := "default_track"
const DEFAULT_VEHICLE := "default_car"

var track := DEFAULT_TRACK
var vehicle := DEFAULT_VEHICLE
var pack_directories: Array[String] = []
var link_host := ""
var link_port := DEFAULT_LINK_PORT
var view := "chase"
var stereo_record_directory := ""
var ground_truth := false
var record_directory := ""
var record_s := 0.0  ## 0: as long as the drive log
var drive_log_path := ""
var show_stereo := false
var keyboard := false
var hold_given := false
var hold_speed_m_s := 0.0
var hold_steering_rad := 0.0
var spawn_given := false
var spawn_position_m := Vector3.ZERO  ## the track's ROS frame: x, y, z up
var spawn_yaw_deg := 0.0
var eye_given := false
var eye_position_m := Vector3.ZERO  ## the track's ROS frame: x, y, z up
var screenshot_path := ""
var upscale := ""  ## a level of Upscaling.SCALES, or "" for none
var timing := false
var pack_settings: Array = []  ## [path, value] pairs, in the order given


static func parse(arguments: PackedStringArray) -> Dictionary:
	## `{"options": SimulatorOptions}`, or `{"error": reason}`.
	var options := SimulatorOptions.new()
	for argument in arguments:
		var separator := argument.find("=")
		var problem := ""
		if separator < 0:
			problem = options._read_switch(argument)
		elif argument.left(separator) == "--set":
			problem = options._read_pack_setting(argument.substr(separator + 1))
		else:
			problem = options._read(argument.left(separator), argument.substr(separator + 1))
		if problem != "":
			return {"error": problem}
	if options.keyboard and options.link_host != "":
		return {"error": "--keyboard and --link both drive the vehicle: choose one"}
	if options.hold_given and (options.keyboard or options.link_host != ""):
		return {"error": "--hold drives the vehicle: not with --keyboard or --link"}
	if options.ground_truth and options.stereo_record_directory == "":
		return {"error": "--ground-truth is recorded: it needs --stereo-record"}
	var problem := options._what_is_wrong_with_recording()
	if problem != "":
		return {"error": problem}
	return {"options": options}


func recording_directory() -> String:
	## Where the stereo pair is recorded, or "" when it is not.
	return record_directory if record_directory != "" else stereo_record_directory


func records_ground_truth() -> bool:
	## True when the pair's ground truth is recorded with it.
	return ground_truth or record_directory != ""


func _what_is_wrong_with_recording() -> String:
	var driven_otherwise := keyboard or link_host != ""
	var recording := record_directory != ""
	# What must not be, and why, most telling first.
	var refused := {
		"--drive-log drives the vehicle: not with --hold, --keyboard or --link":
		drive_log_path != "" and (hold_given or driven_otherwise),
		"--record-seconds is how long --record lasts: it needs --record":
		not recording and record_s > 0.0,
		"--record runs at its own pace: not with --link or --keyboard":
		recording and driven_otherwise,
		"--record records the pair and its ground truth: not with --stereo-record":
		recording and stereo_record_directory != "",
		"--record is as long as --record-seconds or a --drive-log":
		recording and record_s <= 0.0 and drive_log_path == "",
	}
	for problem: String in refused:
		if refused[problem]:
			return problem
	return ""


func _read(option: String, argument: String) -> String:
	match option:
		"--track":
			track = argument
		"--vehicle":
			vehicle = argument
		"--packs":
			pack_directories.append(argument)
		"--link":
			return _read_link(argument)
		"--camera", "--upscale":
			return _read_choice(option, argument)
		"--stereo-record":
			stereo_record_directory = argument
		"--record":
			record_directory = argument
		"--drive-log":
			drive_log_path = argument
		"--show-stereo":
			return "--show-stereo takes no value"
		"--spawn", "--eye", "--hold", "--record-seconds":
			return _read_numbers(option, argument)
		"--screenshot":
			screenshot_path = argument
		_:
			return "unknown option %s" % option
	return ""


func _read_pack_setting(setting: String) -> String:
	var separator := setting.find("=")
	var path := setting.left(separator) if separator > 0 else ""
	var under := path.get_slice(".", 0)
	if not under in ["vehicle", "track"] or path.get_slice_count(".") < 2 or path.ends_with("."):
		return (
			"--set is PATH=VALUE, PATH a field of the vehicle's or the track's pack.json"
			+ " (vehicle.… or track.…)"
		)
	var text := setting.substr(separator + 1)
	var json := JSON.new()
	pack_settings.append([path, json.data if json.parse(text) == OK else text])
	return ""


func _read_choice(option: String, choice: String) -> String:
	var choices: Array = ViewPoses.VIEWS if option == "--camera" else Upscaling.SCALES.keys()
	if not choice in choices:
		return "%s is one of %s" % [option, ", ".join(choices)]
	if option == "--camera":
		view = choice
	else:
		upscale = choice
	return ""


func _read_switch(option: String) -> String:
	match option:
		"--show-stereo":
			show_stereo = true
		"--keyboard":
			keyboard = true
		"--timing":
			timing = true
		"--ground-truth":
			ground_truth = true
		_:
			return "unknown option %s" % option
	return ""


func _read_hold(drive: String) -> String:
	var numbers := drive.split(",")
	if numbers.size() != 2 or not Array(numbers).all(func(number): return number.is_valid_float()):
		return "--hold is KM_H,STEERING_DEG"
	hold_given = true
	hold_speed_m_s = numbers[0].to_float() / Instruments.KM_H_PER_M_S
	hold_steering_rad = deg_to_rad(numbers[1].to_float())
	return ""


func _read_numbers(option: String, argument: String) -> String:
	match option:
		"--spawn":
			return _read_spawn(argument)
		"--eye":
			return _read_eye(argument)
		"--record-seconds":
			return _read_record_seconds(argument)
	return _read_hold(argument)


func _read_record_seconds(seconds: String) -> String:
	if not seconds.is_valid_float() or seconds.to_float() <= 0.0:
		return "--record-seconds is a positive number"
	record_s = seconds.to_float()
	return ""


func _read_spawn(pose: String) -> String:
	var numbers := pose.split(",")
	if numbers.size() != 4 or not Array(numbers).all(func(number): return number.is_valid_float()):
		return "--spawn is X,Y,Z,YAW_DEG"
	spawn_given = true
	spawn_position_m = Vector3(numbers[0].to_float(), numbers[1].to_float(), numbers[2].to_float())
	spawn_yaw_deg = numbers[3].to_float()
	return ""


func _read_eye(point: String) -> String:
	var numbers := point.split(",")
	if numbers.size() != 3 or not Array(numbers).all(func(number): return number.is_valid_float()):
		return "--eye is X,Y,Z"
	eye_given = true
	eye_position_m = Vector3(numbers[0].to_float(), numbers[1].to_float(), numbers[2].to_float())
	return ""


func _read_link(address: String) -> String:
	link_host = address.get_slice(":", 0)
	if address.contains(":"):
		var port := address.get_slice(":", 1)
		if not port.is_valid_int():
			return "--link port is not a number"
		link_port = port.to_int()
	return ""
