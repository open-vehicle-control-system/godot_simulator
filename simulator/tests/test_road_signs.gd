extends TestCase
## A track pack's road signs and signals: read from pack.json and stood in the world.

const PLACED := {
	"posts": [{"position_m": [5.0, 2.0, 1.0], "height_m": 2.3, "diameter_m": 0.076}],
	"plates":
	[{"face": "square", "position_m": [4.9, 2.0, 2.8], "yaw_deg": 90.0, "source": "tagged"}],
	"signals":
	[{"position_m": [8.0, -3.0, 2.75], "yaw_deg": 180.0, "phase": 0.5, "source": "tagged"}],
}


func test_reads_the_signs_of_the_pack() -> void:
	var track := _track("reads", PackFixtures.signs_manifest("signed"), PLACED)

	assert_true(track.signs.placed_path.ends_with("signs.json"))
	assert_eq(track.signs.faces.size(), 1)
	assert_true(track.signs.face("square").image_path.ends_with("signs/square.png"))
	assert_eq(track.signs.face("square").outline[2], Vector2(0.3, 0.3))
	assert_almost_eq(track.signs.lens_diameter_m, 0.2)
	assert_almost_eq(track.signs.amber_s, 3.0)


func test_refuses_signs_a_pack_gets_wrong() -> void:
	var cases := {
		"signed: track.signs.placed names placed.json, which is not in the pack":
		func(signs): signs["placed"] = "placed.json",
		"signed: track.signs.faces[0].image names signs/none.png, which is not in the pack":
		func(signs): signs["faces"][0]["image"] = "signs/none.png",
		"signed: track.signs.faces[0].outline_m is out of range":
		func(signs): signs["faces"][0]["outline_m"] = [[0.0, 0.0], [1.0, 0.0]],
		"signed: track.signs.signal.lens_diameter_m is out of range":
		func(signs): signs["signal"]["lens_diameter_m"] = 0.0,
		"signed: track.signs.signal.cycle_s is missing or not a list of 3 numbers":
		func(signs): signs["signal"]["cycle_s"] = [1.0, 2.0],
	}
	for reason in cases:
		var manifest := PackFixtures.signs_manifest("signed")
		cases[reason].call(manifest["track"]["signs"])
		var directory := PackFixtures.fresh_directory("refuses_signs")
		PackFixtures.write_signs_files(PackFixtures.write_pack(directory, manifest), PLACED)

		assert_eq(PackLibrary.scan([directory]).load_track("signed"), {"error": reason})


func test_stands_plates_posts_and_signals_in_a_batch_each() -> void:
	var track := _track("stands", PackFixtures.signs_manifest("signed"), PLACED)

	var loaded := TrackWorld.load_world(track)

	for batch in ["Plates square", "Posts", "Signals"]:
		var stood: MultiMeshInstance3D = loaded["world"].get_node("RoadSigns").get_node(batch)
		assert_eq(stood.multimesh.instance_count, 1, batch)
	loaded["world"].free()


func test_a_plate_faces_the_yaw_the_pack_gives_it() -> void:
	var stood := RoadSigns.facing_transform(Vector3(2.0, 2.8, 4.9), 90.0)

	# ROS yaw 90° faces along the pack's y, Godot's +X.
	assert_almost_eq(stood.origin, Vector3(2.0, 2.8, 4.9), 1e-6)
	assert_almost_eq(stood.basis.z, Vector3(1.0, 0.0, 0.0), 1e-6)


func test_a_post_stands_on_its_foot_at_its_size() -> void:
	var stood := RoadSigns.post_transform(Vector3(2.0, 1.0, 5.0), 0.076, 2.3)

	assert_almost_eq(stood * Vector3(0.5, 1.0, 0.0), Vector3(2.038, 3.3, 5.0), 1e-6)
	var lowest := INF
	for vertex in RoadSigns.post_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		lowest = minf(lowest, vertex.y)
	assert_almost_eq(lowest, 0.0, 1e-6)


func test_a_plate_shows_its_face_to_the_front_across_its_outline() -> void:
	var outline := PackedVector2Array(
		[Vector2(-0.3, -0.2), Vector2(0.3, -0.2), Vector2(0.3, 0.2), Vector2(-0.3, 0.2)]
	)

	var arrays := RoadSigns.plate_mesh(outline).surface_get_arrays(0)

	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var top_right := vertices.find(Vector3(0.3, 0.2, 0.0))
	assert_almost_eq(uvs[top_right], Vector2(1.0, 0.0), 1e-6)
	# Clockwise seen from +Z, where the plate faces: Godot's front.
	var winding := (vertices[1] - vertices[0]).cross(vertices[2] - vertices[0])
	assert_true(winding.z < 0.0, "front faces +Z")


func test_a_post_is_solid() -> void:
	var track := _track("solid", PackFixtures.signs_manifest("signed"), PLACED)
	var loaded := TrackWorld.load_world(track)
	add_child(loaded["world"])
	await wait_physics_frames(2)

	var query := PhysicsRayQueryParameters3D.create(Vector3(2.0, 2.0, 0.0), Vector3(2.0, 2.0, 9.0))
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)

	assert_almost_eq(hit.get("position", Vector3.INF), Vector3(2.0, 2.0, 5.0 - 0.038), 1e-3)
	loaded["world"].queue_free()


func test_refuses_placed_signs_that_name_no_face() -> void:
	var placed := PLACED.duplicate(true)
	placed["plates"][0]["face"] = "round"
	var track := _track("no_face", PackFixtures.signs_manifest("signed"), placed)

	assert_eq(
		TrackWorld.load_world(track),
		{"error": "signed: signs.json: plates[0].face is not one of square"}
	)


func _track(test_name: String, manifest: Dictionary, placed: Dictionary) -> TrackSpec:
	var directory := PackFixtures.fresh_directory("signs_" + test_name)
	var pack_directory := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack_directory, 20.0)
	PackFixtures.write_signs_files(pack_directory, placed)
	return PackLibrary.scan([directory]).load_track(manifest["id"])["track"]
