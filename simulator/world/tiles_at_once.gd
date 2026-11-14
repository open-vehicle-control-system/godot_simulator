class_name TilesAtOnce
extends Node
## Has every tile around the vehicle in the scene before each frame is drawn, loading the
## missing ones at once instead of over the next frames: what a frame shows then depends on
## where the vehicle is, never on how fast tiles load, as a repeatable recording needs.

var _tiles: TrackTiles
var _target: Node3D


func setup(tiles: TrackTiles, target: Node3D) -> void:
	## Loads at once, from now on, the tiles `tiles` would stream in around `target`.
	_tiles = tiles
	_target = target
	name = "TilesAtOnce"
	_tiles.start_radius_m = _tiles.load_radius_m
	# Nothing is left for the tiles to load in the background, whose pace differs run to run.
	_tiles.load_radius_m = 0.0


func _process(_delta: float) -> void:
	var problem := _tiles.load_around(_target.global_position)
	if problem != "":
		push_error(problem)
