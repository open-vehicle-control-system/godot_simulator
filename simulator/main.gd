extends Node3D
## The composition root: reads the options (see SimulatorOptions), loads the track and vehicle
## packs, and wires the vehicle to the OVCS link, the stereo camera, its cockpit and the viewer.

## Searched after the --packs directories, the bundled packs last: a pack anywhere with a
## bundled pack's id is refused with it, as any two packs of one id are.
const DEFAULT_PACK_DIRECTORIES := ["user://packs", "res://default_packs"]
## The VMS measures wheel speed against the wall clock: never wait on vsync, keep this rate.
const FRAMES_PER_S := 60
const EXIT_USAGE := 2

## The options it starts with: the command line's after `--` unless set before entering the tree.
var arguments := OS.get_cmdline_user_args()


func _ready() -> void:
	var parsed := SimulatorOptions.parse(arguments)
	if parsed.has("error"):
		_quit_with(parsed["error"])
		return
	var options: SimulatorOptions = parsed["options"]
	var library := PackLibrary.scan(_pack_directories(options))
	for problem in library.errors:
		push_warning("packs: %s" % problem)
	var track_found := library.load_track(options.track, options.pack_settings)
	var vehicle_found := library.load_vehicle(options.vehicle, options.pack_settings)
	for found in [track_found, vehicle_found]:
		if found.has("error"):
			_quit_with("%s (packs: %s)" % [found["error"], ", ".join(_pack_directories(options))])
			return
	var track: TrackSpec = track_found["track"]
	if options.spawn_given:
		track.move_spawn(options.spawn_position_m, options.spawn_yaw_deg)
	track.labelled = options.records_ground_truth()
	var problem := _build(options, track, vehicle_found["vehicle"])
	if problem != "":
		_quit_with(problem)


func _build(options: SimulatorOptions, track: TrackSpec, spec: VehicleSpec) -> String:
	# The vehicle's model and the sky are read on worker threads while the tiles around the
	# spawn load.
	var model_read := {}
	var sky_read := {}
	var model_task := WorkerThreadPool.add_task(_read_model_into.bind(model_read, spec))
	var sky_task := WorkerThreadPool.add_task(_read_sky_into.bind(sky_read, track))
	var world_found := TrackWorld.load_world(track)
	WorkerThreadPool.wait_for_task_completion(model_task)
	WorkerThreadPool.wait_for_task_completion(sky_task)
	if world_found.has("error"):
		return world_found["error"]
	var model_found := VehicleModel.build_from(spec, model_read)
	if model_found.has("error"):
		return model_found["error"]
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = FRAMES_PER_S
	get_window().title = "%s, %s" % [track.name, spec.name]
	var lighting := TrackWorld.lighting_under(track, sky_read)
	var world_environment := WorldEnvironment.new()
	world_environment.environment = lighting["environment"]
	add_child(world_environment)
	add_child(lighting["sun"])
	add_child(world_found["world"])
	var vehicle := Vehicle.new()
	add_child(vehicle)
	var model: VehicleModel = model_found["model"]
	vehicle.setup(spec, model)
	vehicle.global_transform = track.spawn_transform()
	var tiles: TrackTiles = world_found["world"]
	tiles.follow(vehicle)
	if options.timing:
		var frame_times := FrameTimes.new()
		add_child(frame_times)
		frame_times.setup(tiles, vehicle)
	var stereo := StereoCamera.new()
	add_child(stereo)
	stereo.setup(vehicle, spec.stereo)
	var link: SimulatorLink = null
	if options.link_host != "":
		link = SimulatorLink.new()
		add_child(link)
		link.setup(vehicle, options.link_host, options.link_port)
		var sender := StereoSender.new()
		add_child(sender)
		sender.setup(link, stereo.request_pair, spec.stereo.rate_hz)
	if options.hold_given:
		vehicle.command(options.hold_speed_m_s, options.hold_steering_rad)
	if options.keyboard:
		var driver := KeyboardDriver.new()
		add_child(driver)
		driver.setup(vehicle)
	var recording_problem := _drive_from_a_log_and_record(options, vehicle, stereo, tiles)
	if recording_problem != "":
		return recording_problem
	var viewer := Viewer.new()
	viewer.keyboard_driving = options.keyboard
	viewer.holding_drive = options.hold_given
	viewer.lighting = TrackWorld.window_lighting(lighting["environment"], track)
	if options.upscale != "":
		Upscaling.apply(get_viewport(), options.upscale)
	add_child(viewer)
	viewer.setup(vehicle, link, stereo, "%s  |  %s" % [spec.name, track.name], options.view)
	viewer.show_stereo(options.show_stereo)
	if options.eye_given:
		var eye := options.eye_position_m
		viewer.look_from(Vector3(eye.y, eye.z, eye.x))
	if options.screenshot_path != "":
		var screenshot := Screenshot.new()
		add_child(screenshot)
		screenshot.setup(options.screenshot_path)
	if spec.instruments != null:
		var instruments := Instruments.new()
		add_child(instruments)
		var reported_motor_rpm := link.motor_rpm if link != null else Callable()
		var problem := instruments.setup(vehicle, model.cockpit_parts, reported_motor_rpm)
		if problem != "":
			return problem
	if spec.mirrors != null:
		viewer.mirrors = Mirrors.new()
		add_child(viewer.mirrors)
		var problem := viewer.mirrors.setup(spec, model.body, lighting["environment"])
		if problem != "":
			return problem
	if options.records_ground_truth():
		Segmentation.label_under(vehicle, Segmentation.VEHICLE)
	return ""


