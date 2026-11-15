class_name BicycleModel
extends RefCounted
## Planar kinematic bicycle model about the rear axle: how the vehicle turns when its tyres do
## not slip, which DynamicBicycle blends into below walking pace. Pure.
##
## Yaw is about +Y, from +Z (forward) towards +X (left): positive steering turns left.


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
