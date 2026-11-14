class_name InstrumentScales
extends RefCounted
## What the cockpit's instruments show for the vehicle's motion: needle and steering wheel
## angles from the scales a vehicle pack gives. Pure.

const SECONDS_PER_MINUTE := 60.0


static func dial_angle_deg(dial: Array[Vector2], reading: float) -> float:
	## The needle's angle for `reading` on a dial given as (reading, degrees) marks in rising
	## order: straight between two marks, stopped at the dial's ends beyond them.
	if reading <= dial[0].x:
		return dial[0].y
	for index in range(1, dial.size()):
		if reading <= dial[index].x:
			var below := dial[index - 1]
			var above := dial[index]
			return lerpf(below.y, above.y, (reading - below.x) / (above.x - below.x))
	return dial[-1].y


static func motor_rpm(
	speed_m_s: float, wheel_radius_m: float, motor_to_wheel_ratio: float
) -> float:
	## The motor's speed when the wheels roll at `speed_m_s`, either way.
	var wheel_turns_per_s := absf(speed_m_s) / (TAU * wheel_radius_m)
	return wheel_turns_per_s * SECONDS_PER_MINUTE * motor_to_wheel_ratio


static func rev_counter_angle_deg(rpm: float, deg_per_rpm: float, max_rpm: float) -> float:
	## The rev counter's needle angle, stopped at its last mark.
	return clampf(rpm, 0.0, max_rpm) * deg_per_rpm


static func steering_wheel_angle_deg(steering_rad: float, ratio: float, lock_deg: float) -> float:
	## The steering wheel's angle for the front wheels' (positive left), within its lock.
	return clampf(rad_to_deg(steering_rad) * ratio, -lock_deg, lock_deg)


static func turned(rest: Basis, axis: Vector3, angle_deg: float) -> Basis:
	## `rest` turned by `angle_deg` about `axis`, by the right-hand rule.
	return Basis(axis.normalized(), deg_to_rad(angle_deg)) * rest
