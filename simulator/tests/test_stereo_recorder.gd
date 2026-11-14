extends TestCase
## Recording stereo pairs, poses and calibration to a directory.


func test_records_matching_frames_a_pose_each_and_the_calibration() -> void:
	var directory := PackFixtures.fresh_directory("recording")
	var vehicle := Vehicle.new()
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	var recording := directory.path_join("run")
	var recorder := StereoRecorder.new()
	add_child(recorder)

	recorder.setup(recording, vehicle, spec.stereo, _solid_pair)
	await wait_physics_frames(ceili(0.45 * Engine.physics_ticks_per_second))
	recorder.finish()

	var left := _pngs(recording.path_join("left"))
	assert_eq(left.size(), 5, "10 Hz for 0.45 s")
	assert_eq(_pngs(recording.path_join("right")), left)
	var rows := FileAccess.get_file_as_string(recording.path_join("poses.csv")).strip_edges().split(
		"\n"
	)
	assert_eq(rows[0], "frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad")
	assert_eq(rows.size(), 1 + left.size())
	assert_true(rows[1].begins_with("0,"), rows[1])
	var calibration: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(recording.path_join("calib.json"))
	)
	assert_almost_eq(calibration["fx"], 160.0, 1e-4)
	assert_eq(calibration["baseline_m"], 0.12)
	assert_eq(calibration["mount_m"], [0.6, 0.0, 1.16])


func _solid_pair() -> Array[Image]:
	var left := Image.create(16, 8, false, Image.FORMAT_RGB8)
	var right := Image.create(16, 8, false, Image.FORMAT_RGB8)
	return [left, right]


func _pngs(directory: String) -> Array:
	return Array(DirAccess.get_files_at(directory)).filter(
		func(file): return file.ends_with(".png")
	)


func test_reports_a_directory_it_cannot_write() -> void:
	var directory := PackFixtures.fresh_directory("unwritable")
	FileAccess.open(directory.path_join("taken"), FileAccess.WRITE).store_string("a file")
	var recorder := StereoRecorder.new()
	add_child(recorder)

	var problem := recorder.setup(
		directory.path_join("taken/run"), Vehicle.new(), _optics(), _solid_pair
	)

	assert_true(problem.begins_with("recorder: cannot write"), problem)


func _optics() -> VehicleSpec.StereoOptics:
	var optics := VehicleSpec.StereoOptics.new()
	optics.width_px = 16
	optics.height_px = 8
	optics.hfov_deg = 90.0
	optics.rate_hz = 10.0
	return optics
