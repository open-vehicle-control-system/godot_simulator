class_name Actuation
extends RefCounted
## What the vehicle's driver asks of it: OVCS's `actuation` message, or what the keyboard, a
## speed hold or a drive log sets. Absolute values, held until the next.

var drive_torque_n_m := 0.0  ## the driven axles' total at the wheels, positive forward
var brake_torque_n_m := 0.0  ## the brakes' total at the wheels, 0 or more
var steering_rad := 0.0  ## the front wheels' bicycle-equivalent angle, positive left
var driveline_inertia_kg_m2 := 0.0  ## the motor's and gearbox's, at the driven wheels


static func of(
	drive_torque_n_m: float,
	brake_torque_n_m: float,
	steering_rad: float,
	driveline_inertia_kg_m2: float
) -> Actuation:
	var actuation := Actuation.new()
	actuation.drive_torque_n_m = drive_torque_n_m
	actuation.brake_torque_n_m = maxf(brake_torque_n_m, 0.0)
	actuation.steering_rad = steering_rad
	actuation.driveline_inertia_kg_m2 = maxf(driveline_inertia_kg_m2, 0.0)
	return actuation
