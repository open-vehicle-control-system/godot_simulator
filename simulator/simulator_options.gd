class_name SimulatorOptions
extends RefCounted
## The command-line options, after `--`:
##
##   --track=ID              the track pack to load (required)
##   --vehicle=ID            the vehicle pack to load (required)
##   --packs=DIR             a directory of packs, searched first; repeatable
##   --link=HOST[:PORT]      the OVCS simulator link to connect to (port 7400 by default);
##                           without it the vehicle stands still
##   --keyboard              drive with the arrow keys instead, without OVCS
##   --hold=KM_H,STEERING_DEG
##                           hold this speed and front wheel angle (positive left) instead,
##                           without OVCS: what a screenshot of a moving vehicle needs
##   --camera=VIEW           chase, cockpit, bonnet, side or front (chase by default)
##   --stereo-record=DIR     record stereo pairs, poses and calibration into DIR
##   --show-stereo           show the stereo pair at start (V toggles it)
##   --spawn=X,Y,Z,YAW_DEG   start there instead of at the track's spawn: metres and degrees in
##                           the track's frame, as `spawn` in its pack.json
##   --eye=X,Y,Z             look at the vehicle from this fixed point of the track's frame
##   --screenshot=FILE       save the window as a PNG once the world has rendered, then quit
##   --timing                report when the first frame was drawn and, every few seconds,
##                           the worst frame time

const DEFAULT_LINK_PORT := 7400

var track := ""
var vehicle := ""
var pack_directories: Array[String] = []
var link_host := ""
var link_port := DEFAULT_LINK_PORT
var view := "chase"
var stereo_record_directory := ""
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
var timing := false


static func parse(arguments: PackedStringArray) -> Dictionary:
	## `{"options": SimulatorOptions}`, or `{"error": reason}`.
	var options := SimulatorOptions.new()
	for argument in arguments:
		var separator := argument.find("=")
		var problem := ""
		if separator < 0:
			problem = options._read_switch(argument)
		else:
			problem = options._read(argument.left(separator), argument.substr(separator + 1))
		if problem != "":
			return {"error": problem}
	if options.track == "":
		return {"error": "--track is required"}
	if options.vehicle == "":
		return {"error": "--vehicle is required"}
	if options.keyboard and options.link_host != "":
		return {"error": "--keyboard and --link both drive the vehicle: choose one"}
	if options.hold_given and (options.keyboard or options.link_host != ""):
		return {"error": "--hold drives the vehicle: not with --keyboard or --link"}
	return {"options": options}


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
		"--camera":
			if not argument in ViewPoses.VIEWS:
				return "--camera is one of %s" % ", ".join(ViewPoses.VIEWS)
			view = argument
		"--stereo-record":
			stereo_record_directory = argument
		"--show-stereo":
			return "--show-stereo takes no value"
		"--spawn", "--eye", "--hold":
			return _read_numbers(option, argument)
		"--screenshot":
			screenshot_path = argument
		_:
			return "unknown option %s" % option
	return ""


func _read_switch(option: String) -> String:
	match option:
		"--show-stereo":
			show_stereo = true
		"--keyboard":
			keyboard = true
		"--timing":
			timing = true
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
	return _read_hold(argument)


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
