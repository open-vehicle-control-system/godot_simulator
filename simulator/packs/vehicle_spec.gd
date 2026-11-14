class_name VehicleSpec
extends RefCounted
## A vehicle pack's contents, in Godot's vehicle frame: +X left, +Y up, +Z forward, the origin
## on the ground. pack.json gives them in ROS base_link (x forward, y left, z up).


## A rectified stereo pair: two parallel pinhole cameras a baseline apart.
class StereoOptics:
	extends RefCounted
	var mount: Vector3  ## midway between the cameras
	var width_px: int
	var height_px: int
	var hfov_deg: float
	var baseline_m: float
	var pitch_deg: float  ## downwards
	var rate_hz: float
	var distortion: LensDistortion = null  ## null for a pinhole
	var vignetting := 0.0  ## the share of the light lost in the image's corners
	var read_noise := 0.0  ## the sensor noise's deviation in the dark, in scene light
	var shot_noise := 0.0  ## the deviation the noise gains per square root of scene light
	var exposure_target := 0.0  ## the mean scene light the exposure adapts to; 0 for fixed
	var exposure_speed_per_s := 0.0
	var exposure_max_stops := 0.0  ## how far the exposure moves either way
	var shutter_s := 0.0  ## how long a frame gathers light: 0 for no motion blur

	func looks_like_a_camera() -> bool:
		## True when an image of this pair is more than what a pinhole shows.
		return (
			distortion != null
			or vignetting > 0.0
			or read_noise > 0.0
			or shot_noise > 0.0
			or exposure_target > 0.0
			or shutter_s > 0.0
		)

	func half_extent() -> Vector2:
		## How far the image reaches from its centre, in focal lengths.
		var half_width := tan(deg_to_rad(hfov_deg) * 0.5)
		return Vector2(half_width, half_width * height_px / width_px)

	func overscan() -> float:
		## How many times wider than the image's pinhole the view drawn for it must be.
		return distortion.overscan(half_extent()) if distortion != null else 1.0


## A pinhole camera sees less than half the world.
const MAX_FIELD_OF_VIEW_DEG := 180.0
## The widest the view drawn for a distorted image is, in images.
const MAX_OVERSCAN := 2.0

var id: String
var name: String
var directory: String
var model_path := ""  ## the glTF model, or "" for a box and cylinders
var front_axle_z: float
var rear_axle_z: float
var front_track_m: float
var rear_track_m: float
var wheel_radius_m: float
var wheel_width_m: float
var max_lateral_acceleration_m_s2: float  ## the tyres' grip: the hardest the vehicle corners
var body_size: Vector3
var body_centre: Vector3
var driver_eye: Vector3
var driver_pitch_deg: float
var stereo := StereoOptics.new()
var instruments: InstrumentsSpec = null  ## null when the pack has no `instruments`
var mirrors: MirrorsSpec = null  ## null when the pack has no `mirrors`


static func parse(manifest: Dictionary, directory: String) -> Dictionary:
	## `{"vehicle": VehicleSpec}` from a vehicle pack's manifest, or `{"error": reason}`.
	var reader := ManifestReader.new(manifest["id"], manifest)
	var spec := VehicleSpec.new()
	spec.id = manifest["id"]
	spec.directory = directory
	spec.name = reader.text("name")
	if reader.has("vehicle.model"):
		spec.model_path = directory.path_join(reader.text("vehicle.model"))
	spec.front_axle_z = reader.number("vehicle.front_axle_x_m")
	spec.rear_axle_z = reader.number("vehicle.rear_axle_x_m")
	reader.check(spec.front_axle_z > spec.rear_axle_z, "vehicle.front_axle_x_m")
	spec.front_track_m = reader.positive("vehicle.front_track_m")
	spec.rear_track_m = reader.positive("vehicle.rear_track_m")
	spec.wheel_radius_m = reader.positive("vehicle.wheel_radius_m")
	spec.wheel_width_m = reader.positive("vehicle.wheel_width_m")
	spec.max_lateral_acceleration_m_s2 = reader.positive("vehicle.max_lateral_acceleration_m_s2")
	spec.body_size = reader.ros_vector("vehicle.body.size_m")
	spec.body_centre = reader.ros_vector("vehicle.body.centre_m")
	spec.driver_eye = reader.ros_vector("vehicle.driver_eye_m")
	spec.driver_pitch_deg = reader.number("vehicle.driver_pitch_deg")
	spec.stereo.mount = reader.ros_vector("vehicle.stereo.mount_m")
	spec.stereo.width_px = int(reader.positive("vehicle.stereo.width_px"))
	spec.stereo.height_px = int(reader.positive("vehicle.stereo.height_px"))
	spec.stereo.hfov_deg = reader.positive("vehicle.stereo.hfov_deg", MAX_FIELD_OF_VIEW_DEG)
	spec.stereo.baseline_m = reader.positive("vehicle.stereo.baseline_m")
	spec.stereo.pitch_deg = reader.number("vehicle.stereo.pitch_deg")
	spec.stereo.rate_hz = reader.positive("vehicle.stereo.rate_hz")
	spec._read_camera_effects(reader)
	var vehicle_section: Variant = manifest.get("vehicle")
	var reader_within_vehicle := ManifestReader.new(
		manifest["id"], vehicle_section if vehicle_section is Dictionary else {}, "vehicle."
	)
	if reader.has("vehicle.instruments"):
		spec.instruments = InstrumentsSpec.parse(reader_within_vehicle)
	if reader.has("vehicle.mirrors"):
		spec.mirrors = MirrorsSpec.parse(reader_within_vehicle)
	if reader.error == "":
		reader.error = reader_within_vehicle.error
	if reader.error != "":
		return {"error": reader.error}
	return {"vehicle": spec}


func _read_camera_effects(reader: ManifestReader) -> void:
	## What makes the stereo pair's images those of cameras: each is off when absent.
	if reader.has("vehicle.stereo.distortion"):
		var coefficients := []
		for coefficient in ["k1", "k2", "p1", "p2", "k3"]:
			coefficients.append(reader.number("vehicle.stereo.distortion.%s" % coefficient))
		stereo.distortion = LensDistortion.new(coefficients)
		reader.check(
			(
				reader.error != ""
				or (
					not stereo.distortion.folds(stereo.half_extent())
					and stereo.overscan() <= MAX_OVERSCAN
				)
			),
			"vehicle.stereo.distortion"
		)
	if reader.has("vehicle.stereo.vignetting"):
		stereo.vignetting = reader.positive("vehicle.stereo.vignetting", 1.0)
	if reader.has("vehicle.stereo.noise"):
		stereo.read_noise = reader.number("vehicle.stereo.noise.read")
		reader.check(stereo.read_noise >= 0.0, "vehicle.stereo.noise.read")
		stereo.shot_noise = reader.number("vehicle.stereo.noise.shot")
		reader.check(stereo.shot_noise >= 0.0, "vehicle.stereo.noise.shot")
	if reader.has("vehicle.stereo.exposure"):
		stereo.exposure_target = reader.positive("vehicle.stereo.exposure.target")
		stereo.exposure_speed_per_s = reader.positive("vehicle.stereo.exposure.speed_per_s")
		stereo.exposure_max_stops = reader.positive("vehicle.stereo.exposure.max_stops")
	if reader.has("vehicle.stereo.motion_blur"):
		stereo.shutter_s = reader.positive("vehicle.stereo.motion_blur.shutter_s")


func wheelbase_m() -> float:
	## The distance between the axles.
	return front_axle_z - rear_axle_z
