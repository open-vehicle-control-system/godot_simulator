class_name DynamicBicycle
extends RefCounted
## Planar dynamic bicycle model about the centre of gravity, with tyres that slip. Pure.
##
## The speed along the heading follows the command; the lateral velocity and the yaw rate come
## from each axle's side force, which grows with its slip angle up to a peak and falls a little
## beyond (Pacejka's magic formula, B C D E). Load moves between the axles as the vehicle brakes
## or accelerates and from the inner wheels to the outer ones as it corners; a tyre's stiffness
## grows less than its load and its friction falls as its load rises. The force an axle carries
## along the road shrinks what it holds sideways. Below walking pace the motion blends into the
## kinematic model, which has no slip. Every property of the vehicle is its pack's.
##
## Frame as BicycleModel: yaw about +Y from +Z (forward) towards +X (left); lateral velocity,
## yaw rate and steering are positive left.

const GRAVITY_M_S2 := 9.81
## Below the first speed the motion is kinematic, above the second dynamic, blended between.
const KINEMATIC_BELOW_M_S := 1.0
const DYNAMIC_ABOVE_M_S := 3.0
const MAX_SUBSTEP_S := 0.004
const MAX_SUBSTEPS := 200
## An axle always keeps this share of the weight, and this share of its grip sideways.
const MIN_AXLE_LOAD_SHARE := 0.05
const MIN_SIDE_GRIP_SHARE := 0.1


static func rolling(yaw_rad: float, speed_m_s: float, centre := Vector3.ZERO) -> Dictionary:
	## The motion of a vehicle at `centre` rolling straight along `yaw_rad` at a steady
	## `speed_m_s`, as `advance` returns it.
	return {
		"centre": centre,
		"yaw_rad": yaw_rad,
		"speed_m_s": speed_m_s,
		"lateral_velocity_m_s": 0.0,
		"yaw_rate_rad_s": 0.0,
		"longitudinal_acceleration_m_s2": 0.0,
		"lateral_acceleration_m_s2": 0.0,
		"yaw_acceleration_rad_s2": 0.0,
	}


static func advance(
	motion: Dictionary, spec: VehicleSpec, speed_m_s: float, steering_rad: float, delta_s: float
) -> Dictionary:
	## `motion` after `delta_s` at `speed_m_s` along the heading (its change from `motion`'s is
	## the step's longitudinal acceleration) with the front wheels at `steering_rad`: `centre`,
	## `yaw_rad`, `speed_m_s`, `lateral_velocity_m_s` and `yaw_rate_rad_s` of the centre of
	## gravity, with the accelerations over the step (`longitudinal_acceleration_m_s2`,
	## `lateral_acceleration_m_s2` in the vehicle frame, `yaw_acceleration_rad_s2`).
	var start_speed_m_s: float = motion["speed_m_s"]
	var start_lateral_m_s: float = motion["lateral_velocity_m_s"]
	var start_yaw_rate_rad_s: float = motion["yaw_rate_rad_s"]
	var centre: Vector3 = motion["centre"]
	var yaw_rad: float = motion["yaw_rad"]
	var lateral_m_s := start_lateral_m_s
	var yaw_rate_rad_s := start_yaw_rate_rad_s
	var longitudinal_m_s2 := (speed_m_s - start_speed_m_s) / delta_s
	# Tyres pass on at most their grip along the road, whatever the command asks.
	var grip_m_s2 := spec.max_lateral_acceleration_m_s2
	var tyres_m_s2 := clampf(longitudinal_m_s2, -grip_m_s2, grip_m_s2)
	var substeps := _substeps(spec, absf(speed_m_s), lateral_m_s, delta_s)
	var substep_s := delta_s / substeps
	var lateral_m_s2_sum := 0.0
	for index in substeps:
		var rates := _rates(spec, speed_m_s, lateral_m_s, yaw_rate_rad_s, steering_rad, tyres_m_s2)
		var dynamic_lateral_m_s: float = lateral_m_s + rates["lateral_m_s2"] * substep_s
		var dynamic_yaw_rate_rad_s: float = yaw_rate_rad_s + rates["yaw_rad_s2"] * substep_s
		var kinematic_yaw_rate_rad_s := _kinematic_yaw_rate_rad_s(spec, speed_m_s, steering_rad)
		var kinematic_lateral_m_s := kinematic_yaw_rate_rad_s * _behind_m(spec)
		var dynamic_share := smoothstep(
			KINEMATIC_BELOW_M_S, DYNAMIC_ABOVE_M_S, Vector2(speed_m_s, lateral_m_s).length()
		)
		var next_lateral_m_s := lerpf(kinematic_lateral_m_s, dynamic_lateral_m_s, dynamic_share)
		lateral_m_s2_sum += (
			(next_lateral_m_s - lateral_m_s) / substep_s + speed_m_s * yaw_rate_rad_s
		)
		lateral_m_s = next_lateral_m_s
		yaw_rate_rad_s = lerpf(kinematic_yaw_rate_rad_s, dynamic_yaw_rate_rad_s, dynamic_share)
		yaw_rad += yaw_rate_rad_s * substep_s
		var heading := BicycleModel.heading(yaw_rad)
		var left := Vector3.UP.cross(heading)
		centre += (heading * speed_m_s + left * lateral_m_s) * substep_s
	return {
		"centre": centre,
		"yaw_rad": yaw_rad,
		"speed_m_s": speed_m_s,
		"lateral_velocity_m_s": lateral_m_s,
		"yaw_rate_rad_s": yaw_rate_rad_s,
		"longitudinal_acceleration_m_s2": longitudinal_m_s2,
		"lateral_acceleration_m_s2": lateral_m_s2_sum / substeps,
		"yaw_acceleration_rad_s2": (yaw_rate_rad_s - start_yaw_rate_rad_s) / delta_s,
	}


