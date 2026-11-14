extends TestCase
## Track packs with one world scene: the world, its collision, the spawn pose and the sky.


func test_loads_the_world_with_collision_on_its_ground() -> void:
	var track := _flat_track("collision", PackFixtures.track_manifest("flat"))

	var loaded := TrackWorld.load_world(track)
	add_child(loaded["world"])
	await wait_physics_frames(2)

	var hit := _ray_down(Vector3(3.0, 10.0, -4.0))
	assert_almost_eq(hit.get("position", Vector3.INF), Vector3(3.0, 0.0, -4.0), 1e-4)
	loaded["world"].queue_free()


func test_reports_a_world_that_does_not_load() -> void:
	var directory := PackFixtures.fresh_directory("no_world")
	PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]

	assert_eq(TrackWorld.load_world(track), {"error": "flat: world.glb does not load"})


func test_places_the_spawn_pose_from_ros_position_and_yaw() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["spawn"] = {"position_m": [5.0, 2.0, 1.0], "yaw_deg": 90.0}
	var track := _flat_track("spawn", manifest)

	var spawn := track.spawn_transform()

	assert_almost_eq(spawn.origin, Vector3(2.0, 1.0, 5.0), 1e-6)
	# ROS yaw 90° turns forward (x) to the left (y): Godot +Z towards +X.
	assert_almost_eq(spawn.basis.z, Vector3(1.0, 0.0, 0.0), 1e-6)


func test_a_track_without_a_sky_gets_a_procedural_one() -> void:
	var track := _flat_track("procedural_sky", PackFixtures.track_manifest("flat"))

	var environment: Environment = TrackWorld.lighting(track)["environment"]

	assert_true(environment.sky.sky_material is ProceduralSkyMaterial)


func test_a_track_with_a_sky_shows_its_panorama() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["sky"] = "sky.png"
	var directory := PackFixtures.fresh_directory("panorama_sky")
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	Image.create(8, 4, false, Image.FORMAT_RGB8).save_png(pack_directory.path_join("sky.png"))
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]

	var environment: Environment = TrackWorld.lighting(track)["environment"]

	assert_true(environment.sky.sky_material is PanoramaSkyMaterial)


func _flat_track(test_name: String, manifest: Dictionary) -> TrackSpec:
	var directory := PackFixtures.fresh_directory(test_name)
	PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)
	return PackLibrary.scan([directory]).load_track(manifest["id"])["track"]


func _ray_down(from: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 20.0)
	return get_viewport().world_3d.direct_space_state.intersect_ray(query)


func test_refuses_a_sky_that_is_not_there() -> void:
	var directory := PackFixtures.fresh_directory("missing_sky")
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["sky"] = "sky.hdr"
	PackFixtures.write_pack(directory, manifest)

	var found := PackLibrary.scan([directory]).load_track("flat")

	assert_eq(found, {"error": "flat: track.sky names sky.hdr, which is not in the pack"})
