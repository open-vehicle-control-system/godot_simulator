class_name TrackTiles
extends Node3D
## A track's world, streamed: the tiles around the vehicle are read on worker threads and
## enter the scene one a frame, nearest first; the ones left far behind are freed. Only the
## tiles close to the vehicle collide, and those are loaded at once if they are not there, so
## the vehicle never meets ground or obstacles that are missing. Where a tile is not loaded
## the far terrain shows.

const LOAD_RADIUS_M := 900.0
## Beyond the load radius, so a tile at its border is not loaded and freed in turns.
const DROP_RADIUS_M := 1100.0
const COLLISION_RADIUS_M := 120.0
const COLLISION_DROP_RADIUS_M := 180.0
## What is loaded before the vehicle is placed: the tile it stands on and those around it.
const START_RADIUS_M := 200.0
const MAX_TILES_LOADING := 3
const SCAN_INTERVAL_S := 0.2

var load_radius_m := LOAD_RADIUS_M
var drop_radius_m := DROP_RADIUS_M
var collision_radius_m := COLLISION_RADIUS_M
var collision_drop_radius_m := COLLISION_DROP_RADIUS_M
var start_radius_m := START_RADIUS_M

var _tiles: TilesSpec
var _loader: TileLoader
var _far: FarTerrain  # null for a track without far terrain
var _target: Node3D
var _centre := Vector3.ZERO  # what the tiles are loaded around when nothing is followed
var _loaded: Dictionary[String, TileContent] = {}
var _colliding: Dictionary[String, Node3D] = {}
var _loading: Dictionary[String, int] = {}  # tile key -> worker task
var _finished: Array[TileContent] = []  # filled by worker threads, under _mutex
var _unprepared: Array[TileContent] = []  # in the scene, shapes of their collision still to make
var _refused: Dictionary[String, bool] = {}  # tiles whose files are wrong, not tried again
var _mutex := Mutex.new()
var _since_scan_s := SCAN_INTERVAL_S


static func create(track: TrackSpec) -> Dictionary:
	## `{"tiles": TrackTiles}` ready to load `track`'s tiles, none loaded yet, or
	## `{"error": reason}`.
	var materials := SurfaceMaterials.new(track)
	var problem := materials.prepare()
	if problem != "":
		return {"error": problem}
	var forest: Forest = null
	if track.trees != null:
		var forest_found := Forest.create(track.trees)
		if forest_found.has("error"):
			return {"error": "%s: %s" % [track.id, forest_found["error"]]}
		forest = forest_found["forest"]
	var signs: RoadSigns = null
	if track.signs != null:
		signs = RoadSigns.new(track.signs)
	var decals: RoadDecals = null
	if track.decals != null:
		decals = RoadDecals.new(track.decals)
	var world := TrackTiles.new()
	world.name = "Track"
	world.process_physics_priority = -1  # before the vehicle moves
	world._tiles = track.tiles
	world._loader = TileLoader.new(track, materials, forest, signs, decals)
	if track.far_scene_path != "":
		var far_found := FarTerrain.build(track)
		if far_found.has("error"):
			world.free()
			return {"error": far_found["error"]}
		world._far = far_found["far"]
		world.add_child(world._far)
	if track.trees != null and track.trees.canopy_scene_path != "":
		var canopy_found := Canopy.build(track, world._far.photo)
		if canopy_found.has("error"):
			world.free()
			return {"error": "%s: %s" % [track.id, canopy_found["error"]]}
		world.add_child(canopy_found["canopy"])
	return {"tiles": world}


func load_around(point: Vector3) -> String:
	## Loads at once the tiles within the start radius of `point`, with the collision of the
	## nearest; the rest follows frame by frame. Returns what is wrong with a tile, or "".
	_centre = point
	return _load_now(start_radius_m)


func follow(target: Node3D) -> void:
	## Keeps the tiles around `target` loaded from now on.
	_target = target


func loaded_keys() -> Array[String]:
	## The keys of the tiles in the scene.
	return _loaded.keys()


func colliding_keys() -> Array[String]:
	## The keys of the tiles whose collision is in the scene.
	return _colliding.keys()


func preparing_keys() -> Array[String]:
	## The keys of the tiles in the scene whose collision is not all made yet.
	var keys: Array[String] = []
	keys.assign(_unprepared.map(func(content): return content.tile.key))
	return keys


func is_settled() -> bool:
	## True when every tile within the load radius is in the scene.
	var wanted := TileRing.within(_tiles.tiles, _point(), load_radius_m)
	return wanted.all(func(tile): return _loaded.has(tile.key) or _refused.has(tile.key))


func _ready() -> void:
	# What was loaded before the first frame is ready to collide before it.
	while not _unprepared.is_empty():
		_prepare_some_collision()


