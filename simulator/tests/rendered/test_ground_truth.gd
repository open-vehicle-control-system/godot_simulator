extends TestCase
## The ground truth rendered of a generated scene: walls at known distances in front of the
## stereo pair, one labelled, one not, a pane of glass before the first; and a vehicle whose
## windscreen, just before the pair, overlooks its bonnet and the first wall.

const WIDTH_PX := 320
const HEIGHT_PX := 180
const BASELINE_M := 0.2
const MOUNT := Vector3(0.0, 1.0, 0.0)
const NEAR_WALL_M := 4.0
const FAR_WALL_M := 20.0
const BONNET_TOP := Vector3(-0.3, 0.6, 0.9)
const FRAMES_TO_READ_BACK := 120
const SKY_COLOUR := Color8(70, 130, 180)
const BUILDING_COLOUR := Color8(70, 70, 70)
const UNLABELLED_COLOUR := Color8(0, 0, 0)
const VEHICLE_COLOUR := Color8(0, 0, 142)

var _frame: StereoFrame
var _optics: VehicleSpec.StereoOptics


func test_depth_is_the_distance_along_the_optical_axis() -> void:
	await _render_the_walls()

	assert_almost_eq(_map_at("depth", _seen_at(Vector3(-1.0, 1.0, NEAR_WALL_M))), NEAR_WALL_M, 1e-3)
	# Off the axis the depth is still the wall's, not the length of the ray.
	assert_almost_eq(_map_at("depth", _seen_at(Vector3(-1.8, 1.8, NEAR_WALL_M))), NEAR_WALL_M, 1e-3)
	assert_almost_eq(_map_at("depth", _seen_at(Vector3(6.0, 1.0, FAR_WALL_M))), FAR_WALL_M, 1e-2)
	assert_eq(_map_at("depth", Vector2i(WIDTH_PX / 2, 2)), 0.0, "sky")


func test_disparity_is_the_depth_seen_by_the_pair() -> void:
	await _render_the_walls()

	var on_near_wall := _seen_at(Vector3(-1.0, 1.0, NEAR_WALL_M))
	assert_almost_eq(
		_map_at("disparity", on_near_wall), StereoCamera.disparity_px(_optics, NEAR_WALL_M), 1e-3
	)
	assert_almost_eq(
		_map_at("disparity", _seen_at(Vector3(6.0, 1.0, FAR_WALL_M))),
		StereoCamera.disparity_px(_optics, FAR_WALL_M),
		1e-3
	)
	assert_eq(_map_at("disparity", Vector2i(WIDTH_PX / 2, 2)), 0.0, "sky")
	# The right camera sees the wall's edge that many pixels to the left.
	var row := _seen_at(Vector3(-1.0, 2.0, NEAR_WALL_M)).y  # above the glass
	var shift_px := _first_red_column("left", row) - _first_red_column("right", row)
	assert_almost_eq(float(shift_px), _map_at("disparity", on_near_wall), 1.0)


func test_segmentation_shows_the_class_each_surface_carries() -> void:
	await _render_the_walls()

	var segmentation := _frame.images["segmentation"]
	var on_near_wall := _seen_at(Vector3(-1.0, 1.0, NEAR_WALL_M))
	assert_eq(segmentation.get_pixelv(on_near_wall), BUILDING_COLOUR)
	var behind_glass := _seen_at(Vector3(0.5, 1.0, NEAR_WALL_M))
	assert_eq(segmentation.get_pixelv(behind_glass), BUILDING_COLOUR, "seen through glass")
	assert_almost_eq(_map_at("depth", behind_glass), NEAR_WALL_M, 1e-3, "seen through glass")
	var on_far_wall := _seen_at(Vector3(6.0, 1.0, FAR_WALL_M))
	assert_eq(segmentation.get_pixelv(on_far_wall), UNLABELLED_COLOUR)
	assert_eq(segmentation.get_pixel(WIDTH_PX / 2, 2), SKY_COLOUR)


func test_a_windscreen_shows_what_is_behind_it() -> void:
	await _render_the_walls()

	var through_windscreen := _seen_at(Vector3(-1.0, 0.0, NEAR_WALL_M))
	var segmentation := _frame.images["segmentation"]
	assert_eq(segmentation.get_pixelv(through_windscreen), BUILDING_COLOUR)
	assert_almost_eq(_map_at("depth", through_windscreen), NEAR_WALL_M, 1e-3)
	assert_almost_eq(
		_map_at("disparity", through_windscreen),
		StereoCamera.disparity_px(_optics, NEAR_WALL_M),
		1e-3
	)
	var on_bonnet := _seen_at(BONNET_TOP)
	assert_eq(segmentation.get_pixelv(on_bonnet), VEHICLE_COLOUR, "the bonnet is the vehicle")
	assert_almost_eq(_map_at("depth", on_bonnet), BONNET_TOP.z, 1e-2)


