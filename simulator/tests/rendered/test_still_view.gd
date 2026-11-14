extends TestCase
## A still view of tree impostors under a sky, drawn frame after frame: every frame shows the
## same pixels, in the window and in both cameras of the pair.

const WIDTH_PX := 320
const HEIGHT_PX := 180
const MOUNT := Vector3(0.0, 1.5, 0.0)
const TREE_ROWS := 6
const TREES_PER_ROW := 10
const TREE_SPACING_M := 4.0
const TREE_HEIGHT_M := 9.0
const ATLAS_PX := 256
const FRAMES_BETWEEN := 10
const FRAMES_TO_READ_BACK := 120

var _stereo: StereoCamera
var _pair: StereoFrame


func test_a_still_view_of_trees_draws_the_same_pixels_every_frame() -> void:
	var scene := _forest()
	add_child(scene)
	for frame in FRAMES_BETWEEN:
		await get_tree().process_frame

	var first := await _frame_seen()
	for frame in FRAMES_BETWEEN:
		await get_tree().process_frame
	var second := await _frame_seen()

	scene.queue_free()
	for view: String in ["window", "left", "right"]:
		assert_eq(_differing_pixels(first[view], second[view]), 0, view)


func _forest() -> Node3D:
	## Rows of tree impostors before the pair and the window's camera, lit by a sun and a sky.
	var scene := Node3D.new()
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_SKY
	world.environment.sky = Sky.new()
	world.environment.sky.sky_material = ProceduralSkyMaterial.new()
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world.environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	scene.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)
	scene.add_child(sun)
	scene.add_child(_trees())
	var camera := Camera3D.new()
	camera.position = MOUNT
	camera.basis = Basis(Vector3.UP, PI)
	scene.add_child(camera)
	camera.make_current()
	var vehicle := Node3D.new()
	scene.add_child(vehicle)
	_stereo = StereoCamera.new()
	scene.add_child(_stereo)
	_stereo.setup(vehicle, _optics())
	return scene


func _trees() -> MultiMeshInstance3D:
	var material := ShaderMaterial.new()
	material.shader = Forest.SHADER
	material.set_shader_parameter("atlas", ImageTexture.create_from_image(_leafy_atlas()))
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = Forest.card_mesh(2, 0.6)
	multimesh.mesh.surface_set_material(0, material)
	multimesh.instance_count = TREE_ROWS * TREES_PER_ROW
	for row in TREE_ROWS:
		for column in TREES_PER_ROW:
			var foot := Vector3(
				(column - 0.5 * TREES_PER_ROW + 0.5 * (row % 2)) * TREE_SPACING_M,
				0.0,
				8.0 + row * TREE_SPACING_M
			)
			var basis := Basis(Vector3.UP, 0.7 * (row * TREES_PER_ROW + column))
			multimesh.set_instance_transform(
				row * TREES_PER_ROW + column,
				Transform3D(basis.scaled(Vector3.ONE * TREE_HEIGHT_M), foot)
			)
			multimesh.set_instance_color(row * TREES_PER_ROW + column, Color.WHITE)
	var trees := MultiMeshInstance3D.new()
	trees.multimesh = multimesh
	return trees


func _leafy_atlas() -> Image:
	## Two views of a crown full of holes, as a real atlas's leaves leave between them.
	var random := RandomNumberGenerator.new()
	random.seed = 3
	var atlas := Image.create_empty(ATLAS_PX, ATLAS_PX, false, Image.FORMAT_RGBA8)
	for blob in 600:
		var centre := Vector2i(random.randi_range(0, ATLAS_PX - 1), random.randi_range(20, 220))
		var leaf := Color(0.1, random.randf_range(0.3, 0.5), 0.1, 1.0)
		atlas.fill_rect(Rect2i(centre, Vector2i(random.randi_range(2, 7), 3)), leaf)
	atlas.generate_mipmaps()
	return atlas


func _optics() -> VehicleSpec.StereoOptics:
	var optics := VehicleSpec.StereoOptics.new()
	optics.mount = MOUNT
	optics.width_px = WIDTH_PX
	optics.height_px = HEIGHT_PX
	optics.hfov_deg = 90.0
	optics.baseline_m = 0.2
	optics.rate_hz = 10.0
	return optics


func _frame_seen() -> Dictionary:
	## The window's image and the pair's, of the frame about to be drawn.
	_pair = null
	_stereo.request_next_frame(func(frame): _pair = frame)
	await RenderingServer.frame_post_draw
	var window := get_viewport().get_texture().get_image()
	for waited in FRAMES_TO_READ_BACK:
		if _pair == null:
			await get_tree().process_frame
	assert_true(_pair != null, "no frame was read back")
	return {"window": window, "left": _pair.images["left"], "right": _pair.images["right"]}


func _differing_pixels(first: Image, second: Image) -> int:
	first.convert(Image.FORMAT_RGBA8)
	second.convert(Image.FORMAT_RGBA8)
	var first_bytes := first.get_data()
	var second_bytes := second.get_data()
	var differing := 0
	for pixel in first_bytes.size() / 4:
		for channel in 3:
			if first_bytes[4 * pixel + channel] != second_bytes[4 * pixel + channel]:
				differing += 1
				break
	return differing
