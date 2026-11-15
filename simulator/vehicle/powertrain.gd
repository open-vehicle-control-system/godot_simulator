class_name Powertrain
extends RefCounted
## What a vehicle's powertrain does at a speed: the torque its motor gives the wheels through
## the gear in use, and what rolling and the air take back. Pure. Under OVCS, OVCS's simulated
## motor and gearbox take its place: only the keyboard and the speed hold drive by it.
##
## The motor gives its full torque up to the speed where its power takes over, then its power,
## up to its rpm limit and nothing past it. The motor and gearbox spin up with the wheels: their
## inertia is what Gillespie's approximation for passenger cars adds to the mass for them
## (Fundamentals of Vehicle Dynamics, eq. 2-11), 0.25 % of it per squared overall ratio.

const AIR_DENSITY_KG_M3 := 1.2
const ROTATING_MASS_SHARE_PER_SQUARED_RATIO := 0.0025
## An automatic gearbox takes the higher of two gears whose forces are this close.
const SAME_FORCE_SHARE := 0.001
## How far past its rpm limit, as a share of it, the motor still pushes: at the limit itself,
## whatever rounding says.
const RPM_LIMIT_TOLERANCE := 1e-6
## An automatic gearbox shifts up from a gear before the motor reaches this share of its rpm
## limit in it: on the limit, the motor's torque comes and goes.
const SHIFT_RPM_SHARE := 0.97
## Below this speed the motor's power is no limit: its torque is.
const STANDSTILL_M_S := 0.01


static func overall_ratio(powertrain: PowertrainSpec, gear: int) -> float:
	## Motor turns per wheel turn in `gear`, from 1.
	return powertrain.gear_ratios[gear - 1] * powertrain.final_drive_ratio


static func gear_at(spec: VehicleSpec, speed_m_s: float) -> int:
	## The gear in use at `speed_m_s`: the selected one, or the one an automatic gearbox picks,
	## which pushes hardest at full throttle (the highest of those that push as hard) among
	## those it has not shifted up from (SHIFT_RPM_SHARE).
	var powertrain := spec.powertrain
	if powertrain.gear != PowertrainSpec.AUTOMATIC:
		return powertrain.gear
	var top_gear := powertrain.gear_ratios.size()
	var best_gear := top_gear
	var best_force_n := 0.0
	for gear in range(1, top_gear + 1):
		var rpm := InstrumentScales.motor_rpm(
			speed_m_s, spec.wheel_radius_m, overall_ratio(powertrain, gear)
		)
		if gear < top_gear and rpm > SHIFT_RPM_SHARE * powertrain.max_rpm:
			continue
		var force_n := motor_force_n(spec, gear, absf(speed_m_s))
		if force_n >= best_force_n * (1.0 - SAME_FORCE_SHARE) and force_n > 0.0:
			best_gear = gear
			best_force_n = maxf(force_n, best_force_n)
	return best_gear


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
	var rolling_n := powertrain.rolling_resistance_coefficient * spec.mass_kg * Vehicle.GRAVITY_M_S2
	return drag_n + rolling_n


static func wheel_torque_n_m(spec: VehicleSpec, gear: int, wheel_speed_rad_s: float) -> float:
	## The torque the motor gives the driven wheels at full throttle in `gear` with them turning
	## at `wheel_speed_rad_s` (either way): 0 or more.
	return (
		motor_force_n(spec, gear, absf(wheel_speed_rad_s) * spec.wheel_radius_m)
		* spec.wheel_radius_m
	)


static func driveline_inertia_kg_m2(spec: VehicleSpec, gear: int) -> float:
	## The motor's and gearbox's inertia at the driven wheels in `gear`: what Gillespie's
	## approximation adds to the mass, 0.25 % of it per squared overall ratio, at the wheels'
	## radius.
	var ratio := overall_ratio(spec.powertrain, gear)
	return (
		ROTATING_MASS_SHARE_PER_SQUARED_RATIO
		* ratio
		* ratio
		* spec.mass_kg
		* spec.wheel_radius_m
		* spec.wheel_radius_m
	)
