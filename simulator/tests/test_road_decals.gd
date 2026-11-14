extends TestCase
## A track pack's decals: read from pack.json and laid on the ground of their tiles.

const PLACED := [
	{
		"kind": "stain",
		"position_m": [5.0, 2.0, 0.1],
		"yaw_deg": 90.0,
		"size_m": [3.0, 1.5],
		"opacity": 0.6,
	}
]


func test_reads_the_decals_of_the_pack() -> void:
	var track := _track("reads", PackFixtures.decals_manifest("marked"), PLACED)

	assert_eq(track.decals.kinds.size(), 1)
	assert_eq(track.decals.kinds[0].id, "stain")
	assert_true(track.decals.kinds[0].textures_path.ends_with("decals/stain"))
	assert_almost_eq(track.decals.draw_distance_m, 50.0)


func test_refuses_decals_a_pack_gets_wrong() -> void:
	var cases := {
		"marked: track.decals.kinds[0].textures names decals/none_albedo.png, which is not in the pack":
		func(decals): decals["kinds"][0]["textures"] = "decals/none",
		"marked: track.decals.draw_distance_m is out of range":
		func(decals): decals["draw_distance_m"] = 0.0,
	}
	for reason in cases:
		var manifest := PackFixtures.decals_manifest("marked")
		cases[reason].call(manifest["track"]["decals"])
		var directory := PackFixtures.fresh_directory("refuses_decals")
		var pack_directory := PackFixtures.write_pack(directory, manifest)
		PackFixtures.write_decals_files(pack_directory, PLACED)

		assert_eq(PackLibrary.scan([directory]).load_track("marked"), {"error": reason})


func test_refuses_a_decal_of_no_kind_the_pack_names() -> void:
	var placed := PLACED.duplicate(true)
	placed[0]["kind"] = "manhole"
	var track := _track("no_kind", PackFixtures.decals_manifest("marked"), placed)

	assert_eq(
		TrackWorld.load_world(track),
		{"error": "marked: tile a: a.json: decals[0].kind is not one of stain"}
	)


func test_lays_a_decal_where_the_tile_lists_it() -> void:
	var track := _track("lays", PackFixtures.decals_manifest("marked"), PLACED)

	var loaded := TrackWorld.load_world(track)

	var decals: Array[Node] = loaded["world"].get_node("Tile_a/Decals").get_children()
	assert_eq(decals.size(), 1)
	var decal: Decal = decals[0]
	# ROS (x, y, z) is Godot (y, z, x); yaw 90° turns the decal's length along Godot's +X.
	assert_almost_eq(decal.position, Vector3(2.0, 0.1, 5.0), 1e-6)
	assert_almost_eq(decal.basis.z, Vector3(1.0, 0.0, 0.0), 1e-6)
	assert_almost_eq(decal.size, Vector3(1.5, RoadDecals.DEPTH_M, 3.0), 1e-6)
	assert_almost_eq(decal.modulate.a, 0.6, 1e-6)
	assert_true(decal.texture_albedo != null and decal.texture_normal != null, "textures")
	assert_true(decal.distance_fade_enabled, "fades with distance")
	assert_almost_eq(decal.distance_fade_begin + decal.distance_fade_length, 50.0, 1e-6)
	loaded["world"].free()


func test_decals_lie_on_the_ground_only() -> void:
	var track := _track("ground_only", PackFixtures.decals_manifest("marked"), PLACED)

	var loaded := TrackWorld.load_world(track)

	var decal: Decal = loaded["world"].get_node("Tile_a/Decals").get_child(0)
	var ground: MeshInstance3D = loaded["world"].get_node("Tile_a").find_child("Terrain_a")
	assert_eq(decal.cull_mask, RoadDecals.GROUND_LAYER)
	assert_true(ground.layers & RoadDecals.GROUND_LAYER != 0, "the ground takes decals")
	assert_true(ground.layers & 1 != 0, "the ground is still drawn on the first layer")
	loaded["world"].free()


func _track(test_name: String, manifest: Dictionary, placed: Array) -> TrackSpec:
	var directory := PackFixtures.fresh_directory("decals_" + test_name)
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_decals_files(pack_directory, placed)
	return PackLibrary.scan([directory]).load_track(manifest["id"])["track"]
