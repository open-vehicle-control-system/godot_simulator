class_name GroundTruthEffect
extends CompositorEffect
## Turns what the ground truth camera drew into the frame's ground truth, on the GPU: its
## depth buffer into metres and disparity, the labels its surfaces show into class colours,
## each pixel that of the left camera's image, lens distortion included. The three textures
## are read back by whoever records them.

const SHADER_PATH := "res://sensors/shaders/ground_truth.comp"
## What a labelled surface writes (label.gdshaderinc): its class times the step, and the mark.
const LABELLED_MARK := 1024.0
const CLASS_STEP := 16.0
## The mark left of a label under something transparent, below which the label is not read.
const FAINTEST_MARK := 32.0
const GROUP_PX := 8
const MAX_CLASSES := 16
const NO_DISTORTION := [0.0, 0.0, 0.0, 0.0, 0.0]
## Push constants come in blocks of 16 bytes.
const PUSH_CONSTANT_FLOATS := 32

var depth_m := RID()  ## R32F
var disparity_px := RID()  ## R32F
var segmentation := RID()  ## RGBA8
var size_px := Vector2i.ZERO  ## the image's, which the view drawn may be wider than

var _optics: VehicleSpec.StereoOptics
var _focal_px_times_baseline_m: float
var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _class_colours: RID


func _init(optics: VehicleSpec.StereoOptics = null, focal_px := 0.0) -> void:
	## The ground truth of the image of `optics`, whose pinhole focuses at `focal_px`.
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_device = RenderingServer.get_rendering_device()
	if _device == null or optics == null:
		return
	_optics = optics
	_focal_px_times_baseline_m = focal_px * optics.baseline_m
	size_px = Vector2i(optics.width_px, optics.height_px)
	depth_m = _texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	disparity_px = _texture(RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	segmentation = _texture(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_shader = ComputeShader.compile(_device, SHADER_PATH)
	_pipeline = _device.compute_pipeline_create(_shader)
	_sampler = _device.sampler_create(RDSamplerState.new())
	var colours := PackedFloat32Array()
	colours.resize(4 * MAX_CLASSES)
	for class_id in Segmentation.CLASSES.size():
		var colour: Array = Segmentation.CLASSES[class_id]["colour"]
		for channel in 3:
			colours[4 * class_id + channel] = colour[channel] / 255.0
	_class_colours = _device.uniform_buffer_create(4 * colours.size(), colours.to_byte_array())


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _device == null:
		return
	for resource in [depth_m, disparity_px, segmentation, _class_colours, _sampler, _shader]:
		if resource.is_valid():
			_device.free_rid(resource)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or _device == null:
		return
	var uniforms: Array[RDUniform] = [
		_sampled(0, buffers.get_depth_layer(0)),
		_sampled(1, buffers.get_color_layer(0)),
		_bound(2, RenderingDevice.UNIFORM_TYPE_IMAGE, depth_m),
		_bound(3, RenderingDevice.UNIFORM_TYPE_IMAGE, disparity_px),
		_bound(4, RenderingDevice.UNIFORM_TYPE_IMAGE, segmentation),
		_bound(5, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, _class_colours),
	]
	var constants := _camera_constants(render_data.get_render_scene_data().get_cam_projection())
	var compute := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(compute, _pipeline)
	_device.compute_list_bind_uniform_set(
		compute, UniformSetCacheRD.get_cache(_shader, 0, uniforms), 0
	)
	_device.compute_list_set_push_constant(compute, constants, constants.size())
	_device.compute_list_dispatch(
		compute, ceili(float(size_px.x) / GROUP_PX), ceili(float(size_px.y) / GROUP_PX), 1
	)
	_device.compute_list_end()


func _camera_constants(projection: Projection) -> PackedByteArray:
	var inverse := projection.inverse()
	var constants := PackedFloat32Array()
	for column in 4:
		for row in 4:
			constants.append(inverse[column][row])
	constants.append(_focal_px_times_baseline_m)
	constants.append(LABELLED_MARK / CLASS_STEP)
	constants.append(FAINTEST_MARK)
	constants.append(Segmentation.UNLABELLED)
	var lens: Array = _optics.distortion.coefficients() if _optics.distortion else NO_DISTORTION
	var half_extent := _optics.half_extent()
	constants.append_array(lens.slice(0, 4))
	constants.append_array([lens[4], _optics.overscan(), half_extent.x, half_extent.y])
	constants.append(Segmentation.SKY)
	constants.resize(PUSH_CONSTANT_FLOATS)
	return constants.to_byte_array()


func _texture(format: RenderingDevice.DataFormat) -> RID:
	var described := RDTextureFormat.new()
	described.format = format
	described.width = size_px.x
	described.height = size_px.y
	described.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return _device.texture_create(described, RDTextureView.new())


func _sampled(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


func _bound(binding: int, type: RenderingDevice.UniformType, resource: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(resource)
	return uniform
