class_name SpeedControl
extends RefCounted
## Drive and brake torques that hold a vehicle at a commanded speed: what --hold and
## --drive-log drive by. A proportional-integral control of the speed, with the air's and
## rolling's resistance fed forward; the motor pushes either way, the brakes slow the vehicle
## down, and a vehicle stopped with standstill commanded is parked. It knows no limit of the
## vehicle's powertrain: it is a test driver, not a model of one.

const GAIN_PER_S := 3.0
const INTEGRAL_GAIN_PER_S2 := 1.0
## Within what a front-driven car on road tyres passes on, so its wheels do not spin.
const MAX_ACCELERATION_M_S2 := 3.0
## The most the integral adds: enough for a steep slope, little to unwind when the vehicle is
## held back (against a wall) and then commanded the other way.
const MAX_INTEGRAL_M_S2 := 2.0
## Below this speed the vehicle counts as stopped.
const STOPPED_M_S := 0.3

var _integral_m := 0.0


func next(
	target_speed_m_s: float,
	steering_rad: float,
	speed_m_s: float,
	delta_s: float,
	spec: VehicleSpec
) -> Actuation:
	## The actuation that brings the vehicle, going at `speed_m_s`, to `target_speed_m_s`
	## (negative reversing) over the next `delta_s`, the front wheels at `steering_rad`.
	var gear := Powertrain.gear_at(spec, speed_m_s)
	var inertia_kg_m2 := Powertrain.driveline_inertia_kg_m2(spec, gear)
	if is_zero_approx(target_speed_m_s) and absf(speed_m_s) < STOPPED_M_S:
		_integral_m = 0.0
		var parking_n_m := (
			Vehicle.PARKING_BRAKE_PER_WEIGHT
			* spec.mass_kg
			* Vehicle.GRAVITY_M_S2
			* spec.wheel_radius_m
		)
		return Actuation.of(0.0, parking_n_m, steering_rad, inertia_kg_m2)
	var error_m_s := target_speed_m_s - speed_m_s
	# The integral grows only while the acceleration asked for is within reach: no windup.
	var asked_m_s2 := GAIN_PER_S * error_m_s + INTEGRAL_GAIN_PER_S2 * _integral_m
	if absf(asked_m_s2) < MAX_ACCELERATION_M_S2:
		var most_m := MAX_INTEGRAL_M_S2 / INTEGRAL_GAIN_PER_S2
		_integral_m = clampf(_integral_m + error_m_s * delta_s, -most_m, most_m)
	var acceleration_m_s2 := clampf(
		GAIN_PER_S * error_m_s + INTEGRAL_GAIN_PER_S2 * _integral_m,
		-MAX_ACCELERATION_M_S2,
		MAX_ACCELERATION_M_S2
	)
	var moving := signf(speed_m_s) if absf(speed_m_s) >= STOPPED_M_S else signf(target_speed_m_s)
	var radius_m := spec.wheel_radius_m
	var torque_n_m := (
		(
			(spec.mass_kg * acceleration_m_s2 + Powertrain.resistance_n(spec, speed_m_s) * moving)
			* radius_m
		)
		+ inertia_kg_m2 * acceleration_m_s2 / radius_m
	)
	if absf(speed_m_s) >= STOPPED_M_S and torque_n_m * speed_m_s < 0.0:
		return Actuation.of(0.0, absf(torque_n_m), steering_rad, inertia_kg_m2)
	return Actuation.of(torque_n_m, 0.0, steering_rad, inertia_kg_m2)
