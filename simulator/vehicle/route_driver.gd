class_name RouteDriver
extends Node
## Drives the vehicle along its track's centre line at a speed (--follow-route), slowing for
## corners (RouteFollowing), by SpeedControl.

var _vehicle: Vehicle
var _route: Route
var _asked_m_s := 0.0
var _control := SpeedControl.new()
var _along_m := -1.0


func follow(vehicle: Vehicle, route: Route, speed_m_s: float) -> void:
	## Drives `vehicle` along `route` at `speed_m_s` from now on.
	_vehicle = vehicle
	_route = route
	_asked_m_s = speed_m_s
	name = "RouteDriver"


func along_m() -> float:
	## How far along the route the vehicle's rear axle is.
	return maxf(_along_m, 0.0)


func where() -> String:
	## Where the vehicle is, for --timing.
	return "%.2f km along the route" % (along_m() / 1000.0)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		queue_free()
		return
	var spec := _vehicle.spec
	var rear_axle := _vehicle.global_transform * Vector3(0.0, 0.0, spec.rear_axle_z)
	_along_m = _route.nearest_m(rear_axle, _along_m)
	var speed_m_s := _vehicle.speed_m_s
	var steering_rad := RouteFollowing.steering_rad(
		_route, rear_axle, _vehicle.global_basis, _along_m, speed_m_s, spec.wheelbase_m()
	)
	var target_m_s := RouteFollowing.speed_m_s(
		_route, _along_m, _asked_m_s, spec.friction * Vehicle.GRAVITY_M_S2
	)
	_vehicle.actuate(_control.next(target_m_s, steering_rad, speed_m_s, delta, spec))
