extends TestCase
## A track's tiles: which are loaded, collide and are freed as the vehicle moves, and the
## ground and obstacles the vehicle meets on them.

const TILE_M := 20.0


func test_a_point_over_a_tile_is_no_distance_from_it() -> void:
	var tile := _tile(Vector2(10.0, -20.0), 20.0)
	var cases := {
		Vector2(15.0, -5.0): 0.0,
		Vector2(40.0, -5.0): 10.0,
		Vector2(34.0, 3.0): 5.0,
	}

	for point in cases:
		assert_almost_eq(TileRing.distance_m(tile, point), cases[point], 1e-6, str(point))


func test_tiles_within_a_radius_come_nearest_first() -> void:
	var tiles: Array[TilesSpec.Tile] = []
	for number in 5:
		var tile := _tile(Vector2(number * 20.0, 0.0), 20.0)
		tile.key = "t%d" % number
		tiles.append(tile)

	var near := TileRing.within(tiles, Vector2(52.0, 10.0), 25.0)

	assert_eq(near.map(func(tile): return tile.key), ["t2", "t3", "t1"])


func test_reads_the_tiles_of_the_pack() -> void:
	var track := _row_track("reads", 3)

	assert_almost_eq(track.tiles.tile_size_m, TILE_M)
	assert_eq(track.tiles.ground_samples(), 3)
	var tile := track.tiles.tiles[1]
	assert_eq(tile.key, "t1")
	assert_almost_eq(tile.corner, Vector2(20.0, -10.0))
	assert_almost_eq(tile.bounds.position, Vector3(20.0, -100.0, -10.0))
	assert_almost_eq(tile.bounds.size, Vector3(20.0, 200.0, 20.0))
	assert_true(tile.path(".glb").ends_with("tiles/t1.glb"))


func test_refuses_tiles_a_pack_gets_wrong() -> void:
	var cases := {
		"row: tiles.json: tile_size_m is out of range": func(index): index["tile_size_m"] = 0.0,
		"row: tiles.json: ground_step_m is out of range": func(index): index["ground_step_m"] = 7.0,
		"row: tiles.json: tiles is out of range": func(index): index["tiles"] = [],
		"row: tiles.json: tiles[0].corner_m is missing or not a list of 2 numbers":
		func(index): index["tiles"][0].erase("corner_m"),
		"row: tiles.json: tiles[0].maps is out of range":
		func(index): index["tiles"][0]["maps"] = ["rivers"],
	}
	for reason in cases:
		var directory := PackFixtures.fresh_directory("tiles_refuses")
		var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("row"))
		PackFixtures.write_tile_row(pack, TILE_M, 2)
		var path := pack.path_join("tiles.json")
		var index: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		cases[reason].call(index)
		FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(index))

		assert_eq(PackLibrary.scan([directory]).load_track("row"), {"error": reason})


func test_the_tiles_around_the_spawn_are_loaded_at_once_the_near_ones_with_collision() -> void:
	var world := _row_world("spawn_load", 8)
	world.start_radius_m = 35.0
	world.collision_radius_m = 15.0

	var problem := world.load_around(Vector3(70.0, 0.0, 0.0))

	assert_eq(problem, "")
	assert_eq(_sorted(world.loaded_keys()), ["t1", "t2", "t3", "t4", "t5"])
	assert_eq(_sorted(world.colliding_keys()), ["t2", "t3", "t4"])
	world.free()


func test_the_collision_of_the_tiles_loaded_at_start_is_made_before_the_first_frame() -> void:
	var world := _row_world("made_at_start", 8)
	world.start_radius_m = 35.0
	world.load_around(Vector3(70.0, 0.0, 0.0))

	add_child(world)

	assert_eq(world.preparing_keys(), [] as Array[String])
	world.free()


func test_the_ground_is_solid_the_moment_its_tile_is_loaded() -> void:
	var world := _row_world("solid_at_once", 4)
	add_child(world)

	world.load_around(Vector3(50.0, 0.0, 0.0))

	# Tile t2 lies 2 m up.
	assert_almost_eq(_ground_below(Vector3(50.0, 0.0, 3.0)), Vector3(50.0, 2.0, 3.0), 1e-4)
	world.queue_free()


