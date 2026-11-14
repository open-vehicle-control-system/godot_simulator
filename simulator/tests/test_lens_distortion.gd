extends TestCase
## Lens distortion in OpenCV's model: radial k1, k2, k3 and tangential p1, p2.


func test_distorts_a_point_as_opencv_does() -> void:
	var lens := LensDistortion.new([-0.2, 0.05, 0.01, 0.02, 0.0])

	assert_almost_eq(lens.distorted(Vector2(0.5, 0.25)), Vector2(0.48994140625, 0.244970703125))
	assert_almost_eq(lens.distorted(Vector2.ZERO), Vector2.ZERO)


func test_radial_distortion_alone_keeps_the_direction() -> void:
	var lens := LensDistortion.new([-0.2, 0.0, 0.0, 0.0, 0.0])

	assert_almost_eq(lens.distorted(Vector2(0.5, 0.25)), Vector2(0.46875, 0.234375))


func test_undistorting_finds_the_point_that_distorts_to_it() -> void:
	var lenses := [
		[-0.3, 0.1, 0.0, 0.0, -0.01],
		[0.1, 0.02, 0.001, -0.002, 0.0],
		[-0.2, 0.05, 0.01, 0.02, 0.0],
	]
	for coefficients in lenses:
		var lens := LensDistortion.new(coefficients)
		for point in [Vector2(0.9, 0.5), Vector2(-0.6, 0.55), Vector2(0.1, -0.2)]:
			var seen_at := lens.distorted(point)
			assert_almost_eq(lens.undistorted(seen_at), point, 1e-5, str(coefficients))


func test_a_barrel_lens_sees_wider_than_the_pinhole_of_its_image() -> void:
	var half_extent := Vector2(1.0, 0.5625)
	var barrel := LensDistortion.new([-0.2, 0.03, 0.0, 0.0, 0.0])

	var overscan := barrel.overscan(half_extent)

	assert_true(overscan > 1.1 and overscan < 1.5, str(overscan))
	for corner in [
		half_extent, -half_extent, Vector2(half_extent.x, 0.0), Vector2(0.0, half_extent.y)
	]:
		var seen := barrel.undistorted(corner)
		assert_true(absf(seen.x) <= half_extent.x * overscan + 1e-6, str(corner))
		assert_true(absf(seen.y) <= half_extent.y * overscan + 1e-6, str(corner))


func test_a_pincushion_lens_sees_within_the_pinhole_of_its_image() -> void:
	var pincushion := LensDistortion.new([0.1, 0.0, 0.0, 0.0, 0.0])

	assert_eq(pincushion.overscan(Vector2(1.0, 0.5625)), 1.0)


func test_tells_a_lens_that_folds_the_image() -> void:
	var half_extent := Vector2(1.0, 0.5625)

	assert_true(not LensDistortion.new([-0.2, 0.03, 0.0, 0.0, 0.0]).folds(half_extent))
	# Past r = 1 / sqrt(3 * 0.5), points move back towards the centre.
	assert_true(LensDistortion.new([-0.5, 0.0, 0.0, 0.0, 0.0]).folds(half_extent))
