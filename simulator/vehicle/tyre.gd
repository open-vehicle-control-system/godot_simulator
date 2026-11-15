class_name Tyre
extends RefCounted
## A tyre's force on the road from how far its tread is deflected. Pure.
##
## The tread at the contact is a spring: it deflects as the contact slips (along, as the wheel
## turns faster or slower than the ground passes; across, as the ground passes sideways) and
## relaxes over its relaxation length as the wheel rolls on. Rolling, a deflection settles
## at the slip times the relaxation length, so the force is the slip's; standing, it is a
## spring that holds the vehicle without creeping. The force is Pacejka's magic formula over
## both deflections combined (B C D E, the same shape either way, each direction scaled by its
## stiffness), so a tyre carrying force along the road holds less across it. A tyre's
## stiffness grows less than its load and its friction falls as its load rises.
##
## Directions: `x` along the wheel's heading (positive pushes the vehicle forward), `y` across
## it (positive pushes it left).

## How far the tyre rolls for a deflection to relax by a factor e, along and across, in wheel
## radii: a passenger car tyre's 15 cm and 40 cm.
const LONGITUDINAL_RELAXATION_PER_RADIUS := 0.45
const LATERAL_RELAXATION_PER_RADIUS := 1.2
## A tyre's longitudinal slip stiffness, per unit of slip, per newton of its static load.
const SLIP_STIFFNESS_PER_LOAD := 18.0
## A deflection never exceeds this many times the one at the peak force: past it the tread
## slides, so a slide stops pushing the moment the contact grips again.
const MAX_DEFLECTION_PER_PEAK := 3.0

var longitudinal_relaxation_m: float
var lateral_relaxation_m: float
var static_load_n: float
var cornering_stiffness_n_per_rad: float  ## at the static load
var slip_stiffness_n: float  ## per unit of longitudinal slip, at the static load
var friction: float  ## at the static load
var friction_load_sensitivity: float
var stiffness_load_exponent: float
var shape: float  ## Pacejka's C
var curvature: float  ## Pacejka's E
var _peak_argument: float  ## Pacejka's B times the slip at the peak force


static func of(spec: VehicleSpec, front: bool) -> Tyre:
	## A front or rear tyre of the vehicle `spec` describes.
	var tyre := Tyre.new()
	tyre.longitudinal_relaxation_m = LONGITUDINAL_RELAXATION_PER_RADIUS * spec.wheel_radius_m
	tyre.lateral_relaxation_m = LATERAL_RELAXATION_PER_RADIUS * spec.wheel_radius_m
	var wheelbase_m := spec.wheelbase_m()
	var axle_share := (
		(spec.centre_of_gravity_z - spec.rear_axle_z) / wheelbase_m
		if front
		else (spec.front_axle_z - spec.centre_of_gravity_z) / wheelbase_m
	)
	tyre.static_load_n = spec.mass_kg * Vehicle.GRAVITY_M_S2 * axle_share * 0.5
	tyre.cornering_stiffness_n_per_rad = (
		(
			spec.front_cornering_stiffness_n_per_rad
			if front
			else spec.rear_cornering_stiffness_n_per_rad
		)
		* 0.5
	)
	tyre.slip_stiffness_n = SLIP_STIFFNESS_PER_LOAD * tyre.static_load_n
	tyre.friction = spec.friction
	tyre.friction_load_sensitivity = spec.friction_load_sensitivity
	tyre.stiffness_load_exponent = spec.cornering_stiffness_load_exponent
	tyre.shape = spec.tyre_shape
	tyre.curvature = spec.tyre_curvature
	tyre._peak_argument = peak_argument(spec.tyre_shape, spec.tyre_curvature)
	return tyre


static func peak_argument(shape_c: float, curvature_e: float) -> float:
	## Where the magic formula sin(C atan(t - E (t - atan t))) peaks: C atan(...) = pi / 2.
	## t - E (t - atan t) grows with t for any E under 1, so bisection finds it.
	var target := tan(PI / (2.0 * shape_c))
	var low := 0.0
	var high := 1000.0
	for iteration in 60:
		var middle := (low + high) * 0.5
		if middle - curvature_e * (middle - atan(middle)) < target:
			low = middle
		else:
			high = middle
	return (low + high) * 0.5


func peak_force_n(load_n: float) -> float:
	## The most the tyre holds at `load_n`, any way.
	if load_n <= 0.0:
		return 0.0
	var over_static := (load_n - static_load_n) / static_load_n
	return friction * load_n * maxf(1.0 - friction_load_sensitivity * over_static, 0.0)


func stiffness(load_n: float) -> Vector2:
	## The force per unit of slip at `load_n`: along (per unit of slip), across (per radian).
	var factor := pow(maxf(load_n, 0.0) / static_load_n, stiffness_load_exponent)
	return Vector2(slip_stiffness_n, cornering_stiffness_n_per_rad) * factor


func spring_n_per_m(load_n: float) -> Vector2:
	## The tread's stiffness against a deflection at `load_n`, along and across.
	var slip := stiffness(load_n)
	return Vector2(slip.x / longitudinal_relaxation_m, slip.y / lateral_relaxation_m)


func force_n(deflection_m: Vector2, load_n: float) -> Vector2:
	## The force the road gives the wheel with the tread deflected by `deflection_m` at `load_n`.
	var peak_n := peak_force_n(load_n)
	if peak_n <= 0.0:
		return Vector2.ZERO
	var arguments := _arguments(deflection_m, load_n, peak_n)
	var argument := arguments.length()
	if argument < 1e-12:
		return Vector2.ZERO
	var magnitude := peak_n * sin(shape * atan(argument - curvature * (argument - atan(argument))))
	return arguments * (magnitude / argument)


func limit_deflection(deflection_m: Vector2, load_n: float) -> Vector2:
	## `deflection_m`, shortened to MAX_DEFLECTION_PER_PEAK times the deflection at the peak.
	var peak_n := peak_force_n(load_n)
	if peak_n <= 0.0:
		return Vector2.ZERO
	var argument := _arguments(deflection_m, load_n, peak_n).length()
	var most := MAX_DEFLECTION_PER_PEAK * _peak_argument
	return deflection_m * (most / argument) if argument > most else deflection_m


func _arguments(deflection_m: Vector2, load_n: float, peak_n: float) -> Vector2:
	## Pacejka's B times the slip, along and across: the slip is the deflection over the
	## relaxation length, B the stiffness over C D.
	return spring_n_per_m(load_n) * deflection_m / (shape * peak_n)
