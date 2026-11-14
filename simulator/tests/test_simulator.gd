extends TestCase
## The simulator as it starts from its command line: packs found, vehicle driven over the link.


func test_starts_from_its_options_and_is_driven_over_the_link() -> void:
	var server := LinkTestServer.new()
	var directory := PackFixtures.fresh_directory("simulator")
	PackFixtures.write_flat_world(
		PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat")), 200.0
	)
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var simulator: Node3D = load("res://main.tscn").instantiate()
	simulator.arguments = PackedStringArray(
		[
			"--track=flat",
			"--vehicle=small_car",
			"--packs=" + directory,
			"--link=127.0.0.1:%d" % server.port,
		]
	)

	add_child(simulator)
	for frame in 3 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		server.poll()
		if server.connected():
			server.send_drive(3.0, 0.0)
		if server.of_type("state").size() > 60:
			break

	var vehicle: Vehicle = simulator.get_node("Vehicle")
	assert_true(vehicle.global_position.z > 1.0, "driven to %s" % vehicle.global_position)
	assert_almost_eq(server.of_type("state").back()["linear_velocity_m_s"][0], 3.0, 1e-6)
	simulator.queue_free()
	server.stop()
