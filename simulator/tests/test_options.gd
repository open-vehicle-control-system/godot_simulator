extends TestCase
## The command-line options after `--`.


func test_reads_every_option() -> void:
	var arguments := PackedStringArray(
		[
			"--track=mettet",
			"--vehicle=ovcs1",
			"--packs=/a",
			"--packs=/b",
			"--link=10.0.0.2:7500",
			"--camera=cockpit",
			"--stereo-record=/tmp/run",
			"--show-stereo",
			"--spawn=12.5,-3,1.25,90",
			"--eye=1,2,30",
			"--screenshot=/tmp/shot.png",
		]
	)

	var parsed := SimulatorOptions.parse(arguments)

	assert_eq(parsed["error"] if parsed.has("error") else "", "")
	var options: SimulatorOptions = parsed["options"]
	assert_eq(options.track, "mettet")
	assert_eq(options.vehicle, "ovcs1")
	assert_eq(options.pack_directories, ["/a", "/b"] as Array[String])
	assert_eq(options.link_host, "10.0.0.2")
	assert_eq(options.link_port, 7500)
	assert_eq(options.view, "cockpit")
	assert_eq(options.stereo_record_directory, "/tmp/run")
	assert_true(options.show_stereo)
	assert_true(options.spawn_given)
	assert_almost_eq(options.spawn_position_m, Vector3(12.5, -3.0, 1.25))
	assert_almost_eq(options.spawn_yaw_deg, 90.0)
	assert_true(options.eye_given)
	assert_almost_eq(options.eye_position_m, Vector3(1.0, 2.0, 30.0))
	assert_eq(options.screenshot_path, "/tmp/shot.png")


func test_defaults_the_link_port_and_the_view() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(PackedStringArray(["--track=t", "--vehicle=v", "--link=localhost"]))["options"]
	)

	assert_eq(options.link_port, SimulatorOptions.DEFAULT_LINK_PORT)
	assert_eq(options.view, "chase")
	assert_eq(options.stereo_record_directory, "")
	assert_true(not options.spawn_given)
	assert_eq(options.screenshot_path, "")


func test_defaults_to_the_bundled_track_and_vehicle() -> void:
	var options: SimulatorOptions = SimulatorOptions.parse(PackedStringArray())["options"]

	assert_eq(options.track, "default_track")
	assert_eq(options.vehicle, "default_car")


func test_runs_without_a_link_when_none_is_given() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions.parse(PackedStringArray(["--track=t", "--vehicle=v"]))["options"]
	)

	assert_eq(options.link_host, "")


func test_rejects_what_it_does_not_understand() -> void:
	var cases := {
		"unknown option --fly": ["--track=t", "--vehicle=v", "--fly"],
		"--camera is one of chase, cockpit, bonnet, side, front":
		["--track=t", "--vehicle=v", "--camera=top"],
		"--link port is not a number": ["--track=t", "--vehicle=v", "--link=host:port"],
		"--spawn is X,Y,Z,YAW_DEG": ["--track=t", "--vehicle=v", "--spawn=1,2,north"],
		"--eye is X,Y,Z": ["--track=t", "--vehicle=v", "--eye=1,2"],
	}
	for reason in cases:
		assert_eq(
			SimulatorOptions.parse(PackedStringArray(cases[reason])), {"error": reason}, reason
		)


func test_keeps_equals_signs_inside_a_value() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(PackedStringArray(["--track=t", "--vehicle=v", "--packs=/a=b"]))["options"]
	)

	assert_eq(options.pack_directories, ["/a=b"] as Array[String])


func test_refuses_a_value_on_a_switch() -> void:
	var parsed := SimulatorOptions.parse(
		PackedStringArray(["--track=t", "--vehicle=v", "--show-stereo=false"])
	)

	assert_eq(parsed, {"error": "--show-stereo takes no value"})


func test_keyboard_turns_on_driving_with_the_arrow_keys() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(PackedStringArray(["--track=t", "--vehicle=v", "--keyboard"]))["options"]
	)

	assert_true(options.keyboard)


func test_timing_turns_on_the_frame_time_report() -> void:
	var arguments := PackedStringArray(["--track=t", "--vehicle=v", "--timing"])

	var options: SimulatorOptions = SimulatorOptions.parse(arguments)["options"]

	assert_true(options.timing)
	assert_true(not SimulatorOptions.parse(arguments.slice(0, 2))["options"].timing)


func test_keyboard_and_link_are_exclusive() -> void:
	var parsed := SimulatorOptions.parse(
		PackedStringArray(["--track=t", "--vehicle=v", "--keyboard", "--link=localhost"])
	)

	assert_eq(parsed, {"error": "--keyboard and --link both drive the vehicle: choose one"})