func _process(delta: float) -> void:
	_attach_one_finished()
	_prepare_some_collision()
	_since_scan_s += delta
	if _since_scan_s < SCAN_INTERVAL_S:
		return
	_since_scan_s = 0.0
	var point := _point()
	for key in _loaded:
		if TileRing.distance_m(_loaded[key].tile, point) > drop_radius_m:
			_drop(key)
			break  # one a frame
	for tile: TilesSpec.Tile in TileRing.within(_tiles.tiles, point, load_radius_m):
		if _loading.size() >= MAX_TILES_LOADING:
			break
		if not (_loaded.has(tile.key) or _loading.has(tile.key) or _refused.has(tile.key)):
			_loading[tile.key] = WorkerThreadPool.add_task(_load_on_worker.bind(tile))


func _physics_process(_delta: float) -> void:
	var point := _point()
	var near := TileRing.within(_tiles.tiles, point, collision_radius_m)
	if near.any(func(tile): return not (_loaded.has(tile.key) or _refused.has(tile.key))):
		var problem := _load_now(collision_radius_m)
		if problem != "":
			push_error(problem)
	for tile: TilesSpec.Tile in near:
		if _loaded.has(tile.key) and not _colliding.has(tile.key):
			_add_collision(tile.key)
	for key in _colliding.keys():
		if TileRing.distance_m(_loaded[key].tile, point) > collision_drop_radius_m:
			_colliding[key].queue_free()
			_colliding.erase(key)


func _exit_tree() -> void:
	for task in _loading.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_loading.clear()
	_finished.clear()


func _point() -> Vector2:
	var around := _target.global_position if _target != null else _centre
	return Vector2(around.x, around.z)


func _load_now(radius_m: float) -> String:
	## Brings the tiles within `radius_m` into the scene before returning, loading the missing
	## ones side by side on the worker threads, and gives the near ones their collision.
	var point := _point()
	var missing: Array[TilesSpec.Tile] = []
	for tile: TilesSpec.Tile in TileRing.within(_tiles.tiles, point, radius_m):
		if _loaded.has(tile.key) or _refused.has(tile.key):
			continue
		if _loading.has(tile.key):
			WorkerThreadPool.wait_for_task_completion(_loading[tile.key])
			_loading.erase(tile.key)
		else:
			missing.append(tile)
	var contents: Array[TileContent] = []
	contents.resize(missing.size())
	if not missing.is_empty():
		var group := WorkerThreadPool.add_group_task(
			_load_one_of.bind(missing, contents), missing.size()
		)
		WorkerThreadPool.wait_for_group_task_completion(group)
	_mutex.lock()
	contents.append_array(
		_finished.filter(func(content): return not _loading.has(content.tile.key))
	)
	_finished.assign(_finished.filter(func(content): return _loading.has(content.tile.key)))
	_mutex.unlock()
	var problem := ""
	for content in contents:
		var refused := _attach(content)
		if problem == "":
			problem = refused
	for tile: TilesSpec.Tile in TileRing.within(_tiles.tiles, point, collision_radius_m):
		if _loaded.has(tile.key) and not _colliding.has(tile.key):
			_add_collision(tile.key)
	return problem


func _load_one_of(index: int, tiles: Array[TilesSpec.Tile], contents: Array[TileContent]) -> void:
	contents[index] = _loader.read_tile(tiles[index])


func _load_on_worker(tile: TilesSpec.Tile) -> void:
	var content := _loader.read_tile(tile)
	_mutex.lock()
	_finished.append(content)
	_mutex.unlock()


func _attach_one_finished() -> void:
	_mutex.lock()
	var content: TileContent = _finished.pop_front() if not _finished.is_empty() else null
	_mutex.unlock()
	if content == null:
		return
	WorkerThreadPool.wait_for_task_completion(_loading[content.tile.key])
	_loading.erase(content.tile.key)
	if TileRing.distance_m(content.tile, _point()) > drop_radius_m:
		return
	var problem := _attach(content)
	if problem != "":
		push_error(problem)


func _attach(content: TileContent) -> String:
	## Puts a loaded tile in the scene; a tile that did not load is not tried again.
	var key := content.tile.key
	if content.error != "":
		_refused[key] = true
		return content.error
	_loader.build_scene(content)
	add_child(content.scene)
	_loaded[key] = content
	_unprepared.append(content)
	if _far != null:
		_far.show_tile(key, false)
	return ""


func _prepare_some_collision() -> void:
	## Makes one shape of the collision of the nearest tile that lacks some, so a tile's
	## collision is ready before the vehicle comes near it.
	var point := _point()
	var nearest: TileContent = null
	for content in _unprepared:
		if nearest == null or _is_nearer(content, nearest, point):
			nearest = content
	if nearest == null:
		return
	if not TileCollision.prepare_next_shape(nearest, get_world_3d().direct_space_state):
		_unprepared.erase(nearest)


static func _is_nearer(content: TileContent, other: TileContent, point: Vector2) -> bool:
	return TileRing.distance_m(content.tile, point) < TileRing.distance_m(other.tile, point)


func _add_collision(key: String) -> void:
	var collision := TileCollision.build(_loaded[key], _tiles)
	_loaded[key].scene.add_child(collision)
	_colliding[key] = collision


func _drop(key: String) -> void:
	_colliding.erase(key)
	_unprepared.erase(_loaded[key])
	_loaded[key].scene.queue_free()
	_loaded.erase(key)
	if _far != null:
		_far.show_tile(key, true)
