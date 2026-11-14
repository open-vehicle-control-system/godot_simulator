extends TestCase
## The tiles around the vehicle, all in the scene before each frame of a recording.

const TILE_M := 20.0


func test_every_tile_within_the_load_radius_is_there_the_frame_the_vehicle_arrives() -> void:
	var directory := PackFixtures.fresh_directory("tiles_at_once")
	var pack := PackFixtures.write_pack(directory, PackFixtures.track_manifest("row"))
	PackFixtures.write_tile_row(pack, TILE_M, 12, 0.0)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("row")["track"]
	var world: TrackTiles = TrackTiles.create(track)["tiles"]
	world.load_radius_m = 45.0
	world.drop_radius_m = 60.0
	world.collision_radius_m = 5.0
	add_child(world)
	var vehicle := Node3D.new()
	add_child(vehicle)
	world.follow(vehicle)
	var at_once := TilesAtOnce.new()
	add_child(at_once)
	at_once.setup(world, vehicle)

	vehicle.global_position = Vector3(150.0, 0.0, 0.0)
	await get_tree().process_frame
	await get_tree().process_frame

	var loaded := world.loaded_keys()
	loaded.sort()
	assert_eq(loaded, ["t5", "t6", "t7", "t8", "t9"] as Array[String])
	world.queue_free()
	vehicle.queue_free()
	at_once.queue_free()
