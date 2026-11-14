class_name TilesSpec
extends RefCounted
## A track pack's tiles: the squares its world is cut into, each with its scene, its ground's
## heights and maps, and what stands on it, loaded on their own.

const OPTIONAL_MAPS := ["track", "roads", "lots"]


class Tile:
	extends RefCounted
	var key: String  ## names the tile's files: `<key>.glb`, `<key>.ground.f32`, ...
	var corner: Vector2  ## (x, z) of its lowest corner, in Godot's world frame
	var bounds: AABB  ## what it holds, which may reach past its square
	var maps: Array[String] = []  ## which of OPTIONAL_MAPS it has
	var directory: String

	func path(suffix: String) -> String:
		## The tile's file ending in `suffix`.
		return directory.path_join(key + suffix)

	func reach() -> Rect2:
		## The ground its contents cover, as (x, z).
		return Rect2(bounds.position.x, bounds.position.z, bounds.size.x, bounds.size.z)


var tile_size_m: float
var ground_step_m: float  ## between the samples of a tile's ground heights
var tiles: Array[Tile] = []


static func parse(reader: ManifestReader, directory: String) -> TilesSpec:
	## The tiles listed by the file `tiles` names in `reader`; `reader.error` tells what is
	## wrong with them.
	var spec := TilesSpec.new()
	var path := reader.file("tiles", directory)
	if reader.error != "":
		return spec
	var listed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var index := ManifestReader.new(
		reader.pack_id, listed if listed is Dictionary else {}, path.get_file() + ": "
	)
	spec.tile_size_m = index.positive("tile_size_m")
	spec.ground_step_m = index.positive("ground_step_m")
	var steps := spec.tile_size_m / maxf(spec.ground_step_m, 1e-6)
	index.check(is_equal_approx(steps, roundf(steps)), "ground_step_m")
	var tile_directory := directory.path_join("tiles")
	for tile_reader in index.readers("tiles"):
		var tile := Tile.new()
		tile.key = tile_reader.text("key")
		tile.directory = tile_directory
		# The pack's frame is ROS's: its (x, y) are Godot's (z, x).
		var corner := tile_reader.numbers("corner_m", 2)
		tile.corner = Vector2(corner[1], corner[0])
		var low := tile_reader.ros_vector("bounds_m.0")
		tile.bounds = AABB(low, tile_reader.ros_vector("bounds_m.1") - low)
		for map in tile_reader.list("maps"):
			tile_reader.check(map in OPTIONAL_MAPS, "maps")
			if map in OPTIONAL_MAPS:
				tile.maps.append(map)
		if index.error == "":
			index.error = tile_reader.error
		spec.tiles.append(tile)
	index.check(not spec.tiles.is_empty(), "tiles")
	if reader.error == "":
		reader.error = index.error
	return spec


func ground_samples() -> int:
	## How many height samples a tile's ground has along each side.
	return roundi(tile_size_m / ground_step_m) + 1
