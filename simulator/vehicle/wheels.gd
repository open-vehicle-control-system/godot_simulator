class_name Wheels
extends RefCounted
## The four wheels' spin and their tyres' tread, advanced over a physics step. Pure.
##
## Each wheel turns by the torques on it: the drive torque through an open differential (the
## two wheels of a driven axle get the same torque; the driveline's inertia turns with their
## mean speed), the brake, rolling resistance and the tyre's force on the road. A brake or
## rolling resistance never turns a wheel back: up to its torque, it holds the wheel still.
## The tread deflects as its contact slips (Tyre). The ground's motion under each wheel and
## its load are held for the step, which is cut into substeps: the tread on a light wheel is
## a stiff spring.
##
## Order: front left, front right, rear left, rear right. Spin is positive rolling forward.

const MAX_SUBSTEP_S := 0.0005
## A wheel and tyre's own inertia about its axle, as a share of the vehicle's mass at the
## wheel's radius: the four take Gillespie's 4 % (Fundamentals of Vehicle Dynamics, eq. 2-11).
const WHEEL_INERTIA_SHARE := 0.01
## How much of critical damping the tread has standing still, against the wheel's share of the
## vehicle's mass; rolling, its relaxation damps it instead.
const TREAD_DAMPING_RATIO := 0.3
const DAMPED_BELOW_M_S := 2.0
const UNDAMPED_ABOVE_M_S := 5.0

var omega_rad_s := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var angle_rad := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])  ## turned since the start
var deflection_m: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var tyres: Array[Tyre] = []
var radius_m: float
var wheel_inertia_kg_m2: float
var rolling_resistance: float
var driven_axles: Array = []  ## pairs of wheel indices


static func of(spec: VehicleSpec) -> Wheels:
	## The wheels of the vehicle `spec` describes, standing still.
	var wheels := Wheels.new()
	var front := Tyre.of(spec, true)
	var rear := Tyre.of(spec, false)
	wheels.tyres.assign([front, front, rear, rear])
	wheels.radius_m = spec.wheel_radius_m
	wheels.wheel_inertia_kg_m2 = WHEEL_INERTIA_SHARE * spec.mass_kg * spec.wheel_radius_m ** 2
	wheels.rolling_resistance = spec.powertrain.rolling_resistance_coefficient
	match spec.driven_axle:
		"front":
			wheels.driven_axles = [[0, 1]]
		"rear":
			wheels.driven_axles = [[2, 3]]
		_:
			wheels.driven_axles = [[0, 1], [2, 3]]
	return wheels


func roll_at(speed_m_s: float) -> void:
	## Sets every wheel rolling at `speed_m_s` without slip, its tread relaxed.
	for index in 4:
		omega_rad_s[index] = speed_m_s / radius_m
		deflection_m[index] = Vector2.ZERO


func is_driven(index: int) -> bool:
	for axle in driven_axles:
		if index in axle:
			return true
	return false


func advance(
	contacts: Array[Dictionary],
	drive_torque_n_m: float,
	brake_torques_n_m: PackedFloat64Array,
	driveline_inertia_kg_m2: float,
	delta_s: float
) -> Array[Vector2]:
	## Advances the wheels by `delta_s` and returns each tyre's mean force on the road over it
	## (x along the wheel's heading, y across, to its left). `contacts` holds, per wheel, the
	## ground's velocity at the contact relative to the wheel (`along_m_s`, `across_m_s`: the
	## wheel's own velocity over the ground) and its load (`load_n`, 0 for a wheel in the
	## air). `drive_torque_n_m` is the driven axles' total, shared equally between them, as is
	## `driveline_inertia_kg_m2`; `brake_torques_n_m` is each wheel's brake (0 or more).
	var substeps := maxi(ceili(delta_s / MAX_SUBSTEP_S), 1)
	var substep_s := delta_s / substeps
	var axle_torque_n_m := drive_torque_n_m / driven_axles.size()
	var axle_inertia_kg_m2 := maxf(driveline_inertia_kg_m2, 0.0) / driven_axles.size()
	var sums: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	var holding := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for index in 4:
		var load_n: float = contacts[index]["load_n"]
		holding[index] = (
			maxf(brake_torques_n_m[index], 0.0) + rolling_resistance * maxf(load_n, 0.0) * radius_m
		)
		if load_n <= 0.0:
			deflection_m[index] = Vector2.ZERO
	for substep in substeps:
		var forces: Array[Vector2] = []
		var torques := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
		for index in 4:
			var force := _tread_force_n(index, contacts[index])
			forces.append(force)
			torques[index] = -force.x * radius_m
			sums[index] += force
		var spun := PackedInt32Array()
		for axle in driven_axles:
			_spin_axle(
				axle[0], axle[1], axle_torque_n_m, axle_inertia_kg_m2, torques, holding, substep_s
			)
			spun.append_array(axle)
		for index in 4:
			if not index in spun:
				_spin_wheel(index, torques[index], holding[index], substep_s)
		for index in 4:
			_deflect(index, contacts[index], substep_s)
			angle_rad[index] += omega_rad_s[index] * substep_s
	var means: Array[Vector2] = []
	for index in 4:
		means.append(sums[index] / substeps)
	return means


