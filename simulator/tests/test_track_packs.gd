extends TestCase
## Track packs: the world around the spawn, its collision, the spawn pose and the sky.


func test_loads_the_world_with_collision_on_its_ground() -> void:
	var track := _flat_track("collision", PackFixtures.track_manifest("flat"))

	var loaded := TrackWorld.load_world(track)
	add_child(loaded["world"])
	await wait_physics_frames(2)

	var hit := _ray_down(Vector3(3.0, 10.0, -4.0))
	assert_almost_eq(hit.get("position", Vector3.INF), Vector3(3.0, 0.0, -4.0), 1e-4)
	loaded["world"].queue_free()


func test_reports_a_tile_that_does_not_load() -> void:
	var track := _flat_track("no_tile", PackFixtures.track_manifest("flat"))
	DirAccess.remove_absolute(track.directory.path_join("tiles/a.glb"))

	assert_eq(TrackWorld.load_world(track), {"error": "flat: tile a: a.glb does not load"})


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

	var environment: Environment = _lit_environment(track)

	assert_true(environment.sky.sky_material is ProceduralSkyMaterial)


func test_a_track_with_a_sky_shows_its_panorama() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["sky"] = "sky.png"
	var directory := PackFixtures.fresh_directory("panorama_sky")
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack_directory, 20.0)
	Image.create(8, 4, false, Image.FORMAT_RGB8).save_png(pack_directory.path_join("sky.png"))
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]

	var environment: Environment = _lit_environment(track)

	assert_true(environment.sky.sky_material is PanoramaSkyMaterial)


func test_the_window_is_lit_indirectly_and_the_world_is_not() -> void:
	var track := _flat_track("indirect", PackFixtures.track_manifest("flat"))
	var world_lighting: Environment = _lit_environment(track)

	var window_lighting := TrackWorld.window_lighting(world_lighting, track)

	assert_true(window_lighting.ssil_enabled, "the window")
	assert_almost_eq(window_lighting.ssil_intensity, 1.0)
	assert_true(not world_lighting.ssil_enabled, "the world, as the stereo cameras see it")
	assert_true(not window_lighting.ssr_enabled and not world_lighting.ssr_enabled)
	assert_eq(window_lighting.sky, world_lighting.sky)


func test_a_pack_sets_how_strong_the_indirect_light_is() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["indirect_light"] = {"strength": 1.5}
	var track := _flat_track("indirect_strength", manifest)

	var lit := TrackWorld.window_lighting(_lit_environment(track), track)

	assert_almost_eq(lit.ssil_intensity, 1.5)


func test_a_pack_does_without_indirect_light() -> void:
	var manifest := PackFixtures.track_manifest("flat")
	manifest["track"]["indirect_light"] = {"strength": 0.0}
	var track := _flat_track("indirect_none", manifest)

	var lit := TrackWorld.window_lighting(_lit_environment(track), track)

	assert_true(not lit.ssil_enabled)


func test_refuses_an_indirect_light_out_of_range() -> void:
	for strength in [-0.5, 4.5, "strong"]:
		var manifest := PackFixtures.track_manifest("flat")
		manifest["track"]["indirect_light"] = {"strength": strength}
		var directory := PackFixtures.fresh_directory("indirect_refused")
		PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)

		var found := PackLibrary.scan([directory]).load_track("flat")

		assert_true(found.get("error", "").contains("track.indirect_light.strength"), str(found))


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
	PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)

	var found := PackLibrary.scan([directory]).load_track("flat")

	assert_eq(found, {"error": "flat: track.sky names sky.hdr, which is not in the pack"})


static func _lit_environment(track: TrackSpec) -> Environment:
	## The track's lighting environment; its sun, which no test adds to a scene, freed.
	var lighting := TrackWorld.lighting(track)
	lighting["sun"].free()
	return lighting["environment"]
