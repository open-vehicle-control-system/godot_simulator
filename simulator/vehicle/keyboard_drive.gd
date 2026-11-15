class_name KeyboardDrive
extends RefCounted
## The actuation the arrow keys ask for, for driving a track without OVCS (--keyboard). Pure.
##
## Up is full throttle through the vehicle's powertrain (Powertrain: its motor's torque in the
## gear in use, nothing past its rpm limit), Down brakes and, once stopped, reverses in first
## gear up to MAX_REVERSE_SPEED_M_S; Left and Right steer, less at speed, and the steering
## returns to centre when released. With no key the vehicle coasts, and stopped it is held.

## The brakes' deceleration, as a share of g on the vehicle's mass.
const BRAKING_G := 0.8
const MAX_REVERSE_SPEED_M_S := 4.0
const MAX_STEERING_RAD := 0.5
const STEERING_RATE_RAD_S := 1.2
## At this speed and above the steering lock has shrunk to STEERING_SHARE_AT_FADE_SPEED of
## MAX_STEERING_RAD: enough left to steer into a slide.
const STEERING_FADE_SPEED_M_S := 50.0
const STEERING_SHARE_AT_FADE_SPEED := 0.4
## Below this speed Down reverses instead of braking, and no key holds the vehicle.
const STOPPED_M_S := 0.3


static func next(
	steering_rad: float,
	speed_m_s: float,
	wheel_speed_rad_s: float,
	keys: Dictionary,
	delta_s: float,
	spec: VehicleSpec
) -> Actuation:
	## The actuation after `delta_s` with `keys` held (`up`, `down`, `left`, `right`: true when
	## held), from the front wheels at `steering_rad`, the vehicle going at `speed_m_s` and its
	## driven wheels turning at `wheel_speed_rad_s`.
	var up: bool = keys.get("up", false)
	var down: bool = keys.get("down", false)
	# The gearbox turns with the wheels, which slip: the gear is the wheels' speed's.
	var gear := Powertrain.gear_at(spec, wheel_speed_rad_s * spec.wheel_radius_m)
	var braking_n_m := BRAKING_G * spec.mass_kg * Vehicle.GRAVITY_M_S2 * spec.wheel_radius_m
	var drive_n_m := 0.0
	var brake_n_m := 0.0
	if up and speed_m_s < -STOPPED_M_S:
		brake_n_m = braking_n_m
	elif up:
		drive_n_m = Powertrain.wheel_torque_n_m(spec, gear, wheel_speed_rad_s)
	elif down and speed_m_s > STOPPED_M_S:
		brake_n_m = braking_n_m
	elif down:
		gear = 1
		if speed_m_s > -MAX_REVERSE_SPEED_M_S:
			drive_n_m = -Powertrain.wheel_torque_n_m(spec, gear, wheel_speed_rad_s)
	elif absf(speed_m_s) < STOPPED_M_S:
		brake_n_m = braking_n_m
	return Actuation.of(
		drive_n_m,
		brake_n_m,
		_next_steering(steering_rad, speed_m_s, keys, delta_s),
		Powertrain.driveline_inertia_kg_m2(spec, gear)
	)


static func _next_steering(
	steering_rad: float, speed_m_s: float, keys: Dictionary, delta_s: float
) -> float:
	var speed_share := clampf(absf(speed_m_s) / STEERING_FADE_SPEED_M_S, 0.0, 1.0)
	var lock_rad := MAX_STEERING_RAD * lerpf(1.0, STEERING_SHARE_AT_FADE_SPEED, speed_share)
	var target_rad := 0.0
	if keys.get("left", false):
		target_rad += lock_rad
	if keys.get("right", false):
		target_rad -= lock_rad
	return move_toward(steering_rad, target_rad, STEERING_RATE_RAD_S * delta_s)
