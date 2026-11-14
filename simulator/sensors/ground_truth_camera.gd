class_name GroundTruthCamera
extends Node
## Sees what the left stereo camera sees, as ground truth: each pixel's depth, disparity and
## class. It draws the world's labels instead of its light, only the frames asked for, and a
## compositor effect turns its depth buffer and labels into the three maps.

const FLOAT_MAPS := ["depth", "disparity"]

var camera := Camera3D.new()

var _viewport := SubViewport.new()
var _effect: GroundTruthEffect


func setup(optics: VehicleSpec.StereoOptics, focal_px: float) -> void:
	## Draws the ground truth of a camera of `optics` focusing at `focal_px`.
	name = "GroundTruthCamera"
	_viewport.size = Vector2i(optics.width_px, optics.height_px)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Labels are emitted, not lit: no light, shadow or fog is computed for them.
	_viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	camera.cull_mask = Segmentation.ground_truth_cull_mask()
	camera.environment = _nothing_but_labels()
	_effect = GroundTruthEffect.new(focal_px * optics.baseline_m)
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [_effect]
	_viewport.add_child(camera)
	add_child(_viewport)
	camera.current = true


func draw_next_frame() -> void:
	## Draws the ground truth of the frame about to be drawn.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func read_into(frame: StereoFrame) -> void:
	## Reads the ground truth drawn last into `frame`, a few frames from now: three parts.
	var device := RenderingServer.get_rendering_device()
	device.texture_get_data_async(_effect.depth_m, 0, _on_map_read.bind("depth", frame))
	device.texture_get_data_async(_effect.disparity_px, 0, _on_map_read.bind("disparity", frame))
	device.texture_get_data_async(_effect.segmentation, 0, _on_segmentation_read.bind(frame))


func _on_map_read(floats: PackedByteArray, map: String, frame: StereoFrame) -> void:
	frame.maps[map] = floats
	frame.part_arrived()


func _on_segmentation_read(pixels: PackedByteArray, frame: StereoFrame) -> void:
	frame.images["segmentation"] = Image.create_from_data(
		frame.size_px.x, frame.size_px.y, false, Image.FORMAT_RGBA8, pixels
	)
	frame.part_arrived()


static func _nothing_but_labels() -> Environment:
	var dark := Environment.new()
	dark.background_mode = Environment.BG_COLOR
	dark.background_color = Color.BLACK
	dark.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	dark.ambient_light_color = Color.BLACK
	return dark
