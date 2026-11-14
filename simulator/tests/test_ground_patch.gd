extends TestCase
## A tile's height grid is cut into square patches that share their edges.


func test_a_grid_no_larger_than_a_patch_is_one_patch() -> void:
	var heights := _numbered(3)

	var patches := GroundPatch.split(heights, 3, 2)

	assert_eq(patches.size(), 1)
	assert_eq(patches[0].heights_m, heights)
	assert_eq(patches[0].samples, 3)
	assert_eq(patches[0].first, Vector2i.ZERO)


func test_patches_share_the_samples_of_their_edges() -> void:
	var patches := GroundPatch.split(_numbered(5), 5, 2)

	assert_eq(patches.size(), 4)
	var firsts := patches.map(func(patch): return patch.first)
	assert_eq(firsts, [Vector2i(0, 0), Vector2i(2, 0), Vector2i(0, 2), Vector2i(2, 2)])
	# Columns 2 to 4 of rows 0 to 2.
	assert_eq(patches[1].heights_m, PackedFloat32Array([2, 3, 4, 7, 8, 9, 12, 13, 14]))
	assert_eq(patches[1].samples, 3)


func test_the_last_patches_reach_back_to_stay_square() -> void:
	var patches := GroundPatch.split(_numbered(4), 4, 2)

	var firsts := patches.map(func(patch): return patch.first)
	assert_eq(firsts, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)])
	assert_eq(patches[3].heights_m, PackedFloat32Array([5, 6, 7, 9, 10, 11, 13, 14, 15]))


func test_a_patch_is_centred_between_its_first_and_last_samples() -> void:
	var patches := GroundPatch.split(_numbered(5), 5, 2)

	assert_almost_eq(patches[3].centre_m(0.5), Vector2(1.5, 1.5))


func _numbered(samples: int) -> PackedFloat32Array:
	## A grid whose heights are their own index.
	var heights := PackedFloat32Array()
	for index in samples * samples:
		heights.append(index)
	return heights
