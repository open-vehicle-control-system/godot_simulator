class_name StereoRecorder
extends Node
## Records stereo frames for offline vision work: an image or a map per frame in a directory
## each (left/NNNNNN.png, right/NNNNNN.png and, with ground truth, segmentation/NNNNNN.png,
## depth/NNNNNN.npy, disparity/NNNNNN.npy), a row of poses.csv per frame, and calib.json.
## Poses are the vehicle's base_link in the world, in ROS frames as the link reports them.

const POSES_HEADER := "frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad"
## The processor's threads left to the simulation while files are written, one a thread: a
## frame handed over while every other thread writes is not recorded, so a disk or encoder
## slower than the camera never holds the simulation back.
const THREADS_KEPT_FREE := 4
const MIN_FILES_BEING_WRITTEN := 4

## Low priority tasks share a few of the pool's threads: too few to encode at the camera's rate.
const HIGH_PRIORITY := true

var _directory: String
var _vehicle: Vehicle
var _request_frame: Callable
var _period_s: float
var _time_s := 0.0
var _next_capture_s := 0.0
var _capture_due := false
var _frame := 0
var _poses: FileAccess
var _writing_tasks: Array[int] = []
var _directories_made := {}
var _frames_skipped := 0
var _max_files_being_written := maxi(
	MIN_FILES_BEING_WRITTEN, OS.get_processor_count() - THREADS_KEPT_FREE
)


func setup(
	directory: String,
	vehicle: Vehicle,
	rate_hz: float,
	calibration: Dictionary,
	request_frame: Callable
) -> String:
	## Records into `directory`, `rate_hz` times a second, the StereoFrame that `request_frame`
	## hands to the function it is called with, at once or a few frames later, of the frame
	## about to be drawn; `calibration` becomes calib.json. Returns why it cannot, or "".
	_directory = directory
	_vehicle = vehicle
	_request_frame = request_frame
	_period_s = 1.0 / rate_hz
	name = "StereoRecorder"
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return "recorder: cannot write %s" % directory
	var calibration_file := FileAccess.open(directory.path_join("calib.json"), FileAccess.WRITE)
	if calibration_file == null:
		return "recorder: cannot write %s" % directory
	calibration_file.store_string(JSON.stringify(calibration, "  "))
	_poses = FileAccess.open(directory.path_join("poses.csv"), FileAccess.WRITE)
	_poses.store_line(POSES_HEADER)
	print("recorder: %s at %.0f Hz" % [directory, rate_hz])
	return ""


func finish() -> void:
	## Waits for the frames being written and closes the poses. A frame not handed over yet
	## is not recorded.
	for task in _writing_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_writing_tasks.clear()
	if _poses != null:
		_poses.close()
		_poses = null
		print("recorder: %d frames recorded, %d skipped" % [_frame, _frames_skipped])


func _physics_process(delta: float) -> void:
	if _poses == null:
		return
	_time_s += delta
	if _time_s < _next_capture_s:
		return
	_next_capture_s += _period_s
	if _next_capture_s <= _time_s:
		_next_capture_s = _time_s + _period_s
	_capture_due = true


func _process(_delta: float) -> void:
	# Physics has stepped and the frame is not drawn yet: it will show this state.
	if _poses == null or not _capture_due:
		return
	_capture_due = false
	var shown := {
		"time_s": _time_s,
		"pose": _vehicle.global_transform,
		"speed_m_s": _vehicle.speed_m_s,
		"steering_rad": _vehicle.steering_rad,
	}
	_request_frame.call(_record.bind(shown))


func _record(frame: StereoFrame, shown: Dictionary) -> void:
	if _poses == null:
		return
	_writing_tasks = _writing_tasks.filter(func(task): return not _completed(task))
	if _writing_tasks.size() >= _max_files_being_written:
		_frames_skipped += 1
		return
	for image in frame.images:
		_writing_tasks.append(
			WorkerThreadPool.add_task(
				_write_image.bind(frame.images[image], _path(image, "png")), HIGH_PRIORITY
			)
		)
	for map in frame.maps:
		var file := NumpyFile.float32_image(frame.size_px.x, frame.size_px.y, frame.maps[map])
		_writing_tasks.append(
			WorkerThreadPool.add_task(_write_file.bind(file, _path(map, "npy")), HIGH_PRIORITY)
		)
	var pose: Transform3D = shown["pose"]
	var position := LinkProtocol.to_ros(pose.origin)
	var rotation := pose.basis.orthonormalized().get_rotation_quaternion()
	var row := [
		str(_frame),
		"%.4f" % shown["time_s"],
		"%.4f" % position[0],
		"%.4f" % position[1],
		"%.4f" % position[2],
		"%.6f" % rotation.z,
		"%.6f" % rotation.x,
		"%.6f" % rotation.y,
		"%.6f" % rotation.w,
		"%.3f" % shown["speed_m_s"],
		"%.4f" % shown["steering_rad"],
	]
	_poses.store_line(",".join(row))
	_poses.flush()  # a recording is often ended by killing the simulator
	_frame += 1


func _path(kind: String, extension: String) -> String:
	## Where this frame's file of `kind` goes, its directory made.
	var directory := _directory.path_join(kind)
	if not _directories_made.has(kind):
		DirAccess.make_dir_recursive_absolute(directory)
		_directories_made[kind] = true
	return directory.path_join("%06d.%s" % [_frame, extension])


static func _write_image(image: Image, path: String) -> void:
	image.convert(Image.FORMAT_RGB8)
	image.save_png(path)


static func _write_file(file: PackedByteArray, path: String) -> void:
	FileAccess.open(path, FileAccess.WRITE).store_buffer(file)


static func _completed(task: int) -> bool:
	if not WorkerThreadPool.is_task_completed(task):
		return false
	WorkerThreadPool.wait_for_task_completion(task)
	return true


func _exit_tree() -> void:
	finish()