func test_hold_gives_the_speed_and_steering_to_keep() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(PackedStringArray(["--track=t", "--vehicle=v", "--hold=72,-10"]))["options"]
	)

	assert_true(options.hold_given)
	assert_almost_eq(options.hold_speed_m_s, 20.0, 1e-6)
	assert_almost_eq(options.hold_steering_rad, deg_to_rad(-10.0), 1e-6)


func test_hold_is_refused_with_another_way_of_driving_or_without_two_numbers() -> void:
	var cases := {
		"--keyboard": "--hold drives the vehicle: not with --keyboard or --link",
		"--link=localhost": "--hold drives the vehicle: not with --keyboard or --link",
		"--hold=fast": "--hold is KM_H,STEERING_DEG",
	}
	for argument in cases:
		var parsed := SimulatorOptions.parse(
			PackedStringArray(["--track=t", "--vehicle=v", "--hold=30,0", argument])
		)

		assert_eq(parsed, {"error": cases[argument]}, argument)


func test_ground_truth_is_recorded_with_the_stereo_pair() -> void:
	var recording := PackedStringArray(
		["--track=t", "--vehicle=v", "--stereo-record=/tmp/run", "--ground-truth"]
	)
	assert_true(SimulatorOptions.parse(recording)["options"].ground_truth)
	assert_true(not SimulatorOptions.parse(recording.slice(0, 3))["options"].ground_truth)
	assert_eq(
		SimulatorOptions.parse(PackedStringArray(["--track=t", "--vehicle=v", "--ground-truth"])),
		{"error": "--ground-truth is recorded: it needs --stereo-record or --record"}
	)


func test_record_records_the_ground_truth_with_or_without_ground_truth() -> void:
	var recording := PackedStringArray(
		["--track=t", "--vehicle=v", "--record=/tmp/run", "--record-seconds=1", "--hold=30,0"]
	)
	var parsed := SimulatorOptions.parse(recording + PackedStringArray(["--ground-truth"]))
	assert_true(parsed.has("options"), "refused: %s" % parsed)
	assert_true(parsed["options"].records_ground_truth())
	assert_true(SimulatorOptions.parse(recording)["options"].records_ground_truth())


func test_record_takes_a_directory_and_how_long_to_record() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(
			PackedStringArray(
				[
					"--track=t",
					"--vehicle=v",
					"--record=/tmp/run",
					"--record-seconds=2.5",
					"--hold=30,0"
				]
			)
		)["options"]
	)

	assert_eq(options.record_directory, "/tmp/run")
	assert_eq(options.record_s, 2.5)


func test_a_drive_log_drives_the_vehicle() -> void:
	var options: SimulatorOptions = (
		SimulatorOptions
		. parse(PackedStringArray(["--track=t", "--vehicle=v", "--drive-log=/tmp/poses.csv"]))["options"]
	)

	assert_eq(options.drive_log_path, "/tmp/poses.csv")


func test_record_and_drive_log_are_refused_with_what_they_cannot_go_with() -> void:
	var cases := {
		"--record is as long as --record-seconds or a --drive-log":
		["--record=/tmp/run", "--hold=30,0"],
		"--record-seconds is a positive number": ["--record=/tmp/run", "--record-seconds=soon"],
		"--record runs at its own pace: not with --link or --keyboard":
		["--record=/tmp/run", "--record-seconds=1", "--link=localhost"],
		"--record records the pair and its ground truth: not with --stereo-record":
		["--record=/tmp/run", "--record-seconds=1", "--stereo-record=/tmp/other"],
		"--record-seconds is how long --record lasts: it needs --record": ["--record-seconds=1"],
		"--drive-log drives the vehicle: not with --hold, --keyboard or --link":
		["--drive-log=/tmp/poses.csv", "--hold=30,0"],
	}
	for problem in cases:
		var arguments := PackedStringArray(["--track=t", "--vehicle=v"] + cases[problem])
		assert_eq(SimulatorOptions.parse(arguments), {"error": problem})


func test_set_overrides_pack_fields_in_order() -> void:
	var arguments := PackedStringArray(
		[
			"--set=vehicle.dynamics.brake_bias_front=0.65",
			"--set=track.sun.azimuth_deg=-30",
			"--set=vehicle.dynamics.driven_axle=rear",
		]
	)

	var options: SimulatorOptions = SimulatorOptions.parse(arguments)["options"]

	assert_eq(
		options.pack_settings,
		[
			["vehicle.dynamics.brake_bias_front", 0.65],
			["track.sun.azimuth_deg", -30.0],
			["vehicle.dynamics.driven_axle", "rear"],
		]
	)


func test_set_takes_a_vehicle_or_track_field_and_a_value() -> void:
	for argument in [
		"--set=dynamics.friction=1", "--set=vehicle.dynamics.friction", "--set=vehicle.=1"
	]:
		var parsed := SimulatorOptions.parse(PackedStringArray([argument]))

		var problem: String = parsed.get("error", "")
		assert_true(problem.begins_with("--set is PATH=VALUE, PATH a field of"), argument)
