extends TestCase
## Trees in clusters, the silhouettes that cast their shadows, the canopy that stands for
## them from afar, and the haze.

const TREES := {
	"impostors":
	[{"atlas": "fir.dds", "views": 2, "width_m": 6.0, "height_m": 18.0, "kind": "conifer"}],
}


func test_a_batch_stands_at_its_centre_and_is_drawn_as_told() -> void:
	var batch := InstanceBatch.new("Copies", BoxMesh.new())
	batch.centre = Vector3(100.0, 5.0, -40.0)
	batch.visible_within_m = 300.0
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	batch.add(Transform3D(Basis.IDENTITY, Vector3(104.0, 6.0, -43.0)))

	var drawn := batch.instantiate()

	assert_almost_eq(drawn.position, Vector3(100.0, 5.0, -40.0))
	assert_eq(drawn.multimesh.instance_count, 1)
	assert_almost_eq(drawn.visibility_range_end, 300.0)
	assert_eq(drawn.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	drawn.free()


func test_opaque_cells_are_covered_once_by_rectangles() -> void:
	var opaque := BitMap.new()
	opaque.create(Vector2i(6, 4))
	# Rows 0 and 1 hold the same run, row 2 two runs, row 3 nothing.
	opaque.set_bit_rect(Rect2i(1, 0, 3, 2), true)
	opaque.set_bit(0, 2, true)
	opaque.set_bit_rect(Rect2i(4, 2, 2, 1), true)

	var rectangles := Forest.opaque_rectangles(opaque, Rect2i(0, 0, 6, 4))

	assert_eq(rectangles, [Rect2i(1, 0, 3, 2), Rect2i(0, 2, 1, 1), Rect2i(4, 2, 2, 1)])
	assert_eq(Forest.opaque_rectangles(opaque, Rect2i(3, 0, 3, 4))[0], Rect2i(3, 0, 1, 2))


func test_a_silhouette_keeps_the_opaque_part_of_each_card() -> void:
	var opaque := BitMap.new()
	opaque.create(Vector2i(4, 2))
	# The first view's upper right cell; the second view's lower half.
	opaque.set_bit(1, 0, true)
	opaque.set_bit_rect(Rect2i(2, 1, 2, 1), true)

	var silhouette := Forest.silhouette_mesh(opaque, 2, 0.5)

	var corners: PackedVector3Array = silhouette.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_eq(corners.size(), 12)
	var first := AABB(corners[0], Vector3.ZERO)
	for corner in range(1, 6):
		first = first.expand(corners[corner])
	# Card 0 runs along z, 0.5 wide: its right half, its upper half.
	assert_almost_eq(first.position, Vector3(0.0, 0.5, 0.0), 1e-5)
	assert_almost_eq(first.size, Vector3(0.0, 0.5, 0.25), 1e-5)
	var second := AABB(corners[6], Vector3.ZERO)
	for corner in range(7, 12):
		second = second.expand(corners[corner])
	# Card 1 runs along x: its whole width, its lower half.
	assert_almost_eq(second.position, Vector3(-0.25, 0.0, 0.0), 1e-5)
	assert_almost_eq(second.size, Vector3(0.5, 0.5, 0.0), 1e-5)


func test_nothing_opaque_makes_no_silhouette() -> void:
	var opaque := BitMap.new()
	opaque.create(Vector2i(4, 2))

	assert_eq(Forest.silhouette_mesh(opaque, 2, 0.5), null)


func test_an_atlas_is_opaque_where_its_alpha_is() -> void:
	var atlas := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
	atlas.fill_rect(Rect2i(0, 0, 32, 64), Color(0.1, 0.4, 0.1, 1.0))
	atlas.generate_mipmaps()

	var opaque := Forest.opaque_cells(atlas, 4)

	assert_eq(opaque.get_size(), Vector2i(4, Forest.SILHOUETTE_ROWS))
	assert_true(opaque.get_bit(0, 5) and opaque.get_bit(1, 20), "the opaque half")
	assert_true(not opaque.get_bit(2, 5) and not opaque.get_bit(3, 20), "the clear half")


func test_trees_are_drawn_without_shadows_which_their_silhouettes_cast() -> void:
	var world := _world_with_trees("shadows", TREES)

	var trees: MultiMeshInstance3D = world.get_node("Tile_a/Trees 0 at 0 0")
	var shadows: MultiMeshInstance3D = world.get_node("Tile_a/Tree shadows 0 at 0 0")
	assert_eq(trees.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_eq(shadows.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	assert_eq(shadows.multimesh.instance_count, trees.multimesh.instance_count)
	assert_almost_eq(
		shadows.visibility_range_end, TrackWorld.SHADOW_DISTANCE_M + Forest.CLUSTER_REACH_M
	)
	assert_almost_eq(trees.visibility_range_end, 0.0, 1e-6, "drawn at any distance")
	assert_true(not world.has_node("Canopy"))
	world.free()


func test_with_a_canopy_trees_are_drawn_up_to_where_it_stands_for_them() -> void:
	var trees := TREES.duplicate(true)
	trees["canopy"] = {"scene": "canopy.glb", "from_m": 400.0}

	var world := _world_with_trees("canopy", trees)

	var drawn: MultiMeshInstance3D = world.get_node("Tile_a/Trees 0 at 0 0")
	assert_almost_eq(drawn.visibility_range_end, 400.0 + Forest.CLUSTER_REACH_M)
	var material: ShaderMaterial = drawn.multimesh.mesh.surface_get_material(0)
	assert_almost_eq(material.get_shader_parameter("gone_at_m"), 400.0)
	assert_almost_eq(material.get_shader_parameter("fades_from_m"), 320.0)
	var piece: MeshInstance3D = world.get_node("Canopy").find_child("Canopy_1", true, false)
	var canopy: ShaderMaterial = piece.material_override
	assert_almost_eq(canopy.get_shader_parameter("rises_from_m"), 240.0)
	assert_almost_eq(canopy.get_shader_parameter("risen_at_m"), 320.0)
	# A piece 2 m wide is not drawn while all of it still lies under the ground.
	assert_almost_eq(piece.visibility_range_begin, 240.0 - sqrt(2.0), 1e-3)
	assert_eq(piece.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	assert_almost_eq(piece.position, Vector3(500.0, 20.0, 0.0), 1e-4)
	world.free()


func test_refuses_a_canopy_a_pack_gets_wrong() -> void:
	var cases := {
		"canopy_missing":
		[{"scene": "none.glb", "from_m": 400.0}, "trees.canopy.scene names none.glb"],
		"canopy_near": [{"scene": "canopy.glb", "from_m": 0.0}, "trees.canopy.from_m"],
	}
	for id: String in cases:
		var manifest := PackFixtures.track_manifest(id)
		manifest["track"]["trees"] = TREES.duplicate(true)
		manifest["track"]["trees"]["canopy"] = cases[id][0]
		manifest["track"]["far"] = {"scene": "far.glb", "photo": "far.jpg"}
		var directory := PackFixtures.fresh_directory(id)
		var pack := PackFixtures.write_pack(directory, manifest)
		PackFixtures.write_flat_world(pack, 20.0)
		PackFixtures.write_dds(pack, "fir.dds", Color.GREEN)
		PackFixtures.write_canopy(pack, [Vector3.ZERO])
		PackFixtures.write_far_terrain(pack, ["a"])

		var found := PackLibrary.scan([directory]).load_track(id)

		assert_true(found.get("error", "").contains(cases[id][1]), "%s: %s" % [id, found])


func test_a_canopy_needs_the_far_terrains_photo() -> void:
	var manifest := PackFixtures.track_manifest("no_far")
	manifest["track"]["trees"] = TREES.duplicate(true)
	manifest["track"]["trees"]["canopy"] = {"scene": "canopy.glb", "from_m": 400.0}
	var directory := PackFixtures.fresh_directory("no_far")
	var pack := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack, 20.0)
	PackFixtures.write_dds(pack, "fir.dds", Color.GREEN)
	PackFixtures.write_canopy(pack, [Vector3.ZERO])

	var found := PackLibrary.scan([directory]).load_track("no_far")

	assert_true(found.get("error", "").contains("trees.canopy needs track.far"), str(found))


func test_the_haze_is_as_thick_as_the_packs_visibility_tells() -> void:
	var manifest := PackFixtures.track_manifest("hazy")
	manifest["track"]["haze"] = {"visibility_m": 8000.0}
	var directory := PackFixtures.fresh_directory("hazy")
	PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("hazy")["track"]

	var environment: Environment = _lit_environment(track)

	assert_true(environment.fog_enabled)
	# A black object 8 km away keeps 2% of its contrast.
	assert_almost_eq(exp(-environment.fog_density * 8000.0), 0.02, 1e-6)
	# 100 m away it keeps over 95%.
	assert_true(exp(-environment.fog_density * 100.0) > 0.95)


func test_a_track_without_haze_has_clear_air() -> void:
	var directory := PackFixtures.fresh_directory("clear")
	var manifest := PackFixtures.track_manifest("clear")
	PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("clear")["track"]

	var environment: Environment = _lit_environment(track)

	assert_almost_eq(exp(-environment.fog_density * TrackWorld.DEFAULT_VISIBILITY_M), 0.02, 1e-6)


func test_refuses_a_visibility_that_is_no_distance() -> void:
	var manifest := PackFixtures.track_manifest("fogged")
	manifest["track"]["haze"] = {"visibility_m": 0.0}
	var directory := PackFixtures.fresh_directory("fogged")
	PackFixtures.write_flat_world(PackFixtures.write_pack(directory, manifest), 20.0)

	var found := PackLibrary.scan([directory]).load_track("fogged")

	assert_true(found.get("error", "").contains("track.haze.visibility_m"), str(found))


func _world_with_trees(id: String, trees: Dictionary) -> TrackTiles:
	## The world of a flat track with two firs east of its origin, drawn as `trees` tells.
	var manifest := PackFixtures.track_manifest(id)
	manifest["track"]["trees"] = trees
	manifest["track"]["far"] = {"scene": "far.glb", "photo": "far.jpg"}
	var directory := PackFixtures.fresh_directory(id)
	var pack := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_flat_world(pack, 20.0)
	PackFixtures.write_dds(pack, "fir.dds", Color.GREEN)
	PackFixtures.write_canopy(pack, [Vector3.ZERO, Vector3(500.0, 20.0, 0.0)])
	PackFixtures.write_far_terrain(pack, ["a"])
	var standing := {"conifer": [[5.0, 2.0, 1.0, 12.0], [6.0, 3.0, 0.5, 20.0]], "broadleaf": []}
	PackFixtures.write_tile_objects(pack, "a", {"trees": standing})
	var track: TrackSpec = PackLibrary.scan([directory]).load_track(id)["track"]
	return TrackWorld.load_world(track)["world"]


static func _lit_environment(track: TrackSpec) -> Environment:
	## The track's lighting environment; its sun, which no test adds to a scene, freed.
	var lighting := TrackWorld.lighting(track)
	lighting["sun"].free()
	return lighting["environment"]
