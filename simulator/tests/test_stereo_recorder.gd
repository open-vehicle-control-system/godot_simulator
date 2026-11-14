extends TestCase
## Recording stereo pairs, ground truth, poses and calibration to a directory.

const WIDTH_PX := 16
const HEIGHT_PX := 8


func test_records_matching_frames_a_pose_each_and_the_calibration() -> void:
	var directory := PackFixtures.fresh_directory("recording")
	var vehicle := _vehicle(directory)
	var recording := directory.path_join("run")
	var recorder := StereoRecorder.new()
	add_child(recorder)

	recorder.setup(recording, vehicle, 10.0, {"fx": 160.0}, _hand_over_a_pair)
	await wait_physics_frames(ceili(0.45 * Engine.physics_ticks_per_second))
	recorder.finish()

	var left := _files(recording.path_join("left"))
	assert_eq(left.size(), 5, "10 Hz for 0.45 s")
	assert_eq(left[0], "000000.png")
	assert_eq(_files(recording.path_join("right")), left)
	var rows := FileAccess.get_file_as_string(recording.path_join("poses.csv")).strip_edges().split(
		"\n"
	)
	assert_eq(rows[0], "frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad")
	assert_eq(rows.size(), 1 + left.size())
	assert_true(rows[1].begins_with("0,"), rows[1])
	var calibration: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(recording.path_join("calib.json"))
	)
	assert_eq(calibration, {"fx": 160.0})
	assert_true(not DirAccess.dir_exists_absolute(recording.path_join("depth")))


func test_records_the_ground_truth_of_each_pair() -> void:
	var directory := PackFixtures.fresh_directory("recording_ground_truth")
	var vehicle := _vehicle(directory)
	var recording := directory.path_join("run")
	var recorder := StereoRecorder.new()
	add_child(recorder)

	recorder.setup(recording, vehicle, 10.0, {}, _hand_over_a_pair_with_ground_truth)
	await wait_physics_frames(ceili(0.25 * Engine.physics_ticks_per_second))
	recorder.finish()

	var left := _files(recording.path_join("left"))
	assert_eq(left.size(), 3)
	assert_eq(_files(recording.path_join("segmentation")), left)
	var maps := ["000000.npy", "000001.npy", "000002.npy"]
	assert_eq(_files(recording.path_join("depth")), maps)
	assert_eq(_files(recording.path_join("disparity")), maps)
	var depth := FileAccess.get_file_as_bytes(recording.path_join("depth/000001.npy"))
	assert_eq(depth, NumpyFile.float32_image(WIDTH_PX, HEIGHT_PX, _floats(12.5)))
	var disparity := FileAccess.get_file_as_bytes(recording.path_join("disparity/000001.npy"))
	assert_eq(disparity, NumpyFile.float32_image(WIDTH_PX, HEIGHT_PX, _floats(1.5)))


func test_a_frame_handed_over_later_is_recorded_with_the_pose_it_was_asked_at() -> void:
	var directory := PackFixtures.fresh_directory("recording_later")
	var vehicle := _vehicle(directory)
	var recording := directory.path_join("run")
	var recorder := StereoRecorder.new()
	add_child(recorder)
	var asked: Array[Callable] = []

	recorder.setup(recording, vehicle, 10.0, {}, func(deliver): asked.append(deliver))
	await wait_physics_frames(3)
	vehicle.global_position.x = 5.0
	asked[0].call(_pair())
	recorder.finish()

	var rows := FileAccess.get_file_as_string(recording.path_join("poses.csv")).strip_edges().split(
		"\n"
	)
	assert_eq(rows.size(), 2)
	assert_almost_eq(rows[1].split(",")[3].to_float(), 0.0, 1e-3, "y_m: Godot's x")


func test_reports_a_directory_it_cannot_write() -> void:
	var directory := PackFixtures.fresh_directory("unwritable")
	FileAccess.open(directory.path_join("taken"), FileAccess.WRITE).store_string("a file")
	var recorder := StereoRecorder.new()
	add_child(recorder)

	var problem := recorder.setup(
		directory.path_join("taken/run"), Vehicle.new(), 10.0, {}, _hand_over_a_pair
	)

	assert_true(problem.begins_with("recorder: cannot write"), problem)


func _hand_over_a_pair(deliver: Callable) -> void:
	deliver.call(_pair())


func _hand_over_a_pair_with_ground_truth(deliver: Callable) -> void:
	var frame := _pair()
	frame.images["segmentation"] = Image.create(WIDTH_PX, HEIGHT_PX, false, Image.FORMAT_RGB8)
	frame.maps["depth"] = _floats(12.5)
	frame.maps["disparity"] = _floats(1.5)
	deliver.call(frame)


func _pair() -> StereoFrame:
	var frame := StereoFrame.new(Vector2i(WIDTH_PX, HEIGHT_PX))
	frame.images["left"] = Image.create(WIDTH_PX, HEIGHT_PX, false, Image.FORMAT_RGB8)
	frame.images["right"] = Image.create(WIDTH_PX, HEIGHT_PX, false, Image.FORMAT_RGB8)
	return frame


func _floats(value: float) -> PackedByteArray:
	var floats := PackedFloat32Array()
	floats.resize(WIDTH_PX * HEIGHT_PX)
	floats.fill(value)
	return floats.to_byte_array()


func _vehicle(directory: String) -> Vehicle:
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	var vehicle := Vehicle.new()
	add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	return vehicle


func _files(directory: String) -> Array:
	var files := Array(DirAccess.get_files_at(directory))
	files.sort()
	return files
