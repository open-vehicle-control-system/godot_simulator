extends TestCase
## The vehicle rests on its four sprung wheels: each finds its own patch of ground, so none
## sinks where the ground changes slope, and the body follows a slope.

const RAMP_DEG := 15.0
const RAMP_START_Z := 6.0
const ALLOWED_SINK_M := 0.03


func test_stands_pitched_on_a_uniform_slope() -> void:
	var vehicle := await _vehicle_before_a_ramp(Vector3(0.0, 0.0, RAMP_START_Z + 6.0))

	var pitch_deg := rad_to_deg(asin(vehicle.global_basis.z.y))
	# Its weight leans on the rear springs, which pitch it up a little more.
	assert_almost_eq(pitch_deg, RAMP_DEG, 1.0, "nose up the ramp")
	assert_eq(vehicle.wheel_in_contact, [true, true, true, true] as Array[bool])


func test_no_wheel_sinks_driving_from_flat_ground_onto_a_ramp() -> void:
	var vehicle := await _vehicle_before_a_ramp()
	var deepest_sink_m := 0.0

	VehicleFixtures.hold(self, vehicle, 2.0, 0.0)
	for frame in 6 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		for wheel in ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]:
			deepest_sink_m = maxf(deepest_sink_m, _sink_m(vehicle, vehicle.get_node(wheel)))

	assert_true(vehicle.global_position.z > RAMP_START_Z, "climbed onto the ramp")
	assert_true(deepest_sink_m < ALLOWED_SINK_M, "deepest wheel sink %.3f m" % deepest_sink_m)


func _sink_m(vehicle: Vehicle, wheel: Node3D) -> float:
	var centre := wheel.global_position
	var query := PhysicsRayQueryParameters3D.create(
		centre + Vector3.UP * 2.0, centre + Vector3.DOWN * 3.0, 0xFFFFFFFF, [vehicle.get_rid()]
	)
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	return hit["position"].y - (centre.y - vehicle.spec.wheel_radius_m)


func _vehicle_before_a_ramp(at := Vector3.ZERO) -> Vehicle:
	var directory := PackFixtures.fresh_directory("ground_ramp")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var spec: VehicleSpec = PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]
	var ground := Node3D.new()
	add_child(ground)
	ground.add_child(
		_slab(Vector3(40.0, 1.0, 40.0), Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))
	)
	var ramp_length := 20.0
	var ramp_tilt := Basis(Vector3.RIGHT, -deg_to_rad(RAMP_DEG))
	var ramp_centre := (
		Vector3(0.0, 0.0, RAMP_START_Z) + ramp_tilt * Vector3(0.0, -0.5, ramp_length * 0.5)
	)
	ground.add_child(_slab(Vector3(40.0, 1.0, ramp_length), Transform3D(ramp_tilt, ramp_centre)))
	var vehicle := Vehicle.new()
	ground.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	var on_ramp := at.z > RAMP_START_Z
	var tilt := Basis(Vector3.RIGHT, -deg_to_rad(RAMP_DEG)) if on_ramp else Basis.IDENTITY
	at.y = (at.z - RAMP_START_Z) * tan(deg_to_rad(RAMP_DEG)) if on_ramp else 0.0
	vehicle.place(Transform3D(tilt, at))
	await wait_physics_frames(Engine.physics_ticks_per_second)
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
