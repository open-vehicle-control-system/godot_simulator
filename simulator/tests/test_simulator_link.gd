extends TestCase
## The simulator link against a server speaking OVCS's side.

var _server: LinkTestServer


func test_a_drive_moves_the_vehicle_and_states_report_it_in_ros_frames() -> void:
	var vehicle := await _linked_vehicle("drive")
	await _until_connected()

	for step in 30:
		_server.send_drive(2.0, 0.0)
		await _step_and_poll(1)

	assert_true(vehicle.global_position.z > 0.5, "moved %s" % vehicle.global_position)
	var last: Dictionary = _server.of_type("state").back()
	assert_almost_eq(last["linear_velocity_m_s"][0], 2.0, 1e-6)
	assert_almost_eq(last["position_m"][0], vehicle.global_position.z, 0.05)
	assert_almost_eq(last["odometer_m"], vehicle.odometer_m, 0.05)
	_server.stop()


func test_stops_when_drives_stop() -> void:
	var vehicle := await _linked_vehicle("timeout")
	await _until_connected()
	_server.send_drive(2.0, 0.1)
	await _step_and_poll(5)

	var frames_past_timeout := ceili(
		(SimulatorLink.DRIVE_TIMEOUT_S + 0.1) * Engine.physics_ticks_per_second
	)
	await _step_and_poll(frames_past_timeout)

	assert_eq(vehicle.speed_m_s, 0.0)
	assert_almost_eq(vehicle.steering_rad, 0.1, 1e-6, "keeps the last steering")
	_server.stop()


func test_stops_and_reconnects_when_the_connection_drops() -> void:
	var vehicle := await _linked_vehicle("reconnect")
	await _until_connected()
	_server.send_drive(2.0, 0.0)
	await _step_and_poll(5)

	_server.drop_simulator()
	await _step_and_poll(5)
	var speed_after_drop := vehicle.speed_m_s
	await _until_connected()

	assert_eq(speed_after_drop, 0.0)
	assert_true(_server.connected(), "reconnected")
	_server.stop()


func test_drops_a_packet_it_does_not_read_and_keeps_going() -> void:
	var vehicle := await _linked_vehicle("unknown")
	await _until_connected()

	_server._peer.put_data(LinkProtocol.packet({"type": "teleport"}))
	_server.send_drive(1.0, 0.0)
	await _step_and_poll(10)

	assert_eq(vehicle.speed_m_s, 1.0)
	_server.stop()


func _linked_vehicle(test_name: String) -> Vehicle:
	_server = LinkTestServer.new()
	var directory := PackFixtures.fresh_directory("link_" + test_name)
	PackFixtures.write_flat_world(
		PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat")), 200.0
	)
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var world: Node3D = TrackWorld.load_world(library.load_track("flat")["track"])["world"]
	add_child(world)
	var spec: VehicleSpec = library.load_vehicle("small_car")["vehicle"]
	var vehicle := Vehicle.new()
	world.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	var link := SimulatorLink.new()
	world.add_child(link)
	link.setup(vehicle, "127.0.0.1", _server.port)
	return vehicle


func _step_and_poll(frames: int) -> void:
	for frame in frames:
		await get_tree().physics_frame
		_server.poll()


func _until_connected() -> void:
	var limit := ceili((SimulatorLink.RECONNECT_S + 1.0) * Engine.physics_ticks_per_second)
	for frame in limit:
		await _step_and_poll(1)
		if _server.connected() and not _server.of_type("state").is_empty():
			_server.headers.clear()
			return
	fail("the simulator never connected")


func test_never_blocks_when_ovcs_stops_reading() -> void:
	var vehicle := await _linked_vehicle("stalled")
	await _until_connected()
	var link: SimulatorLink = vehicle.get_parent().get_node("SimulatorLink")
	var large_image := PackedByteArray()
	large_image.resize(1024 * 1024)

	var started_ms := Time.get_ticks_msec()
	for image in 64:
		link.send_image("left", 0.0, "jpeg", large_image)
	await wait_physics_frames(5)

	assert_true(Time.get_ticks_msec() - started_ms < 2000, "the main thread kept running")
	assert_true(link.connected, "still connected: only images were dropped")
	_server.stop()
