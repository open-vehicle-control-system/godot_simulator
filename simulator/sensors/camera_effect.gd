class_name CameraEffect
extends CompositorEffect
## Makes the view of one stereo camera the image of a camera, as the vehicle pack's stereo
## optics tell: lens distortion, motion blur, vignetting, sensor noise and an exposure that
## adapts, in scene light, before tone mapping (see camera.comp). The view is drawn wider than
## the image by the optics' overscan, so a distorted image is filled to its corners.

const SHADER_PATH := "res://sensors/shaders/camera.comp"
const GROUP_PX := 8
const PASS_METER := 0.0
const PASS_CAMERA := 1.0
const PASS_COPY := 2.0
const SCRATCH_CONTEXT := &"camera_effect"
const SCRATCH_NAME := &"image"
const NO_DISTORTION := [0.0, 0.0, 0.0, 0.0, 0.0]

var _optics: VehicleSpec.StereoOptics
var _camera_index: int
var _frame_s: float
var _frame := 0
var _previous_view := Transform3D.IDENTITY
var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
var _linear: RID
var _nearest: RID
var _exposure_gain: RID
var _camera_block: RID


func _init(
	optics: VehicleSpec.StereoOptics = null, camera_index := 0, frames_per_s := 60.0
) -> void:
	## The effect of `optics` on the camera numbered `camera_index`, whose noise is its own,
	## drawn `frames_per_s` times a second.
	_optics = optics
	_camera_index = camera_index
	_frame_s = 1.0 / frames_per_s
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	_device = RenderingServer.get_rendering_device()
	if _device == null or optics == null:
		return
	needs_motion_vectors = optics.shutter_s > 0.0
	_shader = ComputeShader.compile(_device, SHADER_PATH)
	_pipeline = _device.compute_pipeline_create(_shader)
	var linear := RDSamplerState.new()
	linear.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_linear = _device.sampler_create(linear)
	_nearest = _device.sampler_create(RDSamplerState.new())
	var one_pixel := RDTextureFormat.new()
	one_pixel.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	one_pixel.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	_exposure_gain = _device.texture_create(
		one_pixel, RDTextureView.new(), [PackedFloat32Array([0.0]).to_byte_array()]
	)
	var block := camera_block(optics, Transform3D.IDENTITY, 0, 0, 1.0)
	_camera_block = _device.uniform_buffer_create(block.size(), block)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _device == null:
		return
	for resource in [_exposure_gain, _camera_block, _linear, _nearest, _shader]:
		if resource.is_valid():
			_device.free_rid(resource)


static func camera_block(
	optics: VehicleSpec.StereoOptics,
	to_previous_view: Transform3D,
	frame: int,
	camera_index: int,
	frame_s: float
) -> PackedByteArray:
	## The `Camera` block of camera.comp for one frame.
	var floats := PackedFloat32Array()
	var to_previous := Projection(to_previous_view)
	for column in 4:
		for row in 4:
			floats.append(to_previous[column][row])
	var lens: Array = optics.distortion.coefficients() if optics.distortion else NO_DISTORTION
	var half_extent := optics.half_extent()
	floats.append_array(lens.slice(0, 4))
	floats.append_array([lens[4], optics.overscan(), half_extent.x, half_extent.y])
	floats.append_array(
		[optics.vignetting, optics.read_noise, optics.shot_noise, optics.shutter_s / frame_s]
	)
	(
		floats
		. append_array(
			[
				optics.exposure_target,
				1.0 - exp(-optics.exposure_speed_per_s * frame_s),
				pow(2.0, optics.exposure_max_stops),
				1.0 if optics.exposure_target > 0.0 else 0.0,
			]
		)
	)
	floats.append_array([frame, camera_index, 0.0, 0.0])
	return floats.to_byte_array()


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or _device == null:
		return
	var scene := render_data.get_render_scene_data()
	var view := scene.get_cam_transform().affine_inverse()
	var block := camera_block(
		_optics,
		_previous_view * scene.get_cam_transform() if _frame > 0 else Transform3D.IDENTITY,
		_frame,
		_camera_index,
		_frame_s
	)
	_device.buffer_update(_camera_block, 0, block.size(), block)
	_previous_view = view
	_frame += 1
	var size_px := buffers.get_internal_size()
	if not buffers.has_texture(SCRATCH_CONTEXT, SCRATCH_NAME):
		buffers.create_texture(
			SCRATCH_CONTEXT,
			SCRATCH_NAME,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1,
			size_px,
			1,
			1,
			true,
			false
		)
	var scratch := buffers.get_texture(SCRATCH_CONTEXT, SCRATCH_NAME)
	var colour := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	var velocity := buffers.get_velocity_layer(0) if needs_motion_vectors else depth
	if _optics.exposure_target > 0.0:
		_run(PASS_METER, Vector2i.ONE, scratch, colour, depth, velocity)
	_run(PASS_CAMERA, size_px, scratch, colour, depth, velocity)
	_run(PASS_COPY, size_px, colour, scratch, depth, velocity)


func _run(
	kind: float, size_px: Vector2i, target: RID, source: RID, depth: RID, velocity: RID
) -> void:
	var uniforms: Array[RDUniform] = [
		_bound(0, RenderingDevice.UNIFORM_TYPE_IMAGE, [target]),
		_bound(1, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_linear, source]),
		_bound(2, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_nearest, depth]),
		_bound(3, RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, [_nearest, velocity]),
		_bound(4, RenderingDevice.UNIFORM_TYPE_IMAGE, [_exposure_gain]),
		_bound(5, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, [_camera_block]),
	]
	var constants := PackedFloat32Array([kind, 0.0, 0.0, 0.0]).to_byte_array()
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


static func _bound(binding: int, type: RenderingDevice.UniformType, resources: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for resource: RID in resources:
		uniform.add_id(resource)
	return uniform
