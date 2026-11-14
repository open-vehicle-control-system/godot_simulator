extends TestCase
## The vehicle stops against what it hits (walls, buildings, trees) instead of driving through.

# The fixture's body reaches 1.95 m ahead of its origin.
const BODY_AHEAD_M := 1.95
const WALL_FACE_Z := 10.0
# The fixture's body starts 0.35 m above the ground.
const BODY_BOTTOM_M := 0.35

var _world: Node3D


func test_stops_against_a_wall() -> void:
	var vehicle := await _vehicle_facing_a_wall("stops")

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	var front_z := vehicle.global_position.z + BODY_AHEAD_M
	assert_true(
		front_z <= WALL_FACE_Z + 0.01, "front at %.3f, wall at %.1f" % [front_z, WALL_FACE_Z]
	)
	assert_true(front_z > WALL_FACE_Z - 0.3, "stopped at the wall, not short: %.3f" % front_z)
	assert_eq(vehicle.speed_m_s, 0.0)


func test_odometer_stops_with_the_vehicle() -> void:
	var vehicle := await _vehicle_facing_a_wall("odometer")

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	assert_almost_eq(vehicle.odometer_m, vehicle.global_position.z, 0.05)


func test_backs_away_from_a_wall_it_touches() -> void:
	var vehicle := await _vehicle_facing_a_wall("backs_away")
	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)
	var against_wall_z := vehicle.global_position.z

	vehicle.command(-2.0, 0.0)
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_true(vehicle.global_position.z < against_wall_z - 1.0, "backed off the wall")


func test_stops_against_a_tree() -> void:
	var vehicle := await _vehicle_on_flat_ground("tree")
	vehicle.get_parent().add_child(Forest.trunks([[10.0, 0.0, 0.0, 12.0]]))
	await wait_physics_frames(2)

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	var trunk_face_z := 10.0 - TreeTrunks.RADIUS_M
	assert_true(
		vehicle.global_position.z + BODY_AHEAD_M <= trunk_face_z + 0.01, "stopped at the trunk"
	)
	assert_eq(vehicle.speed_m_s, 0.0)


func test_stops_against_a_sign_post() -> void:
	var vehicle := await _vehicle_on_flat_ground("post")
	var posts := PostBodies.new()
	posts.add_post(Vector3(0.0, 0.0, 10.0), 0.076, 2.3)
	vehicle.get_parent().add_child(posts)
	await wait_physics_frames(2)

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	var front_z := vehicle.global_position.z + BODY_AHEAD_M
	assert_true(front_z <= 10.0 - 0.038 + 0.01, "stopped at the post: front at %.3f" % front_z)
	assert_true(front_z > 9.5, "stopped at the post, not short: %.3f" % front_z)
	assert_eq(vehicle.speed_m_s, 0.0)


func test_does_not_pass_a_wall_its_body_is_already_into() -> void:
	var vehicle := await _vehicle_facing_a_wall("already_into")
	var into_wall_z := WALL_FACE_Z - BODY_AHEAD_M + 0.05
	vehicle.global_position.z = into_wall_z

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_almost_eq(vehicle.global_position.z, into_wall_z, 1e-3)
	assert_eq(vehicle.speed_m_s, 0.0)


func test_stops_against_a_wall_where_the_ground_reaches_its_body() -> void:
	var vehicle := await _vehicle_over_a_ridge("wall", BODY_BOTTOM_M + 0.15)

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(3 * Engine.physics_ticks_per_second)

	var front_z := vehicle.global_position.z + BODY_AHEAD_M
	assert_true(front_z <= WALL_FACE_Z + 0.01, "front at %.3f" % front_z)
	assert_true(front_z > WALL_FACE_Z - 0.3, "stopped at the wall, not short: %.3f" % front_z)


func test_ground_reaching_its_body_does_not_stop_it() -> void:
	var vehicle := await _vehicle_over_a_ridge("free", BODY_BOTTOM_M + 0.15)

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_true(vehicle.global_position.z > 4.5, "drove %.2f m" % vehicle.global_position.z)


func test_drives_over_its_own_ground() -> void:
	var vehicle := await _vehicle_on_flat_ground("ground")

	vehicle.command(5.0, 0.0)
	await wait_physics_frames(Engine.physics_ticks_per_second)

	assert_almost_eq(vehicle.speed_m_s, 5.0, 1e-6)
	assert_true(vehicle.global_position.z > 4.5, "the ground never blocks it")


func _vehicle_facing_a_wall(test_name: String) -> Vehicle:
	var vehicle := await _vehicle_on_flat_ground("wall_" + test_name)
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 3.0, 1.0)
	shape.shape = box
	wall.add_child(shape)
	wall.position = Vector3(0.0, 1.5, WALL_FACE_Z + 0.5)
	vehicle.get_parent().add_child(wall)
	await wait_physics_frames(2)
	return vehicle


func _vehicle_over_a_ridge(test_name: String, ridge_height_m: float) -> Vehicle:
	## On a tile whose ground rises between the wheels, facing the tile's wall.
	var directory := PackFixtures.fresh_directory("obstacles_ridge_" + test_name)
	var track_pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("ridge"))
	PackFixtures.write_ridge_world(track_pack, ridge_height_m, WALL_FACE_Z)
	return await _vehicle_in(directory, "ridge")


func _vehicle_on_flat_ground(test_name: String) -> Vehicle:
	var directory := PackFixtures.fresh_directory("obstacles_" + test_name)
	var track_pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	PackFixtures.write_flat_world(track_pack, 100.0)
	return await _vehicle_in(directory, "flat")


func _vehicle_in(directory: String, track_id: String) -> Vehicle:
	## A small car at the origin of the track `track_id` written in `directory`.
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var spec: VehicleSpec = library.load_vehicle("small_car")["vehicle"]
	# The world of the test before would stand in this one's way.
	if _world != null:
		_world.free()
	_world = TrackWorld.load_world(library.load_track(track_id)["track"])["world"]
	add_child(_world)
	var vehicle := Vehicle.new()
	_world.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	await wait_physics_frames(1)
	return vehicle
