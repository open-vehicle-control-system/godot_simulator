class_name ViewPoses
extends RefCounted
## Where each view looks from, relative to the vehicle. Pure. Distances are fractions of the
## vehicle's length, so every view frames any vehicle the same way.

const VIEWS: Array[String] = ["chase", "cockpit", "bonnet", "side", "front"]
const CHASE_BEHIND := 1.33
const CHASE_ABOVE := 0.49
const CHASE_AIM_AHEAD := 1.02
const CHASE_AIM_ABOVE := 0.23
const BONNET_ABOVE := 0.29
const BONNET_AHEAD := 0.26
const SIDE_LEFT := 1.4
const SIDE_ABOVE := 0.31
const FRONT_AHEAD := 1.53
const FRONT_ABOVE := 0.38
const OUTSIDE_AIM_ABOVE := 0.18


static func pose(
	view: String, vehicle: Transform3D, spec: VehicleSpec, chase_heading: Vector3
) -> Transform3D:
	## The view's camera pose. `chase_heading` is the horizontal direction the outside views
	## follow, smoothed by the caller so they swing gently through corners.
	var length_m := spec.body_size.z
	var forward := vehicle.basis.z
	var up := vehicle.basis.y
	match view:
		"cockpit":
			var looking := Basis.looking_at(forward, up)
			looking = looking.rotated(looking.x, deg_to_rad(spec.driver_pitch_deg))
			return Transform3D(looking, vehicle * spec.driver_eye)
		"bonnet":
			var eye := vehicle.origin + (up * BONNET_ABOVE + forward * BONNET_AHEAD) * length_m
			return Transform3D(Basis.looking_at(forward, up), eye)
		"side":
			var left := Vector3.UP.cross(chase_heading).normalized()
			return _looking_at(
				vehicle.origin + (left * SIDE_LEFT + Vector3.UP * SIDE_ABOVE) * length_m,
				vehicle.origin + Vector3.UP * OUTSIDE_AIM_ABOVE * length_m
			)
		"front":
			return _looking_at(
				(
					vehicle.origin
					+ (chase_heading * FRONT_AHEAD + Vector3.UP * FRONT_ABOVE) * length_m
				),
				vehicle.origin + Vector3.UP * OUTSIDE_AIM_ABOVE * length_m
			)
		_:
			return _looking_at(
				(
					vehicle.origin
					+ (-chase_heading * CHASE_BEHIND + Vector3.UP * CHASE_ABOVE) * length_m
				),
				(
					vehicle.origin
					+ (chase_heading * CHASE_AIM_AHEAD + Vector3.UP * CHASE_AIM_ABOVE) * length_m
				)
			)


static func sees_mirrors(view: String) -> bool:
	## True for the views from the driver's seat, where the mirrors show what is behind.
	return view == "cockpit"


static func next_view(view: String) -> String:
	## The view after `view`, cycling.
	return VIEWS[(VIEWS.find(view) + 1) % VIEWS.size()]


static func _looking_at(eye: Vector3, target: Vector3) -> Transform3D:
	return Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)
