class_name StereoCamera
extends Node
## A rectified stereo pair on a vehicle: two parallel pinhole cameras with the same intrinsics,
## a horizontal baseline apart, each rendering into its own viewport of the vehicle's world.
## Depth from disparity d is fx * baseline / d.

const NEAR_M := 0.05
const FAR_M := 3000.0
const MOUNT_PRECISION_M := 1e-6  # Vector3 is single precision
## Where a camera sits along the vehicle's +X, its left, in half baselines.
const LEFT := 1.0
const RIGHT := -1.0

var optics: VehicleSpec.StereoOptics
var viewports: Array[SubViewport] = []  ## left, right
var cameras: Array[Camera3D] = []  ## left, right

var _ground_truth: GroundTruthCamera = null


func setup(vehicle: Node3D, stereo_optics: VehicleSpec.StereoOptics) -> void:
	## Mounts the pair on `vehicle` as `stereo_optics` places it.
	optics = stereo_optics
	name = "StereoCamera"
	for side in [LEFT, RIGHT]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(optics.width_px, optics.height_px)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var camera := Camera3D.new()
		viewport.add_child(camera)
		add_child(viewport)
		camera.current = true
		_hold(vehicle, camera, side)
		if optics.looks_like_a_camera():
			# The view is drawn as wide as the lens sees, then brought to the image's size.
			viewport.scaling_3d_scale = optics.overscan()
			camera.compositor = Compositor.new()
			camera.compositor.compositor_effects = [
				CameraEffect.new(optics, viewports.size(), _frames_per_s())
			]
		viewports.append(viewport)
		cameras.append(camera)


func add_ground_truth(vehicle: Node3D) -> String:
	## Draws the ground truth of the left camera's image from now on, for the frames
	## `request_next_frame` is asked; returns why it cannot, or "".
	if RenderingServer.get_rendering_device() == null:
		return "ground truth needs a renderer with a rendering device (Forward+)"
	_ground_truth = GroundTruthCamera.new()
	add_child(_ground_truth)
	_ground_truth.setup(optics, intrinsics(optics)["fx"])
	_hold(vehicle, _ground_truth.camera, LEFT)
	return ""


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


static func disparity_px(stereo_optics: VehicleSpec.StereoOptics, depth_m: float) -> float:
	## How far apart, in pixels, the two cameras see a point `depth_m` along the optical axis.
	return intrinsics(stereo_optics)["fx"] * stereo_optics.baseline_m / depth_m


static func calibration(stereo_optics: VehicleSpec.StereoOptics) -> Dictionary:
	## What a recording's calib.json tells of the pair: its intrinsics, its lens's distortion
	## and where it sits.
	var described := intrinsics(stereo_optics)
	var lens := stereo_optics.distortion
	described["distortion_model"] = "OpenCV: k1, k2, p1, p2, k3"
	described["distortion_coefficients"] = (
		lens.coefficients() if lens != null else [0.0, 0.0, 0.0, 0.0, 0.0]
	)
	described["mount_m"] = LinkProtocol.to_ros(stereo_optics.mount).map(
		func(metres): return snappedf(metres, MOUNT_PRECISION_M)
	)
	described["pitch_down_deg"] = stereo_optics.pitch_deg
	described["camera_frame"] = "OpenCV: x right, y down, z forward; right = left + baseline along x"
	described["mount_frame"] = "ROS base_link: x forward, y left, z up; midway between the cameras"
	return described


static func calibration_with_ground_truth(stereo_optics: VehicleSpec.StereoOptics) -> Dictionary:
	## `calibration`, and what the ground truth recorded with each pair holds.
	var described := calibration(stereo_optics)
	described["ground_truth"] = {
		"pixels": "those of the left image, distorted as it is",
		"depth": "float32 metres along the left camera's optical axis; 0 where there is only sky",
		"disparity":
		"float32 pixels between the rectified images, fx * baseline_m / depth; 0 where there is only sky",
		"segmentation_classes": Segmentation.described(),
	}
	return described


func described() -> Dictionary:
	## The calibration of what this camera hands over.
	return calibration_with_ground_truth(optics) if _ground_truth != null else calibration(optics)


func request_next_frame(deliver: Callable) -> void:
	## Calls `deliver` with the StereoFrame the frame about to be drawn shows: the pair and,
	## with ground truth, its maps. They are read back from the GPU within a few frames.
	if _ground_truth != null:
		_ground_truth.draw_next_frame()
	await RenderingServer.frame_post_draw
	var frame := StereoFrame.new(viewports[0].size)
	frame.deliver_after(1 if _ground_truth == null else 4, deliver)
	if _ground_truth != null:
		_ground_truth.read_into(frame)
	request_pair(_on_pair_read.bind(frame))


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


func _on_pair_read(pair: Array[Image], frame: StereoFrame) -> void:
	frame.images["left"] = pair[0]
	frame.images["right"] = pair[1]
	frame.part_arrived()


func _hold(vehicle: Node3D, camera: Camera3D, side: float) -> void:
	## Keeps `camera` on `vehicle` where the pair's camera of `side` sits, looking forward.
	camera.keep_aspect = Camera3D.KEEP_WIDTH  # fov is horizontal
	camera.fov = rad_to_deg(2.0 * atan(optics.half_extent().x * optics.overscan()))
	camera.near = NEAR_M
	camera.far = FAR_M
	var holder := RemoteTransform3D.new()
	holder.position = optics.mount + Vector3(side * optics.baseline_m * 0.5, 0.0, 0.0)
	holder.basis = Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, -deg_to_rad(optics.pitch_deg))
	vehicle.add_child(holder)
	holder.remote_path = holder.get_path_to(camera)


static func _frames_per_s() -> float:
	return Engine.max_fps if Engine.max_fps > 0 else Engine.physics_ticks_per_second