func test_the_ground_follows_the_heights_of_its_tile() -> void:
	var directory := PackFixtures.fresh_directory("tiles_heights")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("row"))
	PackFixtures.write_tile_row(pack, TILE_M, 1)
	# Rising 0.1 m per metre towards +X and 0.3 m per metre towards +Z, from the corner.
	var heights := PackedFloat32Array()
	for row in 3:
		for column in 3:
			heights.append(0.1 * column * 10.0 + 0.3 * row * 10.0)
	PackFixtures.write_ground_heights(pack, "t0", heights)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("row")["track"]
	var world: TrackTiles = TrackWorld.load_world(track)["world"]
	add_child(world)

	# The tile's corner is at (0, -10): 4 m along +X and 13 m along +Z from it.
	var hit := _ground_below(Vector3(4.0, 0.0, 3.0), 20.0)

	assert_almost_eq(hit, Vector3(4.0, 0.1 * 4.0 + 0.3 * 13.0, 3.0), 1e-3)
	world.queue_free()


func test_the_ground_is_whole_across_its_patches() -> void:
	var directory := PackFixtures.fresh_directory("tiles_patches")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	# Three patches a side.
	var samples := 2 * GroundPatch.QUADS + 5
	var step_m := 0.25
	var size_m := (samples - 1) * step_m
	PackFixtures.write_tile_index(pack, size_m, step_m, {"a": Vector2.ZERO})
	PackFixtures.write_flat_tile(pack, "a", Vector2.ZERO, size_m, 0.0, "Terrain_a", "")
	# Rising 0.1 m per metre towards +X and 0.3 m per metre towards +Z, from the corner.
	var heights := PackedFloat32Array()
	for row in samples:
		for column in samples:
			heights.append((0.1 * column + 0.3 * row) * step_m)
	PackFixtures.write_ground_heights(pack, "a", heights)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]
	track.move_spawn(Vector3(size_m * 0.5, size_m * 0.5, 0.0), 0.0)
	var world: TrackTiles = TrackWorld.load_world(track)["world"]
	add_child(world)

	var seam_m := GroundPatch.QUADS * step_m
	for x in [1.0, seam_m - 0.01, seam_m, seam_m + 0.01, 2.0 * seam_m, size_m - 0.3]:
		for z in [0.7, seam_m, 2.0 * seam_m + 0.4]:
			var hit := _ground_below(Vector3(x, 0.0, z), 60.0)
			assert_almost_eq(hit, Vector3(x, 0.1 * x + 0.3 * z, z), 1e-3)
	world.queue_free()


func test_tiles_stream_in_around_what_is_followed_and_are_freed_far_behind() -> void:
	var world := _row_world("streams", 12)
	_set_radii(world, 30.0, 70.0, 15.0)
	var target := Node3D.new()
	add_child(target)
	add_child(world)
	world.load_around(Vector3.ZERO)
	world.follow(target)

	target.position = Vector3(110.0, 0.0, 0.0)
	await _settled(world)

	# Within 30 m: loaded. Between 30 and 70 m: kept if it was there. Beyond 70 m: freed.
	assert_eq(_sorted(world.loaded_keys()), ["t4", "t5", "t6"])
	assert_true(world.get_node_or_null("Tile_t0") == null, "the tile left behind is still there")
	target.position = Vector3(150.0, 0.0, 0.0)
	await _settled(world)
	assert_eq(_sorted(world.loaded_keys()), ["t4", "t5", "t6", "t7", "t8"])
	target.queue_free()
	world.queue_free()