func _drive_from_a_log_and_record(
	options: SimulatorOptions, vehicle: Vehicle, stereo: StereoCamera, tiles: TrackTiles
) -> String:
	## Drives the vehicle from the drive log and records the stereo pair, as far as the
	## options ask for either; returns why it cannot, or "".
	var drive_log_s := 0.0
	if options.drive_log_path != "":
		var found := DriveLog.parse(FileAccess.get_file_as_string(options.drive_log_path))
		if found.has("error"):
			return "--drive-log %s: %s" % [options.drive_log_path, found["error"]]
		var driver := DriveLogDriver.new()
		add_child(driver)
		driver.setup(vehicle, found["log"])
		drive_log_s = found["log"].duration_s()
	if options.recording_directory() == "":
		return ""
	var recorder := StereoRecorder.new()
	add_child(recorder)
	var problem := _record(options, recorder, vehicle, stereo)
	if problem == "" and options.record_directory != "":
		var record_s := options.record_s if options.record_s > 0.0 else drive_log_s
		problem = _record_frame_by_frame(recorder, record_s, tiles, vehicle)
	return problem


func _record(
	options: SimulatorOptions, recorder: StereoRecorder, vehicle: Vehicle, stereo: StereoCamera
) -> String:
	## Records the stereo pair with `recorder` as the options tell; returns why it cannot,
	## or "".
	if options.records_ground_truth():
		var problem := stereo.add_ground_truth(vehicle)
		if problem != "":
			return problem
	return recorder.setup(
		options.recording_directory(),
		vehicle,
		stereo.optics.rate_hz,
		stereo.described(),
		stereo.request_next_frame
	)


func _record_frame_by_frame(
	recorder: StereoRecorder, record_s: float, tiles: TrackTiles, vehicle: Vehicle
) -> String:
	## Makes `recorder`'s recording the same run after run, for `record_s` simulated seconds,
	## then quits: Godot's movie mode steps simulated time by one frame at a time, each is
	## drawn with all its tiles and recorded however long that takes. Returns why it cannot,
	## or "".
	if not OS.has_feature("movie"):
		return "--record needs Godot's movie mode (--write-movie), which simulate.sh starts"
	var at_once := TilesAtOnce.new()
	add_child(at_once)
	at_once.setup(tiles, vehicle)
	recorder.record_every_frame()
	recorder.end_after(record_s)
	recorder.ended.connect(get_tree().quit)
	return ""


static func _read_model_into(read: Dictionary, spec: VehicleSpec) -> void:
	## Reads the vehicle's model into `read`, off the main thread.
	read.merge(VehicleModel.read(spec))


static func _read_sky_into(read: Dictionary, track: TrackSpec) -> void:
	## Reads the track's sky into `read`, off the main thread.
	read.merge(TrackWorld.read_sky(track))


func _pack_directories(options: SimulatorOptions) -> Array[String]:
	var directories: Array[String] = options.pack_directories.duplicate()
	directories.append(OS.get_executable_path().get_base_dir().path_join("packs"))
	for directory in DEFAULT_PACK_DIRECTORIES:
		directories.append(ProjectSettings.globalize_path(directory))
	var existing: Array[String] = []
	existing.assign(
		directories.filter(func(directory): return DirAccess.dir_exists_absolute(directory))
	)
	return existing


func _quit_with(problem: String) -> void:
	printerr("simulator: ", problem)
	get_tree().quit(EXIT_USAGE)
