class_name BicycleModel
extends RefCounted
## Planar kinematic bicycle model about the rear axle. Pure.
##
## Yaw is about +Y, from +Z (forward) towards +X (left): positive steering turns left.


static func advance(
	motion: Dictionary, speed_m_s: float, steering_rad: float, wheelbase_m: float, delta_s: float
) -> Dictionary:
	## `motion` (`rear_axle`, `yaw_rad`) after `delta_s` at this speed and steering, with the
	## `yaw_rate_rad_s` it turned at.
	var yaw_rate_rad_s := speed_m_s * tan(steering_rad) / wheelbase_m
	var yaw_rad: float = motion["yaw_rad"]
	var rear_axle: Vector3 = motion["rear_axle"] + heading(yaw_rad) * speed_m_s * delta_s
	return {
		"rear_axle": rear_axle,
		"yaw_rad": yaw_rad + yaw_rate_rad_s * delta_s,
		"yaw_rate_rad_s": yaw_rate_rad_s,
	}


static func grip_limited_steering(
	steering_rad: float, speed_m_s: float, wheelbase_m: float, max_lateral_acceleration_m_s2: float
) -> float:
	## The steering the vehicle actually turns by: `steering_rad`, unless that would corner harder
	## than the tyres grip, in which case the turn whose lateral acceleration is the grip. Beyond
	## the grip the front wheels slide and the vehicle runs wide.
	var demanded_m_s2 := speed_m_s * speed_m_s * absf(tan(steering_rad)) / wheelbase_m
	if demanded_m_s2 <= max_lateral_acceleration_m_s2:
		return steering_rad
	var gripped_rad := atan(max_lateral_acceleration_m_s2 * wheelbase_m / (speed_m_s * speed_m_s))
	return signf(steering_rad) * gripped_rad


static func heading(yaw_rad: float) -> Vector3:
	## The horizontal unit vector the vehicle faces at `yaw_rad`.
	return Vector3(sin(yaw_rad), 0.0, cos(yaw_rad))
