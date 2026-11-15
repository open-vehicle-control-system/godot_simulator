class_name Powertrain
extends RefCounted
## What a vehicle's powertrain does at a speed: the force its motor gives the road through the
## gear in use, what rolling and the air take back, and how fast the motor turns. Pure.
##
## The motor gives its full torque up to the speed where its power takes over, then its power,
## up to its rpm limit and nothing past it. The driven axle passes on at most its grip
## (DynamicBicycle.traction_limit_n). The motor, gearbox and wheels spin up with the vehicle:
## they add to its mass as Gillespie's approximation for passenger cars has it (Fundamentals of
## Vehicle Dynamics, eq. 2-11): 4 % plus 0.25 % of the overall ratio squared.

const AIR_DENSITY_KG_M3 := 1.2
const ROTATING_MASS_SHARE := 0.04
const ROTATING_MASS_SHARE_PER_SQUARED_RATIO := 0.0025
## An automatic gearbox takes the higher of two gears whose forces are this close.
const SAME_FORCE_SHARE := 0.001
## How far past its rpm limit, as a share of it, the motor still pushes: at the limit itself,
## whatever rounding says, so that it holds the vehicle there.
const RPM_LIMIT_TOLERANCE := 1e-6
## Below this speed the motor's power is no limit: its torque is.
const STANDSTILL_M_S := 0.01


static func overall_ratio(powertrain: PowertrainSpec, gear: int) -> float:
	## Motor turns per wheel turn in `gear`, from 1.
	return powertrain.gear_ratios[gear - 1] * powertrain.final_drive_ratio


static func gear_at(spec: VehicleSpec, speed_m_s: float) -> int:
	## The gear in use at `speed_m_s`: the selected one, or the one an automatic gearbox picks,
	## which pushes hardest at full throttle (the highest of those that push as hard).
	var powertrain := spec.powertrain
	if powertrain.gear != PowertrainSpec.AUTOMATIC:
		return powertrain.gear
	var best_gear := powertrain.gear_ratios.size()
	var best_force_n := 0.0
	for gear in range(1, powertrain.gear_ratios.size() + 1):
		var force_n := motor_force_n(spec, gear, absf(speed_m_s))
		if force_n >= best_force_n * (1.0 - SAME_FORCE_SHARE) and force_n > 0.0:
			best_gear = gear
			best_force_n = maxf(force_n, best_force_n)
	return best_gear


static func motor_rpm(spec: VehicleSpec, speed_m_s: float) -> float:
	## The motor's speed when the wheels roll at `speed_m_s`, either way, in the gear in use.
	var ratio := overall_ratio(spec.powertrain, gear_at(spec, speed_m_s))
	return InstrumentScales.motor_rpm(speed_m_s, spec.wheel_radius_m, ratio)


static func motor_force_n(spec: VehicleSpec, gear: int, speed_m_s: float) -> float:
	## The force at the wheels' contact the motor gives at full throttle in `gear` at
	## `speed_m_s` (0 or more), grip aside.
	var powertrain := spec.powertrain
	var ratio := overall_ratio(powertrain, gear)
	var rpm := InstrumentScales.motor_rpm(speed_m_s, spec.wheel_radius_m, ratio)
	if rpm > powertrain.max_rpm * (1.0 + RPM_LIMIT_TOLERANCE):
		return 0.0
	var efficiency := powertrain.driveline_efficiency
	var torque_n := powertrain.max_torque_n_m * ratio * efficiency / spec.wheel_radius_m
	if speed_m_s < STANDSTILL_M_S:
		return torque_n
	return minf(torque_n, powertrain.max_power_w * efficiency / speed_m_s)


static func resistance_n(spec: VehicleSpec, speed_m_s: float) -> float:
	## What the air and the tyres' rolling take back at `speed_m_s`, either way.
	var powertrain := spec.powertrain
	var drag_n := 0.5 * AIR_DENSITY_KG_M3 * powertrain.drag_area_m2 * speed_m_s * speed_m_s
	var rolling_n := (
		powertrain.rolling_resistance_coefficient * spec.mass_kg * DynamicBicycle.GRAVITY_M_S2
	)
	return drag_n + rolling_n


static func full_throttle_acceleration_m_s2(spec: VehicleSpec, speed_m_s: float) -> float:
	## How hard the vehicle speeds up at full throttle going forwards at `speed_m_s`: negative
	## where the air and rolling take back more than the motor gives.
	var gear := gear_at(spec, speed_m_s)
	var resisting_n := resistance_n(spec, speed_m_s)
	var motor_m_s2 := (
		(motor_force_n(spec, gear, speed_m_s) - resisting_n) / _moving_mass_kg(spec, gear)
	)
	# The spinning parts take their share of the motor's torque before the tyres: held to their
	# grip, the tyres push the vehicle's mass alone.
	var grip_m_s2 := (DynamicBicycle.traction_limit_n(spec) - resisting_n) / spec.mass_kg
	return minf(motor_m_s2, grip_m_s2)


static func coasting_deceleration_m_s2(spec: VehicleSpec, speed_m_s: float) -> float:
	## How hard the vehicle slows with neither throttle nor brake at `speed_m_s`.
	return resistance_n(spec, speed_m_s) / _moving_mass_kg(spec, gear_at(spec, speed_m_s))


static func rpm_limited_speed_m_s(spec: VehicleSpec) -> float:
	## The speed at the motor's rpm limit in the highest gear the vehicle may use.
	var powertrain := spec.powertrain
	var gear := powertrain.gear
	if gear == PowertrainSpec.AUTOMATIC:
		gear = powertrain.gear_ratios.size()
	var wheel_turns_per_s := powertrain.max_rpm / overall_ratio(powertrain, gear) / 60.0
	return wheel_turns_per_s * TAU * spec.wheel_radius_m


static func _moving_mass_kg(spec: VehicleSpec, gear: int) -> float:
	## The vehicle's mass with what its spinning parts add in `gear`.
	var ratio := overall_ratio(spec.powertrain, gear)
	return (
		spec.mass_kg
		* (1.0 + ROTATING_MASS_SHARE + ROTATING_MASS_SHARE_PER_SQUARED_RATIO * ratio * ratio)
	)