static func _rates(
	spec: VehicleSpec,
	along_m_s: float,
	lateral_m_s: float,
	yaw_rate_rad_s: float,
	steering_rad: float,
	longitudinal_m_s2: float
) -> Dictionary:
	## The lateral acceleration and the yaw acceleration the axles' side forces give.
	var ahead_m := _ahead_m(spec)
	var behind_m := _behind_m(spec)
	var wheelbase_m := spec.wheelbase_m()
	var weight_n := spec.mass_kg * GRAVITY_M_S2
	var front_static_n := weight_n * behind_m / wheelbase_m
	var rear_static_n := weight_n * ahead_m / wheelbase_m
	var transfer_n := (
		spec.mass_kg * longitudinal_m_s2 * spec.centre_of_gravity_height_m / wheelbase_m
	)
	var front_load_n := maxf(front_static_n - transfer_n, weight_n * MIN_AXLE_LOAD_SHARE)
	var rear_load_n := maxf(rear_static_n + transfer_n, weight_n * MIN_AXLE_LOAD_SHARE)
	# Cornering moves load to the outer wheels, shared between the axles by roll stiffness.
	var roll_n_m := (
		spec.mass_kg * absf(along_m_s * yaw_rate_rad_s) * spec.centre_of_gravity_height_m
	)
	var front_outwards_n := roll_n_m * spec.front_roll_stiffness_share / spec.front_track_m
	var rear_outwards_n := roll_n_m * (1.0 - spec.front_roll_stiffness_share) / spec.rear_track_m
	# The tyres carry the force that holds the commanded speed, including what turning the
	# lateral velocity into the heading takes.
	var along_n := spec.mass_kg * (longitudinal_m_s2 - lateral_m_s * yaw_rate_rad_s)
	var front_share := _front_share_of_along(
		spec, along_n * along_m_s < 0.0, front_load_n, rear_load_n
	)
	var front_force_n := _side_force_n(
		spec,
		_front_slip_rad(along_m_s, lateral_m_s + ahead_m * yaw_rate_rad_s, steering_rad),
		_stiffness_n_per_rad(
			spec, spec.front_cornering_stiffness_n_per_rad, front_load_n, front_static_n
		),
		_side_grip_n(
			_axle_grip_n(spec, front_load_n, front_outwards_n, front_static_n),
			along_n * front_share
		)
	)
	var rear_force_n := _side_force_n(
		spec,
		-atan2(lateral_m_s - behind_m * yaw_rate_rad_s, absf(along_m_s)),
		_stiffness_n_per_rad(
			spec, spec.rear_cornering_stiffness_n_per_rad, rear_load_n, rear_static_n
		),
		_side_grip_n(
			_axle_grip_n(spec, rear_load_n, rear_outwards_n, rear_static_n),
			along_n * (1.0 - front_share)
		)
	)
	var front_lateral_n := front_force_n * cos(steering_rad)
	return {
		"lateral_m_s2":
		(front_lateral_n + rear_force_n) / spec.mass_kg - along_m_s * yaw_rate_rad_s,
		"yaw_rad_s2":
		(ahead_m * front_lateral_n - behind_m * rear_force_n) / spec.yaw_inertia_kg_m2,
	}


static func _front_slip_rad(along_m_s: float, lateral_m_s: float, steering_rad: float) -> float:
	## The angle from the front wheels' rolling direction to their contact's velocity, negated:
	## positive when the road pushes them left.
	var rolling_m_s := along_m_s * cos(steering_rad) + lateral_m_s * sin(steering_rad)
	var across_m_s := -along_m_s * sin(steering_rad) + lateral_m_s * cos(steering_rad)
	return -atan2(across_m_s, absf(rolling_m_s))