func test_only_the_tiles_near_what_is_followed_collide() -> void:
	var world := _row_world("collides_near", 12)
	_set_radii(world, 60.0, 90.0, 15.0)
	world.collision_drop_radius_m = 25.0
	var target := Node3D.new()
	add_child(target)
	add_child(world)
	world.load_around(Vector3.ZERO)
	world.follow(target)
	target.position = Vector3(110.0, 0.0, 0.0)
	await _settled(world)

	assert_eq(_sorted(world.colliding_keys()), ["t4", "t5", "t6"])
	assert_almost_eq(_ground_below(Vector3(110.0, 0.0, 0.0), 20.0), Vector3(110.0, 5.0, 0.0), 1e-4)
	assert_eq(_ground_below(Vector3(170.0, 0.0, 0.0), 20.0), Vector3.INF, "t8 collides from afar")
	# 33 m on, t5 is still within the 25 m its collision is kept for; t4 is not.
	target.position = Vector3(143.0, 0.0, 0.0)
	await wait_physics_frames(2)
	assert_eq(_sorted(world.colliding_keys()), ["t5", "t6", "t7"])
	target.queue_free()
	world.queue_free()


func test_ground_is_there_at_once_where_the_vehicle_is_moved_to() -> void:
	var world := _row_world("moved_to", 12)
	_set_radii(world, 30.0, 70.0, 15.0)
	var target := Node3D.new()
	add_child(target)
	add_child(world)
	world.load_around(Vector3.ZERO)
	world.follow(target)

	target.position = Vector3(210.0, 0.0, 0.0)
	await wait_physics_frames(2)

	assert_almost_eq(_ground_below(Vector3(210.0, 0.0, 0.0), 20.0), Vector3(210.0, 10.0, 0.0), 1e-4)
	target.queue_free()
	world.queue_free()


func test_a_vehicle_at_speed_always_has_collision_under_it() -> void:
	var directory := PackFixtures.fresh_directory("tiles_at_speed")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("row"))
	PackFixtures.write_tile_row(pack, TILE_M, 40, 0.0)
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var library := PackLibrary.scan([directory])
	var spec: VehicleSpec = library.load_vehicle("small_car")["vehicle"]
	var world: TrackTiles = TrackTiles.create(library.load_track("row")["track"])["tiles"]
	_set_radii(world, 60.0, 90.0, 25.0)
	add_child(world)
	world.load_around(Vector3(5.0, 0.0, 0.0))
	var vehicle := Vehicle.new()
	world.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	# Heading +X, which the tiles lie along.
	vehicle.global_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(5.0, 0.0, 0.0))
	world.follow(vehicle)

	vehicle.command(90.0, 0.0)
	var frames_off_the_ground := 0
	for frame in 8 * Engine.physics_ticks_per_second:
		await get_tree().physics_frame
		if _ground_below(vehicle.global_position + Vector3.UP, 5.0) == Vector3.INF:
			frames_off_the_ground += 1

	assert_true(vehicle.global_position.x > 700.0, "it drove %s" % vehicle.global_position)
	assert_eq(frames_off_the_ground, 0)
	world.queue_free()


func test_a_mesh_that_is_not_ground_is_solid_where_it_is_drawn() -> void:
	var directory := PackFixtures.fresh_directory("tiles_obstacle")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	# The flat world's `Ground` is a mesh no terrain rule covers, 3 m above its height grid.
	var corner := Vector2(-10.0, -10.0)
	PackFixtures.write_tile_index(pack, 20.0, 10.0, {"a": corner})
	PackFixtures.write_flat_tile(pack, "a", corner, 20.0, 3.0, "Ground", "")
	var level := PackedFloat32Array()
	level.resize(9)
	PackFixtures.write_ground_heights(pack, "a", level)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]
	var world: TrackTiles = TrackWorld.load_world(track)["world"]
	add_child(world)

	assert_almost_eq(_ground_below(Vector3(4.0, 5.0, -6.0), 20.0), Vector3(4.0, 3.0, -6.0), 1e-4)
	world.queue_free()


func test_obstacles_too_many_for_one_shape_are_all_solid() -> void:
	var directory := PackFixtures.fresh_directory("tiles_many_obstacles")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat"))
	PackFixtures.write_slabs_tile(pack, [2.0, 5.0, 8.0], TileLoader.OBSTACLE_LOT_FACES)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("flat")["track"]
	var world: TrackTiles = TrackWorld.load_world(track)["world"]
	add_child(world)

	for height_m in [8.0, 5.0, 2.0]:
		var hit := _ground_below(Vector3(3.0, height_m - 9.0, 4.0), 10.0)
		assert_almost_eq(hit, Vector3(3.0, height_m, 4.0), 1e-4)
	var solid: ShapeBody = world.get_node("Tile_a/Collision/Solid")
	assert_eq(solid.shape_count(), 3, "a shape per slab")
	world.queue_free()


