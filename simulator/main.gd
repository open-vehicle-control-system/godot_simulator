extends Node3D
## The composition root: reads the options (see SimulatorOptions), loads the track and vehicle
## packs, and wires the vehicle to the OVCS link, the stereo camera, its cockpit and the viewer.

## Searched after the --packs directories.
const DEFAULT_PACK_DIRECTORIES := ["user://packs"]
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
	var track_found := library.load_track(options.track)
	var vehicle_found := library.load_vehicle(options.vehicle)
	for found in [track_found, vehicle_found]:
		if found.has("error"):
			_quit_with("%s (packs: %s)" % [found["error"], ", ".join(_pack_directories(options))])
			return
	var track: TrackSpec = track_found["track"]
	if options.spawn_given:
		track.move_spawn(options.spawn_position_m, options.spawn_yaw_deg)
	track.labelled = options.ground_truth
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
	if options.stereo_record_directory != "":
		var problem := _record(options, vehicle, stereo)
		if problem != "":
			return problem
	var viewer := Viewer.new()
	viewer.keyboard_driving = options.keyboard
	viewer.holding_drive = options.hold_given
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
		var problem := instruments.setup(vehicle, model.cockpit_parts)
		if problem != "":
			return problem
	if spec.mirrors != null:
		viewer.mirrors = Mirrors.new()
		add_child(viewer.mirrors)
		var problem := viewer.mirrors.setup(spec, model.body, lighting["environment"])
		if problem != "":
			return problem
	if options.ground_truth:
		Segmentation.label_under(vehicle, Segmentation.VEHICLE)
	return ""


func _record(options: SimulatorOptions, vehicle: Vehicle, stereo: StereoCamera) -> String:
	## Records the stereo pair as the options tell; returns why it cannot, or "".
	if options.ground_truth:
		var problem := stereo.add_ground_truth(vehicle)
		if problem != "":
			return problem
	var recorder := StereoRecorder.new()
	add_child(recorder)
	return recorder.setup(
		options.stereo_record_directory,
		vehicle,
		stereo.optics.rate_hz,
		stereo.described(),
		stereo.request_next_frame
	)


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
