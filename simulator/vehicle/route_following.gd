class_name RouteFollowing
extends RefCounted
## The steering and speed that keep a vehicle on a route's centre line. Pure.
##
## Steering is pure pursuit: from the rear axle, the arc through a point of the line a look-ahead
## further on, longer the faster the vehicle goes. The speed is the one asked for, lowered so
## every corner within braking distance is taken at GRIP_SHARE of the tyres' grip, braking
## before it at PLANNING_DECELERATION_M_S2; an open route ends at a stop.

const LOOK_AHEAD_MIN_M := 5.0
const LOOK_AHEAD_PER_M_S := 0.6
const MAX_STEERING_RAD := 0.6
const GRIP_SHARE := 0.6
const PLANNING_DECELERATION_M_S2 := 2.5
## The line's curvature ahead is read this often.
const SPEED_SAMPLE_M := 4.0


static func look_ahead_m(speed_m_s: float) -> float:
	return maxf(LOOK_AHEAD_MIN_M, LOOK_AHEAD_PER_M_S * absf(speed_m_s))


static func steering_rad(
	route: Route,
	rear_axle: Vector3,
	basis: Basis,
	along_m: float,
	speed_m_s: float,
	wheelbase_m: float
) -> float:
	## The front wheels' angle that turns the vehicle, its rear axle at `rear_axle` and turned
	## to `basis`, onto the arc through the line's point a look-ahead past `along_m`.
	var target := route.point_at(along_m + look_ahead_m(speed_m_s))
	var local := basis.orthonormalized().inverse() * (target - rear_axle)
	var reach_m := maxf(Vector2(local.x, local.z).length(), 0.1)
	var bearing_rad := atan2(local.x, local.z)  # positive to the left
	return clampf(
		atan(2.0 * wheelbase_m * sin(bearing_rad) / reach_m), -MAX_STEERING_RAD, MAX_STEERING_RAD
	)


static func speed_m_s(route: Route, along_m: float, asked_m_s: float, grip_m_s2: float) -> float:
	## The speed to drive at `along_m`: `asked_m_s`, or less for a corner or the end ahead.
	var allowed_m_s := asked_m_s
	var horizon_m := (
		asked_m_s * asked_m_s / (2.0 * PLANNING_DECELERATION_M_S2) + look_ahead_m(asked_m_s)
	)
	var ahead_m := 0.0
	while ahead_m <= horizon_m:
		var curvature := absf(route.curvature_at(along_m + ahead_m))
		if curvature > 1e-6:
			var corner_m_s := sqrt(GRIP_SHARE * grip_m_s2 / curvature)
			allowed_m_s = minf(allowed_m_s, _braking_from(corner_m_s, ahead_m))
		ahead_m += SPEED_SAMPLE_M
	if not route.closed:
		allowed_m_s = minf(allowed_m_s, _braking_from(0.0, route.length_m - along_m))
	return allowed_m_s


static func _braking_from(then_m_s: float, ahead_m: float) -> float:
	## The speed that brakes down to `then_m_s` over `ahead_m`.
	return sqrt(then_m_s * then_m_s + 2.0 * PLANNING_DECELERATION_M_S2 * maxf(ahead_m, 0.0))
