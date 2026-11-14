class_name StereoRecorder
extends Node
## Records stereo pairs for offline vision work: left/NNNNNN.png and right/NNNNNN.png, a row of
## poses.csv per pair, and calib.json. Poses are the vehicle's base_link in the world, in ROS
## frames as the link reports them; calib.json gives the intrinsics, the baseline and where the
## pair sits on base_link.

const MOUNT_PRECISION_M := 1e-6  # Vector3 is single precision
const POSES_HEADER := "frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad"

var _directory: String
var _vehicle: Vehicle
var _capture: Callable
var _period_s: float
var _time_s := 0.0
var _next_capture_s := 0.0
var _frame := 0
var _poses: FileAccess
var _writing_tasks: Array[int] = []
var _drawn := {}  # the time and vehicle state of the frame last drawn


func setup(
	directory: String, vehicle: Vehicle, optics: VehicleSpec.StereoOptics, capture: Callable
) -> String:
	## Records what `capture` returns (`[left, right]` images) at the optics' rate into
	## `directory`; returns why it cannot, or "".
	_directory = directory
	_vehicle = vehicle
	_capture = capture
	_period_s = 1.0 / optics.rate_hz
	name = "StereoRecorder"
	for side in ["left", "right"]:
		if DirAccess.make_dir_recursive_absolute(directory.path_join(side)) != OK:
			return "recorder: cannot write %s" % directory
	if not _write_calibration(optics):
		return "recorder: cannot write %s" % directory
	_poses = FileAccess.open(directory.path_join("poses.csv"), FileAccess.WRITE)
	_poses.store_line(POSES_HEADER)
	_remember_drawn()
	print("recorder: %s at %.0f Hz" % [directory, optics.rate_hz])
	return ""


func finish() -> void:
	## Waits for the images being written and closes the poses.
	for task in _writing_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_writing_tasks.clear()
	if _poses != null:
		_poses.close()
		_poses = null


func _physics_process(delta: float) -> void:
	if _poses == null:
		return
	_time_s += delta
	if _time_s < _next_capture_s:
		return
	_next_capture_s += _period_s
	if _next_capture_s <= _time_s:
		_next_capture_s = _time_s + _period_s
	_record_pair()


func _record_pair() -> void:
	var file_name := "%06d.png" % _frame
	var pair: Array[Image] = _capture.call()
	var paths := [
		_directory.path_join("left").path_join(file_name),
		_directory.path_join("right").path_join(file_name),
	]
	_writing_tasks = _writing_tasks.filter(func(task): return not _completed(task))
	_writing_tasks.append(WorkerThreadPool.add_task(_write_pair.bind(pair, paths)))
	var pose: Transform3D = _drawn["pose"]
	var position := LinkProtocol.to_ros(pose.origin)
	var rotation := pose.basis.orthonormalized().get_rotation_quaternion()
	var row := [
		str(_frame),
		"%.4f" % _drawn["time_s"],
		"%.4f" % position[0],
		"%.4f" % position[1],
		"%.4f" % position[2],
		"%.6f" % rotation.z,
		"%.6f" % rotation.x,
		"%.6f" % rotation.y,
		"%.6f" % rotation.w,
		"%.3f" % _drawn["speed_m_s"],
		"%.4f" % _drawn["steering_rad"],
	]
	_poses.store_line(",".join(row))
	_frame += 1


static func _write_pair(pair: Array[Image], paths: Array) -> void:
	pair[0].save_png(paths[0])
	pair[1].save_png(paths[1])


func _process(_delta: float) -> void:
	# Physics steps before drawing: a capture returns the frame drawn in this state.
	if _poses != null:
		_remember_drawn()


func _remember_drawn() -> void:
	_drawn = {
		"time_s": _time_s,
		"pose": _vehicle.global_transform,
		"speed_m_s": _vehicle.speed_m_s,
		"steering_rad": _vehicle.steering_rad,
	}


func _write_calibration(optics: VehicleSpec.StereoOptics) -> bool:
	var calibration := StereoCamera.intrinsics(optics)
	calibration["mount_m"] = LinkProtocol.to_ros(optics.mount).map(
		func(metres): return snappedf(metres, MOUNT_PRECISION_M)
	)
	calibration["pitch_down_deg"] = optics.pitch_deg
	calibration["camera_frame"] = "OpenCV: x right, y down, z forward; right = left + baseline along x"
	calibration["mount_frame"] = "ROS base_link: x forward, y left, z up; midway between the cameras"
	var file := FileAccess.open(_directory.path_join("calib.json"), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(calibration, "  "))
	return true


static func _completed(task: int) -> bool:
	if not WorkerThreadPool.is_task_completed(task):
		return false
	WorkerThreadPool.wait_for_task_completion(task)
	return true


func _exit_tree() -> void:
	finish()