func _tread_force_n(index: int, contact: Dictionary) -> Vector2:
	## The tyre's force on the road now: the deflected tread's, damped standing still, never
	## more than the tyre holds.
	var load_n: float = contact["load_n"]
	if load_n <= 0.0:
		return Vector2.ZERO
	var tyre := tyres[index]
	var force := tyre.force_n(deflection_m[index], load_n)
	var along_m_s: float = contact["along_m_s"]
	var damped := 1.0 - smoothstep(DAMPED_BELOW_M_S, UNDAMPED_ABOVE_M_S, absf(along_m_s))
	if damped > 0.0:
		var spring := tyre.spring_n_per_m(load_n)
		var corner_mass_kg := tyre.static_load_n / Vehicle.GRAVITY_M_S2
		var damping := Vector2(
			2.0 * TREAD_DAMPING_RATIO * sqrt(spring.x * corner_mass_kg),
			2.0 * TREAD_DAMPING_RATIO * sqrt(spring.y * corner_mass_kg)
		)
		force += damping * _deflection_rate(index, contact) * damped
	var peak_n := tyre.peak_force_n(load_n)
	return force.limit_length(peak_n)


func _deflection_rate(index: int, contact: Dictionary) -> Vector2:
	var along_m_s: float = contact["along_m_s"]
	var rolling_m_s := absf(along_m_s)
	var deflection := deflection_m[index]
	return Vector2(
		(
			omega_rad_s[index] * radius_m
			- along_m_s
			- rolling_m_s / tyres[index].longitudinal_relaxation_m * deflection.x
		),
		(
			-float(contact["across_m_s"])
			- rolling_m_s / tyres[index].lateral_relaxation_m * deflection.y
		)
	)


func _deflect(index: int, contact: Dictionary, substep_s: float) -> void:
	## The tread's deflection after `substep_s`, its contact slipping as now: it settles
	## exponentially towards the slip times the relaxation length (integrated exactly, so a
	## fast wheel's short time constant is no instability).
	var load_n: float = contact["load_n"]
	if load_n <= 0.0:
		deflection_m[index] = Vector2.ZERO
		return
	var along_m_s: float = contact["along_m_s"]
	var rolling_m_s := absf(along_m_s)
	var deflection := deflection_m[index]
	deflection.x = _relaxed(
		deflection.x,
		omega_rad_s[index] * radius_m - along_m_s,
		rolling_m_s / tyres[index].longitudinal_relaxation_m,
		substep_s
	)
	deflection.y = _relaxed(
		deflection.y,
		-float(contact["across_m_s"]),
		rolling_m_s / tyres[index].lateral_relaxation_m,
		substep_s
	)
	deflection_m[index] = tyres[index].limit_deflection(deflection, load_n)


static func _relaxed(
	deflection: float, rate_in: float, relaxing_per_s: float, time_s: float
) -> float:
	## `deflection` after `time_s` of d' = rate_in - relaxing_per_s * d.
	if relaxing_per_s * time_s < 1e-9:
		return deflection + rate_in * time_s
	var settled := rate_in / relaxing_per_s
	return settled + (deflection - settled) * exp(-relaxing_per_s * time_s)


