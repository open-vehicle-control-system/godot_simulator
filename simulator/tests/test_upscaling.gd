extends TestCase
## The window can be drawn smaller and upscaled with FSR 2, and always is when it is larger than
## 2560 x 1440 unless asked for every pixel; the stereo cameras never are.

const MAIN_SCENE := "res://main.tscn"


func test_reads_the_upscaling_level() -> void:
	var parsed := SimulatorOptions.parse(["--track=t", "--vehicle=v", "--upscale=balanced"])

	assert_eq(parsed["options"].upscale, "balanced")


func test_does_not_upscale_unless_asked() -> void:
	var parsed := SimulatorOptions.parse(["--track=t", "--vehicle=v"])

	assert_eq(parsed["options"].upscale, "")


func test_refuses_a_level_it_does_not_know() -> void:
	var parsed := SimulatorOptions.parse(["--track=t", "--vehicle=v", "--upscale=sharp"])

	assert_eq(parsed, {"error": "--upscale is one of quality, balanced, performance, native"})


func test_a_level_draws_the_viewport_smaller_and_upscales_it_with_fsr_2() -> void:
	var cases := {"quality": 0.67, "balanced": 0.59, "performance": 0.5}
	for level in cases:
		var viewport := SubViewport.new()

		Upscaling.apply(viewport, Vector2i(1920, 1080), level)

		assert_eq(viewport.scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR2, level)
		assert_almost_eq(viewport.scaling_3d_scale, cases[level], 1e-6, level)
		viewport.free()


func test_a_window_larger_than_1440p_is_drawn_at_1440p_and_upscaled() -> void:
	var five_k := Vector2i(5120, 2880)

	assert_almost_eq(Upscaling.scale_for(five_k, ""), 0.5, 1e-6, "2560 x 1440 of 5120 x 2880")
	assert_almost_eq(Upscaling.scale_for(Vector2i(3840, 2160), ""), 2.0 / 3.0, 1e-6, "4K")
	assert_almost_eq(Upscaling.scale_for(five_k, "quality"), 0.5, 1e-6, "the cap is lower")
	assert_almost_eq(Upscaling.scale_for(Vector2i(2560, 1440), ""), 1.0, 1e-6, "at the cap")
	assert_almost_eq(Upscaling.scale_for(Vector2i(1920, 1080), ""), 1.0, 1e-6)
	assert_almost_eq(Upscaling.scale_for(five_k, Upscaling.NATIVE), 1.0, 1e-6, "every pixel")


func test_follows_the_window_as_it_grows_and_shrinks() -> void:
	var window := Window.new()
	window.size = Vector2i(1920, 1080)
	add_child(window)
	var upscaling := Upscaling.new()
	add_child(upscaling)
	upscaling.setup(window, "")
	var at_1080p := window.scaling_3d_mode

	window.size = Vector2i(5120, 2880)
	var full_screen := [window.scaling_3d_mode, window.scaling_3d_scale]
	window.size = Vector2i(1920, 1080)

	assert_eq(at_1080p, Viewport.SCALING_3D_MODE_BILINEAR)
	assert_eq(full_screen[0], Viewport.SCALING_3D_MODE_FSR2)
	assert_almost_eq(full_screen[1], 0.5, 1e-6)
	assert_eq(window.scaling_3d_mode, Viewport.SCALING_3D_MODE_BILINEAR, "back to every pixel")
	assert_almost_eq(window.scaling_3d_scale, 1.0)


func test_only_the_window_is_upscaled() -> void:
	var directory := PackFixtures.fresh_directory("upscaling")
	PackFixtures.write_flat_world(
		PackFixtures.write_pack(directory, PackFixtures.track_manifest("flat")), 200.0
	)
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	var simulator: Node3D = load(MAIN_SCENE).instantiate()
	simulator.arguments = PackedStringArray(
		["--track=flat", "--vehicle=small_car", "--packs=" + directory, "--upscale=quality"]
	)
	var window := get_viewport()
	var mode_before := window.scaling_3d_mode
	var scale_before := window.scaling_3d_scale

	add_child(simulator)

	assert_eq(window.scaling_3d_mode, Viewport.SCALING_3D_MODE_FSR2)
	assert_almost_eq(window.scaling_3d_scale, 0.67, 1e-6)
	var stereo: StereoCamera = simulator.get_node("StereoCamera")
	for viewport in stereo.viewports:
		assert_eq(viewport.scaling_3d_mode, Viewport.SCALING_3D_MODE_BILINEAR)
		assert_almost_eq(viewport.scaling_3d_scale, 1.0)
		assert_eq(viewport.size, Vector2i(320, 180), "as the vehicle pack sizes it")
	simulator.queue_free()
	window.scaling_3d_mode = mode_before
	window.scaling_3d_scale = scale_before
