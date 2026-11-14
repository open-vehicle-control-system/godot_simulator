class_name TileRing
extends RefCounted
## Which tiles lie around a point: what the streaming of a track's tiles is decided from. Pure.


static func distance_m(tile: TilesSpec.Tile, point: Vector2) -> float:
	## How far `point` (x, z) is from what the tile holds; 0 over it.
	var reach := tile.reach()
	var nearest := point.clamp(reach.position, reach.end)
	return point.distance_to(nearest)


static func within(tiles: Array[TilesSpec.Tile], point: Vector2, radius_m: float) -> Array:
	## The tiles closer to `point` than `radius_m`, the nearest first.
	var near := tiles.filter(func(tile): return distance_m(tile, point) < radius_m)
	near.sort_custom(func(first, second): return _is_nearer(first, second, point))
	return near


static func _is_nearer(first: TilesSpec.Tile, second: TilesSpec.Tile, point: Vector2) -> bool:
	var first_m := distance_m(first, point)
	var second_m := distance_m(second, point)
	if first_m != second_m:
		return first_m < second_m
	# Over several tiles at once (their reaches overlap): the one centred nearest.
	return (
		first.reach().get_center().distance_squared_to(point)
		< second.reach().get_center().distance_squared_to(point)
	)
