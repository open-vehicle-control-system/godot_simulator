extends TestCase
## What the stereo optics' camera effects do to the rendered images of a generated scene: a
## grey wall filling the view 10 m ahead, a small white target before it.

const WIDTH_PX := 320
const HEIGHT_PX := 180
const MOUNT := Vector3(0.0, 1.0, 0.0)
const WALL_M := 10.0
const WALL_LIGHT := 0.25
const TARGET := Vector3(-2.4, 2.2, 4.0)  ## up and to the right of the image's centre
const FRAMES_TO_READ_BACK := 120


func test_a_distorted_image_shows_a_point_where_opencv_projects_it() -> void:
	var optics := _optics()
	optics.distortion = LensDistortion.new([-0.25, 0.05, 0.002, -0.001, 0.0])

	var frame := await _frame_of(optics, 2, true)

	var from_camera := TARGET - (MOUNT + Vector3(0.5 * optics.baseline_m, 0.0, 0.0))
	var pinhole := Vector2(-from_camera.x, -from_camera.y) / from_camera.z
	var intrinsics := StereoCamera.intrinsics(optics)
	var centre := Vector2(intrinsics["cx"], intrinsics["cy"])
	var expected: Vector2 = centre + intrinsics["fx"] * optics.distortion.distorted(pinhole)
	var shown := _target_centre(frame.images["left"])
	assert_almost_eq(shown, expected, 1.0)
	assert_true(shown.distance_to(centre + intrinsics["fx"] * pinhole) > 5.0, "as a pinhole")
	# The ground truth is that of the distorted image: the target's depth at its pixel.
	var at := Vector2i(shown.round())
	var depth_m := frame.maps["depth"].decode_float(4 * (at.y * WIDTH_PX + at.x))
	assert_almost_eq(depth_m, TARGET.z, 0.02)
	# The lens sees wider than its image's pinhole: the corners are drawn too.
	assert_true(frame.images["left"].get_pixel(0, 0).r > 0.3, "an empty corner")


func test_vignetting_takes_its_share_of_the_light_in_the_corners() -> void:
	var optics := _optics()
	optics.vignetting = 0.4

	var frame := await _frame_of(optics, 2)

	var left := frame.images["left"]
	var centre := left.get_pixel(WIDTH_PX / 2, HEIGHT_PX / 2).srgb_to_linear().r
	var corner := left.get_pixel(0, HEIGHT_PX - 1).srgb_to_linear().r
	assert_almost_eq(centre, WALL_LIGHT, 0.02)
	assert_almost_eq(corner / centre, 0.6, 0.03)


func test_sensor_noise_differs_from_pixel_to_pixel_and_between_the_cameras() -> void:
	var optics := _optics()
	optics.read_noise = 0.02

	var frame := await _frame_of(optics, 2)

	var left := _row_light(frame.images["left"], HEIGHT_PX - 20)
	var right := _row_light(frame.images["right"], HEIGHT_PX - 20)
	assert_almost_eq(_mean(left), WALL_LIGHT, 0.01)
	assert_almost_eq(_deviation(left), 0.02, 0.006)
	assert_true(left != right, "both cameras have the same noise")


func test_exposure_adapts_to_the_light_of_the_scene() -> void:
	var optics := _optics()
	optics.exposure_target = 0.5
	optics.exposure_speed_per_s = 30.0
	optics.exposure_max_stops = 3.0

	var frame := await _frame_of(optics, 40)

	var shown := frame.images["left"].get_pixel(WIDTH_PX / 2, HEIGHT_PX - 20).srgb_to_linear().r
	assert_almost_eq(shown, 0.5, 0.04)


func test_motion_blur_smears_what_the_camera_moves_past() -> void:
	var still := await _edge_width_px(0.0)
	var optics_shutter_s := 1.0 / Engine.physics_ticks_per_second

	var moving := await _edge_width_px(optics_shutter_s)

	assert_true(still <= 2, "an edge %d px wide without blur" % still)
	# 0.25 m a frame past a wall 10 m away is 4 px with the shutter open all frame long.
	assert_true(moving >= 3 and moving <= 6, "an edge %d px wide" % moving)


