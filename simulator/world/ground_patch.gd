class_name GroundPatch
extends RefCounted
## A square piece of a tile's height grid, small enough for its height map to be made within
## a frame. Neighbouring patches share the samples of their common edge.

## The squares between samples along a patch's side.
const QUADS := 128

var heights_m := PackedFloat32Array()  ## rows running south and columns east
var samples := 0  ## along each side
var first := Vector2i.ZERO  ## its first sample in the tile's grid: column, row


static func split(
	grid_heights_m: PackedFloat32Array, grid_samples: int, quads := QUADS
) -> Array[GroundPatch]:
	## The patches of a grid of `grid_samples` heights a side, row by row. Where the grid is
	## not a whole number of patches wide, the last ones reach back over their neighbours.
	var patches: Array[GroundPatch] = []
	var firsts := _firsts(grid_samples, quads)
	var side := mini(quads + 1, grid_samples)
	for first_row in firsts:
		for first_column in firsts:
			var patch := GroundPatch.new()
			patch.samples = side
			patch.first = Vector2i(first_column, first_row)
			for row in range(first_row, first_row + side):
				var row_start := row * grid_samples + first_column
				patch.heights_m.append_array(grid_heights_m.slice(row_start, row_start + side))
			patches.append(patch)
	return patches


func centre_m(step_m: float) -> Vector2:
	## Its middle, from the corner of the tile's grid, with `step_m` between samples.
	return (Vector2(first) + Vector2.ONE * (samples - 1) * 0.5) * step_m


static func _firsts(grid_samples: int, quads: int) -> Array[int]:
	## The first sample of each patch along one side of the grid.
	var last_first := maxi(grid_samples - 1 - quads, 0)
	var firsts: Array[int] = []
	for first_sample in range(0, last_first, quads):
		firsts.append(first_sample)
	firsts.append(last_first)
	return firsts
