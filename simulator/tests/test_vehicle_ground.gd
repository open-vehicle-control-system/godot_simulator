extends TestCase
## The vehicle rests on its four wheels: the body follows the plane of their contacts and each
## wheel follows its own patch of ground, so no wheel sinks where the ground changes slope.

const RAMP_DEG := 15.0
const RAMP_START_Z := 6.0
const ALLOWED_SINK_M := 0.02


func test_a_uniform_slope_pitches_the_body_and_leaves_every_wheel_on_it() -> void:
	var slope := tan(deg_to_rad(10.0))
	var contacts: Array[Vector3] = []
	for corner in [
		Vector3(0.7, 0, 1.2), Vector3(-0.7, 0, 1.2), Vector3(0.7, 0, -1.3), Vector3(-0.7, 0, -1.3)
	]:
		contacts.append(Vector3(corner.x, corner.z * slope, corner.z))

	var fit := GroundContact.fit(Vector3.ZERO, contacts)

	var pose: Transform3D = fit["pose"]
	assert_almost_eq(pose.basis.z, Vector3(0.0, sin(deg_to_rad(10.0)), cos(deg_to_rad(10.0))), 1e-5)
	assert_almost_eq(pose.origin, Vector3.ZERO, 1e-5)
	for lift in fit["wheel_lifts_m"]:
		assert_almost_eq(lift, 0.0, 1e-5)


func test_a_raised_corner_lifts_that_wheel() -> void:
	var contacts: Array[Vector3] = [
		Vector3(0.7, 0.08, 1.2),
		Vector3(-0.7, 0.0, 1.2),
		Vector3(0.7, 0.0, -1.3),
		Vector3(-0.7, 0.0, -1.3)
	]

	var lifts: Array = GroundContact.fit(Vector3.ZERO, contacts)["wheel_lifts_m"]

	assert_true(lifts[0] > 0.0, "front left rises: %s" % [lifts])
	assert_true(lifts[1] < 0.0 and lifts[2] < 0.0, "its neighbours drop: %s" % [lifts])


func test_wheel_lifts_stay_within_the_suspension_travel() -> void:
	var contacts: Array[Vector3] = [
		Vector3(0.7, 1.0, 1.2),
		Vector3(-0.7, 0.0, 1.2),
		Vector3(0.7, 0.0, -1.3),
		Vector3(-0.7, 0.0, -1.3)
	]

	var lifts: Array = GroundContact.fit(Vector3.ZERO, contacts)["wheel_lifts_m"]

	for lift in lifts:
		assert_true(absf(lift) <= GroundContact.SUSPENSION_TRAVEL_M + 1e-6, str(lifts))


func test_no_wheel_sinks_driving_from_flat_ground_onto_a_ramp() -> void:
	var vehicle := await _vehicle_before_a_ramp()
	var deepest_sink_m := 0.0

	vehicle.command(1.5, 0.0)
	for frame in 6 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		for wheel in ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]:
			deepest_sink_m = maxf(deepest_sink_m, _sink_m(vehicle, vehicle.get_node(wheel)))

	assert_true(vehicle.global_position.z > RAMP_START_Z, "climbed onto the ramp")
	assert_true(deepest_sink_m < ALLOWED_SINK_M, "deepest wheel sink %.3f m" % deepest_sink_m)


func _sink_m(vehicle: Vehicle, wheel: Node3D) -> float:
	var centre := wheel.global_position
	var query := PhysicsRayQueryParameters3D.create(
		centre + Vector3.UP * 2.0, centre + Vector3.DOWN * 3.0
	)
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return hit["position"].y - (centre.y - vehicle.spec.wheel_radius_m)


func _vehicle_before_a_ramp() -> Vehicle:
	var directory := PackFixtures.fresh_directory("ground_ramp")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	var ground := Node3D.new()
	add_child(ground)
	ground.add_child(
		_slab(Vector3(40.0, 1.0, 40.0), Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))
	)
	var ramp_length := 20.0
	var tilt := Basis(Vector3.RIGHT, -deg_to_rad(RAMP_DEG))
	var ramp_centre := (
		Vector3(0.0, 0.0, RAMP_START_Z) + tilt * Vector3(0.0, -0.5, ramp_length * 0.5)
	)
	ground.add_child(_slab(Vector3(40.0, 1.0, ramp_length), Transform3D(tilt, ramp_centre)))
	var vehicle := Vehicle.new()
	ground.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	await wait_physics_frames(2)
	return vehicle


func _slab(size: Vector3, placed: Transform3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.transform = placed
	return body