func _spin_wheel(index: int, torque_n_m: float, holding_n_m: float, substep_s: float) -> void:
	## A wheel no drive turns: `torque_n_m` from its tyre, a brake holding up to `holding_n_m`.
	var free_rad_s := omega_rad_s[index] + torque_n_m * substep_s / wheel_inertia_kg_m2
	var braking_n_m := clampf(
		-free_rad_s * wheel_inertia_kg_m2 / substep_s, -holding_n_m, holding_n_m
	)
	omega_rad_s[index] = free_rad_s + braking_n_m * substep_s / wheel_inertia_kg_m2


func _spin_axle(
	left: int,
	right: int,
	drive_torque_n_m: float,
	driveline_inertia_kg_m2: float,
	torques: PackedFloat64Array,
	holding: PackedFloat64Array,
	substep_s: float
) -> void:
	## A driven axle's two wheels through an open differential: their mean speed turns with
	## the driveline, under the drive and every wheel torque; their difference under the
	## difference of their own torques. Each brake holds its wheel still, up to its torque.
	var inertia := wheel_inertia_kg_m2
	var common := substep_s / (2.0 * inertia + driveline_inertia_kg_m2)
	var differential := substep_s / (2.0 * inertia)
	var mean_rad_s := (
		(omega_rad_s[left] + omega_rad_s[right]) * 0.5
		+ common * (drive_torque_n_m + torques[left] + torques[right])
	)
	var difference_rad_s := (
		omega_rad_s[left]
		- omega_rad_s[right]
		+ substep_s * (torques[left] - torques[right]) / inertia
	)
	var free_left := mean_rad_s + difference_rad_s * 0.5
	var free_right := mean_rad_s - difference_rad_s * 0.5
	# A torque on one wheel turns it by (common + differential) per N m, the other by
	# (common - differential).
	var own := common + differential
	var other := common - differential
	var held := _held_pair(free_left, free_right, own, other, holding[left], holding[right])
	omega_rad_s[left] = free_left + held.x * own + held.y * other
	omega_rad_s[right] = free_right + held.y * own + held.x * other


static func _held_pair(
	free_left: float,
	free_right: float,
	own: float,
	other: float,
	left_limit_n_m: float,
	right_limit_n_m: float
) -> Vector2:
	## The brake torques on two coupled wheels that stop them, as far as their limits allow: a
	## brake below its limit leaves its wheel still, one at its limit pushes against its wheel's
	## turning. The first of the cases that holds: both below, either at its limit, both.
	var determinant := own * own - other * other
	var left_n_m := (other * free_right - own * free_left) / determinant
	var right_n_m := (other * free_left - own * free_right) / determinant
	var candidates: Array[Vector2] = [Vector2(left_n_m, right_n_m)]
	var left_bound := clampf(left_n_m, -left_limit_n_m, left_limit_n_m)
	candidates.append(Vector2(left_bound, -(free_right + left_bound * other) / own))
	var right_bound := clampf(right_n_m, -right_limit_n_m, right_limit_n_m)
	candidates.append(Vector2(-(free_left + right_bound * other) / own, right_bound))
	for candidate in candidates:
		var held := Vector2(
			clampf(candidate.x, -left_limit_n_m, left_limit_n_m),
			clampf(candidate.y, -right_limit_n_m, right_limit_n_m)
		)
		if (
			_holds(free_left + held.x * own + held.y * other, held.x, left_limit_n_m)
			and _holds(free_right + held.y * own + held.x * other, held.y, right_limit_n_m)
		):
			return held
	# Both at their limits, each against its wheel's free turning.
	return Vector2(-signf(free_left) * left_limit_n_m, -signf(free_right) * right_limit_n_m)


static func _holds(spin_rad_s: float, brake_n_m: float, limit_n_m: float) -> bool:
	## True when a brake at `brake_n_m` of `limit_n_m` is consistent with its wheel then
	## spinning at `spin_rad_s`: below its limit the wheel stands, at it the wheel does not
	## turn the way the brake pushes.
	const STILL_RAD_S := 1e-6
	if absf(brake_n_m) < limit_n_m - 1e-9:
		return absf(spin_rad_s) < STILL_RAD_S
	return spin_rad_s * signf(brake_n_m) <= STILL_RAD_S
