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


## A pinhole camera sees less than half the world.
const MAX_FIELD_OF_VIEW_DEG := 180.0

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


func wheelbase_m() -> float:
	## The distance between the axles.
	return front_axle_z - rear_axle_z