static func _front_share_of_along(
	spec: VehicleSpec, braking: bool, front_load_n: float, rear_load_n: float
) -> float:
	## The share of the force along the road the front axle carries. Braking is split by the
	## brakes' bias, the rear's share kept its margin below its share of the load, as a
	## proportioning valve does; traction goes to the driven wheels.
	var front_load_share := front_load_n / (front_load_n + rear_load_n)
	if braking:
		var rear_share := minf(
			1.0 - spec.brake_bias_front, 1.0 - front_load_share - spec.rear_brake_margin
		)
		return 1.0 - clampf(rear_share, 0.0, 1.0)
	if spec.driven_axle == "all":
		return front_load_share
	return 1.0 if spec.driven_axle == "front" else 0.0


static func _stiffness_n_per_rad(
	spec: VehicleSpec, static_stiffness_n_per_rad: float, load_n: float, static_load_n: float
) -> float:
	## An axle's cornering stiffness at `load_n`, which grows less than the load.
	return (
		static_stiffness_n_per_rad
		* pow(load_n / static_load_n, spec.cornering_stiffness_load_exponent)
	)


static func _axle_grip_n(
	spec: VehicleSpec, load_n: float, outwards_n: float, static_load_n: float
) -> float:
	## The most an axle's two tyres hold, `outwards_n` of its load moved to the outer one: a
	## tyre's friction falls as its load rises, so moving load across loses grip.
	var shifted_n := minf(outwards_n, load_n * 0.5)
	var static_tyre_n := static_load_n * 0.5
	return (
		_tyre_grip_n(spec, load_n * 0.5 + shifted_n, static_tyre_n)
		+ _tyre_grip_n(spec, load_n * 0.5 - shifted_n, static_tyre_n)
	)


static func _tyre_grip_n(spec: VehicleSpec, load_n: float, static_load_n: float) -> float:
	var over_static := (load_n - static_load_n) / static_load_n
	return spec.friction * load_n * maxf(1.0 - spec.friction_load_sensitivity * over_static, 0.0)


static func _side_grip_n(grip_n: float, along_n: float) -> float:
	## The most an axle holds sideways while carrying `along_n` along the road (friction circle).
	var left_n := sqrt(maxf(grip_n * grip_n - along_n * along_n, 0.0))
	return maxf(left_n, grip_n * MIN_SIDE_GRIP_SHARE)


static func _side_force_n(
	spec: VehicleSpec, slip_rad: float, stiffness_n_per_rad: float, peak_n: float
) -> float:
	## Pacejka's magic formula: slope `stiffness_n_per_rad` at no slip, peaking at `peak_n`.
	var shape := spec.tyre_shape
	var stiffness_factor := stiffness_n_per_rad / (shape * peak_n)
	var slip := stiffness_factor * slip_rad
	return peak_n * sin(shape * atan(slip - spec.tyre_curvature * (slip - atan(slip))))


static func _kinematic_yaw_rate_rad_s(
	spec: VehicleSpec, speed_m_s: float, steering_rad: float
) -> float:
	var wheelbase_m := spec.wheelbase_m()
	var turning_rad := BicycleModel.grip_limited_steering(
		steering_rad, speed_m_s, wheelbase_m, spec.max_lateral_acceleration_m_s2
	)
	return speed_m_s * tan(turning_rad) / wheelbase_m


static func _substeps(
	spec: VehicleSpec, speed_m_s: float, lateral_m_s: float, delta_s: float
) -> int:
	## Enough steps that each is short beside the lateral and yaw motions' time constants,
	## which shrink with speed.
	var planar_m_s := maxf(Vector2(speed_m_s, lateral_m_s).length(), KINEMATIC_BELOW_M_S)
	var front_n_per_rad := spec.front_cornering_stiffness_n_per_rad
	var rear_n_per_rad := spec.rear_cornering_stiffness_n_per_rad
	var lateral_s := spec.mass_kg * planar_m_s / (front_n_per_rad + rear_n_per_rad)
	var yaw_s := (
		spec.yaw_inertia_kg_m2
		* planar_m_s
		/ (_ahead_m(spec) ** 2 * front_n_per_rad + _behind_m(spec) ** 2 * rear_n_per_rad)
	)
	var substep_s := minf(MAX_SUBSTEP_S, 0.5 * minf(lateral_s, yaw_s))
	return clampi(ceili(delta_s / substep_s), 1, MAX_SUBSTEPS)


static func _ahead_m(spec: VehicleSpec) -> float:
	## From the centre of gravity forward to the front axle.
	return spec.front_axle_z - spec.centre_of_gravity_z


static func _behind_m(spec: VehicleSpec) -> float:
	## From the rear axle forward to the centre of gravity.
	return spec.centre_of_gravity_z - spec.rear_axle_z