func test_the_far_terrain_shows_where_no_tile_is_loaded() -> void:
	var directory := PackFixtures.fresh_directory("tiles_far")
	var manifest := PackFixtures.track_manifest("row")
	manifest["track"]["far"] = {"scene": "far.glb", "photo": "far.jpg"}
	var pack := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_tile_row(pack, TILE_M, 12)
	PackFixtures.write_far_terrain(pack, range(12).map(func(number): return "t%d" % number))
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("row")["track"]
	var world: TrackTiles = TrackTiles.create(track)["tiles"]
	_set_radii(world, 30.0, 70.0, 15.0)
	var target := Node3D.new()
	add_child(target)
	add_child(world)
	world.load_around(Vector3.ZERO)
	world.follow(target)
	var far: FarTerrain = world.get_node("FarTerrain")

	assert_true(not far.is_shown("t0"), "far terrain under a loaded tile")
	assert_true(far.is_shown("t6"), "no far terrain where no tile is loaded")
	target.position = Vector3(130.0, 0.0, 0.0)
	await _settled(world)
	assert_true(far.is_shown("t0"), "no far terrain where the tile was freed")
	assert_true(not far.is_shown("t6"), "far terrain under a tile that streamed in")
	target.queue_free()
	world.queue_free()


func test_a_tile_whose_files_are_wrong_is_reported_and_left_out() -> void:
	var track := _row_track("wrong_tile", 4)
	FileAccess.open(track.directory.path_join("tiles/t1.ground.f32"), FileAccess.WRITE).store_8(0)
	var world: TrackTiles = TrackTiles.create(track)["tiles"]

	var problem := world.load_around(Vector3(30.0, 0.0, 0.0))

	assert_eq(problem, "row: tile t1: t1.ground.f32 does not hold 3 by 3 heights")
	assert_true(not world.loaded_keys().has("t1"))
	world.free()


func _tile(corner: Vector2, size_m: float) -> TilesSpec.Tile:
	var tile := TilesSpec.Tile.new()
	tile.corner = corner
	tile.bounds = AABB(Vector3(corner.x, 0.0, corner.y), Vector3(size_m, 1.0, size_m))
	return tile


func _row_track(test_name: String, count: int) -> TrackSpec:
	var directory := PackFixtures.fresh_directory("tiles_" + test_name)
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("row"))
	PackFixtures.write_tile_row(pack, TILE_M, count)
	return PackLibrary.scan([directory]).load_track("row")["track"]


func _row_world(test_name: String, count: int) -> TrackTiles:
	## A row of tiles, none loaded, with radii that hold a few of them.
	var world: TrackTiles = TrackTiles.create(_row_track(test_name, count))["tiles"]
	_set_radii(world, 30.0, 70.0, 15.0)
	return world


func _set_radii(world: TrackTiles, load_m: float, drop_m: float, collision_m: float) -> void:
	world.load_radius_m = load_m
	world.drop_radius_m = drop_m
	world.collision_radius_m = collision_m
	world.collision_drop_radius_m = collision_m
	world.start_radius_m = collision_m


func _settled(world: TrackTiles) -> void:
	## Waits until every tile around what `world` follows is in the scene and those left
	## behind are freed.
	for frame in 600:
		await get_tree().process_frame
		if frame > 60 and world.is_settled():
			return
	fail("the tiles did not settle")


func _ground_below(from: Vector3, reach_m := 10.0) -> Vector3:
	## Where a ray straight down from `reach_m` above `from` meets collision; INF where none.
	var top := Vector3(from.x, from.y + reach_m, from.z)
	var query := PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * 2.0 * reach_m)
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)
	return hit.get("position", Vector3.INF)


func _sorted(keys: Array[String]) -> Array:
	var sorted := Array(keys)
	sorted.sort_custom(func(first, second): return first.naturalnocasecmp_to(second) < 0)
	return sorted