func test_the_pair_is_not_drawn_with_labels() -> void:
	await _render_the_walls()

	var shown := _frame.images["left"].get_pixelv(_seen_at(Vector3(-1.0, 1.0, NEAR_WALL_M)))
	assert_almost_eq(shown, Color.RED, 0.02)
	var through_glass := _frame.images["left"].get_pixelv(_seen_at(Vector3(0.5, 1.0, NEAR_WALL_M)))
	assert_true(through_glass.g > 0.2, "the glass is drawn: %s" % through_glass)


func _render_the_walls() -> void:
	## Renders, once for all tests, a red wall labelled a building with glass before its
	## right end, and a further white wall without label, under a black sky.
	if _frame != null:
		return
	_optics = VehicleSpec.StereoOptics.new()
	_optics.mount = MOUNT
	_optics.width_px = WIDTH_PX
	_optics.height_px = HEIGHT_PX
	_optics.hfov_deg = 90.0
	_optics.baseline_m = BASELINE_M
	_optics.rate_hz = 10.0
	var scene := Node3D.new()
	add_child(scene)
	var near_wall := _wall(Color.RED, Vector3(4.0, 4.0, 0.2), Vector3(-1.0, 1.0, NEAR_WALL_M + 0.1))
	near_wall.material_override.next_pass = Segmentation.label_pass(Segmentation.BUILDING)
	scene.add_child(near_wall)
	scene.add_child(_wall(Color.WHITE, Vector3(8.0, 8.0, 0.2), Vector3(6.0, 1.0, FAR_WALL_M + 0.1)))
	var glass := _wall(Color(0.2, 0.9, 0.3, 0.4), Vector3(0.4, 0.4, 0.02), Vector3(0.3, 1.0, 2.0))
	glass.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	scene.add_child(glass)
	var vehicle := Node3D.new()
	scene.add_child(vehicle)
	var bonnet := _wall(Color.BLUE, Vector3(1.2, 0.1, 0.7), BONNET_TOP + Vector3(0.3, -0.05, 0.0))
	vehicle.add_child(bonnet)
	# As Godot imports glTF's BLEND glass: drawn after a depth pre-pass.
	var windscreen := _wall(
		Color(1.0, 1.0, 1.0, 0.1), Vector3(1.0, 0.25, 0.005), Vector3(0.0, 0.825, 0.3)
	)
	windscreen.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	vehicle.add_child(windscreen)
	Segmentation.label_under(vehicle, Segmentation.VEHICLE)
	var stereo := StereoCamera.new()
	scene.add_child(stereo)
	stereo.setup(vehicle, _optics)
	assert_eq(stereo.add_ground_truth(vehicle), "")
	await get_tree().process_frame
	stereo.request_next_frame(func(frame): _frame = frame)
	for waited in FRAMES_TO_READ_BACK:
		if _frame == null:
			await get_tree().process_frame
	assert_true(_frame != null, "no frame was read back")


func _wall(colour: Color, size_m: Vector3, centre: Vector3) -> MeshInstance3D:
	var wall := MeshInstance3D.new()
	wall.mesh = BoxMesh.new()
	(wall.mesh as BoxMesh).size = size_m
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wall.material_override = material
	wall.position = centre
	return wall


func _seen_at(point: Vector3) -> Vector2i:
	## The pixel of the left image showing `point` of the vehicle's frame.
	var intrinsics := StereoCamera.intrinsics(_optics)
	var from_camera := point - (MOUNT + Vector3(0.5 * BASELINE_M, 0.0, 0.0))
	return Vector2i(
		roundi(intrinsics["cx"] - intrinsics["fx"] * from_camera.x / from_camera.z),
		roundi(intrinsics["cy"] - intrinsics["fy"] * from_camera.y / from_camera.z)
	)


func _map_at(map: String, pixel: Vector2i) -> float:
	return _frame.maps[map].decode_float(4 * (pixel.y * WIDTH_PX + pixel.x))


func _first_red_column(image: String, row: int) -> int:
	for column in WIDTH_PX:
		var colour := _frame.images[image].get_pixel(column, row)
		if colour.r > 0.5 and colour.g < 0.3:
			return column
	return -1
