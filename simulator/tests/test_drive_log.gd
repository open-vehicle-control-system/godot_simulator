extends TestCase
## A drive log: the speed and steering to command over time, read from a CSV.


func test_reads_the_drive_of_each_time_from_its_columns_by_name() -> void:
	var found := DriveLog.parse(
		"time_s,speed_m_s,steering_rad\n0.0,1.5,0.0\n0.5,3.0,0.1\n2.0,0.0,-0.2\n"
	)

	assert_true(found.has("log"), str(found))
	var log: DriveLog = found["log"]
	assert_eq(log.duration_s(), 2.0)
	var cases := {
		0.0: [1.5, 0.0], 0.49: [1.5, 0.0], 0.5: [3.0, 0.1], 1.9: [3.0, 0.1], 2.0: [0.0, -0.2]
	}
	for time_s in cases:
		assert_eq(log.drive_at(time_s), cases[time_s], str(time_s))


func test_holds_its_first_drive_before_it_starts_and_its_last_after_it_ends() -> void:
	var log: DriveLog = (
		DriveLog.parse("time_s,speed_m_s,steering_rad\n1.0,2.0,0.1\n3.0,4.0,0.2\n")["log"]
	)

	assert_eq(log.drive_at(0.2), [2.0, 0.1])
	assert_eq(log.drive_at(30.0), [4.0, 0.2])


func test_reads_the_poses_of_a_recording_as_a_drive_log() -> void:
	var poses := (
		StereoRecorder.POSES_HEADER
		+ "\n0,0.0167,1,2,3,0,0,0,1,5.000,0.0100\n1,0.1167,1,2,3,0,0,0,1,6.000,0.0200\n"
	)

	var log: DriveLog = DriveLog.parse(poses)["log"]

	assert_eq(log.drive_at(0.1167), [6.0, 0.02])


func test_tells_what_is_wrong_with_a_log() -> void:
	var cases := {
		"": "no row",
		"time_s,speed_m_s\n0,1\n": "no steering_rad column",
		"time_s,speed_m_s,steering_rad\n": "no row",
		"time_s,speed_m_s,steering_rad\n0,fast,0\n": "row 1 is not three numbers",
		"time_s,speed_m_s,steering_rad\n1,1,0\n0.5,1,0\n": "row 2 is earlier than the row before",
	}
	for text in cases:
		assert_eq(DriveLog.parse(text), {"error": cases[text]}, text)


func test_drives_the_vehicle_as_the_log_tells() -> void:
	var vehicle := await VehicleFixtures.on_flat_ground(self, VehicleFixtures.small_car())
	var driver := SpeedDriver.new()
	add_child(driver)

	driver.follow(
		vehicle, DriveLog.parse("time_s,speed_m_s,steering_rad\n0,3.0,0\n2.0,0.0,0\n")["log"]
	)
	await wait_physics_frames(2 * Engine.physics_ticks_per_second)
	var driven_m := vehicle.global_position.z
	assert_almost_eq(vehicle.speed_m_s, 3.0, 0.3, "at the log's speed")
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	assert_almost_eq(vehicle.speed_m_s, 0.0, 0.01, "stopped as the log tells")
	assert_true(
		vehicle.global_position.z > driven_m + 0.5, "braked to a stop: %s" % vehicle.global_position
	)