func _edge_width_px(shutter_s: float) -> int:
	var optics := _optics()
	optics.shutter_s = shutter_s
	var dark_on_the_left := _box(Color(0.05, 0.05, 0.05), Vector3(100, 20, 1), 52.0, WALL_M - 0.01)
	var frame := await _frame_of(optics, 6, false, Vector3(0.25, 0.0, 0.0), dark_on_the_left)
	var row := _row_light(frame.images["left"], HEIGHT_PX / 2)
	return row.filter(func(light): return light > 0.07 and light < 0.2).size()


func _frame_of(
	optics: VehicleSpec.StereoOptics,
	frames: int,
	ground_truth := false,
	step := Vector3.ZERO,
	also_seen: Node3D = null
) -> StereoFrame:
	## What the pair of `optics` shows after `frames` frames, the vehicle moving by `step` a
	## frame: the wall, the target and `also_seen`.
	var scene := Node3D.new()
	add_child(scene)
	scene.add_child(
		_box(Color(WALL_LIGHT, WALL_LIGHT, WALL_LIGHT), Vector3(200, 200, 1), 0.0, WALL_M)
	)
	if also_seen != null:
		scene.add_child(also_seen)
	var target := _box(Color.WHITE, Vector3(0.1, 0.1, 0.1), TARGET.x, TARGET.z)
	target.position.y = TARGET.y
	scene.add_child(target)
	var vehicle := Node3D.new()
	scene.add_child(vehicle)
	var stereo := StereoCamera.new()
	scene.add_child(stereo)
	stereo.setup(vehicle, optics)
	if ground_truth:
		assert_eq(stereo.add_ground_truth(vehicle), "")
	for frame in frames:
		vehicle.position += step
		await get_tree().process_frame
	var read := []
	vehicle.position += step
	stereo.request_next_frame(func(frame): read.append(frame))
	for waited in FRAMES_TO_READ_BACK:
		if read.is_empty():
			await get_tree().process_frame
	scene.queue_free()
	assert_true(not read.is_empty(), "no frame was read back")
	return read[0]


func _optics() -> VehicleSpec.StereoOptics:
	var optics := VehicleSpec.StereoOptics.new()
	optics.mount = MOUNT
	optics.width_px = WIDTH_PX
	optics.height_px = HEIGHT_PX
	optics.hfov_deg = 90.0
	optics.baseline_m = 0.2
	optics.rate_hz = 10.0
	return optics


func _box(colour: Color, size_m: Vector3, left_m: float, ahead_m: float) -> MeshInstance3D:
	## An unshaded box whose face towards the cameras is `ahead_m` before them.
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	(box.mesh as BoxMesh).size = size_m
	var material := StandardMaterial3D.new()
	material.albedo_color = colour.linear_to_srgb()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material_override = material
	box.position = Vector3(left_m, 0.0, ahead_m + 0.5 * size_m.z)
	return box


func _target_centre(image: Image) -> Vector2:
	var total := Vector2.ZERO
	var weight := 0.0
	for row in HEIGHT_PX:
		for column in WIDTH_PX:
			var light := image.get_pixel(column, row).srgb_to_linear().r
			if light > 0.6:
				total += Vector2(column, row) * light
				weight += light
	return total / maxf(weight, 1e-6)


func _row_light(image: Image, row: int) -> Array:
	var light := []
	for column in WIDTH_PX:
		light.append(image.get_pixel(column, row).srgb_to_linear().r)
	return light


func _mean(numbers: Array) -> float:
	return numbers.reduce(func(total, number): return total + number, 0.0) / numbers.size()


func _deviation(numbers: Array) -> float:
	var mean := _mean(numbers)
	var squares: float = numbers.reduce(
		func(total, number): return total + (number - mean) ** 2, 0.0
	)
	return sqrt(squares / numbers.size())
