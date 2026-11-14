class_name StereoCamera
extends Node
## A rectified stereo pair on a vehicle: two parallel pinhole cameras with the same intrinsics,
## a horizontal baseline apart, each rendering into its own viewport of the vehicle's world.
## Depth from disparity d is fx * baseline / d.

const NEAR_M := 0.05
const FAR_M := 3000.0

var optics: VehicleSpec.StereoOptics
var viewports: Array[SubViewport] = []  ## left, right
var cameras: Array[Camera3D] = []  ## left, right


func setup(vehicle: Node3D, stereo_optics: VehicleSpec.StereoOptics) -> void:
	## Mounts the pair on `vehicle` as `stereo_optics` places it.
	optics = stereo_optics
	name = "StereoCamera"
	var looking_forward := (
		Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, -deg_to_rad(optics.pitch_deg))
	)
	for side in [1.0, -1.0]:  # left (+X in the vehicle frame), then right
		var viewport := SubViewport.new()
		viewport.size = Vector2i(optics.width_px, optics.height_px)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var camera := Camera3D.new()
		camera.keep_aspect = Camera3D.KEEP_WIDTH  # fov is horizontal
		camera.fov = optics.hfov_deg
		camera.near = NEAR_M
		camera.far = FAR_M
		viewport.add_child(camera)
		add_child(viewport)
		camera.current = true
		var holder := RemoteTransform3D.new()
		holder.position = optics.mount + Vector3(side * optics.baseline_m * 0.5, 0.0, 0.0)
		holder.basis = looking_forward
		vehicle.add_child(holder)
		holder.remote_path = holder.get_path_to(camera)
		viewports.append(viewport)
		cameras.append(camera)


static func intrinsics(stereo_optics: VehicleSpec.StereoOptics) -> Dictionary:
	## The pinhole intrinsics, in pixels, shared by both cameras.
	var focal_px := stereo_optics.width_px * 0.5 / tan(deg_to_rad(stereo_optics.hfov_deg) * 0.5)
	return {
		"width": stereo_optics.width_px,
		"height": stereo_optics.height_px,
		"fx": focal_px,
		"fy": focal_px,
		# OpenCV puts pixel centres on integers
		"cx": (stereo_optics.width_px - 1) * 0.5,
		"cy": (stereo_optics.height_px - 1) * 0.5,
		"baseline_m": stereo_optics.baseline_m,
		"hfov_deg": stereo_optics.hfov_deg,
		"vfov_deg": rad_to_deg(2.0 * atan(stereo_optics.height_px * 0.5 / focal_px)),
	}


func request_pair(deliver: Callable) -> void:
	## Calls `deliver` with the left and right images rendered last. Where the renderer can
	## read a texture back later, it does so within a few frames, without making this frame
	## wait for the GPU to finish the last one; else at once.
	var device := RenderingServer.get_rendering_device()
	if device == null:
		deliver.call(capture())
		return
	var pair: Array[Image] = [null, null]
	for side in viewports.size():
		var drawn := RenderingServer.texture_get_rd_texture(viewports[side].get_texture().get_rid())
		device.texture_get_data_async(drawn, 0, _on_read_back.bind(side, pair, deliver))


func capture() -> Array[Image]:
	## The left and right images rendered last.
	return [viewports[0].get_texture().get_image(), viewports[1].get_texture().get_image()]


func _on_read_back(
	pixels: PackedByteArray, side: int, pair: Array[Image], deliver: Callable
) -> void:
	var size := viewports[side].size
	pair[side] = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, pixels)
	if pair[0] != null and pair[1] != null and deliver.is_valid():
		deliver.call(pair)
