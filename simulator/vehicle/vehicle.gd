class_name Vehicle
extends Node3D
## The vehicle OVCS drives: it moves at the speed and steering last commanded, by the bicycle
## model, resting on the ground below it, and counts the distance its wheels roll.
##
## Frame: +X left, +Y up, +Z forward, the origin on the ground.

const GRAVITY_M_S2 := 9.81
const GROUND_PROBE_ABOVE_M := 2.0
const GROUND_PROBE_BELOW_M := 5.0
## The body box used against obstacles never reaches lower than this above the ground, so kerbs
## and the ground's own bumps do not stop the vehicle.
const MIN_BODY_CLEARANCE_M := 0.2
const WHEEL_NAMES := ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]

var spec: VehicleSpec
var odometer_m := 0.0  ## signed: reversing counts down
var speed_m_s := 0.0
var steering_rad := 0.0  ## front wheels, positive left
var yaw_rate_rad_s := 0.0
var longitudinal_acceleration_m_s2 := 0.0

var _commanded_speed_m_s := 0.0
var _commanded_steering_rad := 0.0
var _yaw_rad := 0.0
var _placed := Transform3D()
var _wheels: Array[Node3D] = []  # front left, front right, rear left, rear right
var _body_shape := BoxShape3D.new()
var _body_centre := Vector3.ZERO


func setup(vehicle_spec: VehicleSpec, model: VehicleModel) -> void:
	## Shows `model` as this vehicle, with a wheel at each corner `vehicle_spec` gives.
	spec = vehicle_spec
	name = "Vehicle"
	_set_up_body_shape()
	add_child(model.body)
	for part in model.cockpit_parts:
		add_child(part)
	for axle_z in [spec.front_axle_z, spec.rear_axle_z]:
		var track_m := spec.front_track_m if axle_z == spec.front_axle_z else spec.rear_track_m
		for side in [1.0, -1.0]:
			var pivot := Node3D.new()
			pivot.name = WHEEL_NAMES[_wheels.size()]
			pivot.position = Vector3(side * track_m * 0.5, spec.wheel_radius_m, axle_z)
			var wheel := model.wheel.duplicate() as Node3D
			if side < 0.0:
				wheel.rotate_y(PI)  # outer face to the right
			pivot.add_child(wheel)
			add_child(pivot)
			_wheels.append(pivot)
	model.wheel.free()


func command(commanded_speed_m_s: float, commanded_steering_rad: float) -> void:
	## Moves at this speed (m/s, negative reversing) and steering (rad, positive left) from the
	## next physics step on.
	_commanded_speed_m_s = commanded_speed_m_s
	_commanded_steering_rad = commanded_steering_rad


func stop() -> void:
	## Commands standstill, keeping the steering.
	command(0.0, _commanded_steering_rad)


func motion_state() -> Dictionary:
	## The pose in the world and, in the vehicle frame, the velocities and what an IMU reads
	## (the motion's acceleration plus gravity's reaction), all of the origin, which turns about
	## a point beside the rear axle.
	var basis := global_basis.orthonormalized()
	var gravity_reaction := basis.inverse() * Vector3(0.0, GRAVITY_M_S2, 0.0)
	var ahead_of_rear_axle_m := -spec.rear_axle_z
	var motion_acceleration := Vector3(
		speed_m_s * yaw_rate_rad_s,
		0.0,
		longitudinal_acceleration_m_s2 - ahead_of_rear_axle_m * yaw_rate_rad_s * yaw_rate_rad_s
	)
	return {
		"pose": global_transform,
		"linear_velocity_m_s": Vector3(ahead_of_rear_axle_m * yaw_rate_rad_s, 0.0, speed_m_s),
		"angular_velocity_rad_s": Vector3(0.0, yaw_rate_rad_s, 0.0),
		"linear_acceleration_m_s2": motion_acceleration + gravity_reaction,
	}


func _physics_process(delta: float) -> void:
	if spec == null:
		return
	# The yaw is this node's own state, so a pose tilted onto slopes never feeds back into it;
	# only a move from outside (a spawn) resets it.
	if not global_transform.is_equal_approx(_placed):
		_yaw_rad = atan2(global_basis.z.x, global_basis.z.z)
	var previous_speed_m_s := speed_m_s
	speed_m_s = _commanded_speed_m_s
	steering_rad = _commanded_steering_rad
	var rear_axle := global_position + BicycleModel.heading(_yaw_rad) * spec.rear_axle_z
	var turning_rad := BicycleModel.grip_limited_steering(
		steering_rad, speed_m_s, spec.wheelbase_m(), spec.max_lateral_acceleration_m_s2
	)
	var motion := BicycleModel.advance(
		{"rear_axle": rear_axle, "yaw_rad": _yaw_rad},
		speed_m_s,
		turning_rad,
		spec.wheelbase_m(),
		delta
	)
	var heading := BicycleModel.heading(motion["yaw_rad"])
	var target := _on_ground(motion["rear_axle"] - heading * spec.rear_axle_z, heading)
	# Steering always turns the vehicle, so it can turn away from what it touches.
	_yaw_rad = motion["yaw_rad"]
	yaw_rate_rad_s = motion["yaw_rate_rad_s"]
	var move := _move_past_obstacles(target)
	if move["speed_kept"] < 1.0:
		# Against an obstacle: it slides along it, keeping the share of its speed that runs
		# along the obstacle; head-on, it stops.
		speed_m_s *= move["speed_kept"]
		target = _on_ground(move["origin"], heading)
	odometer_m += signf(speed_m_s) * move["distance_m"]
	longitudinal_acceleration_m_s2 = (speed_m_s - previous_speed_m_s) / delta
	_placed = target
	global_transform = _placed
	_turn_wheels()


func _set_up_body_shape() -> void:
	var bottom_m := maxf(spec.body_centre.y - spec.body_size.y * 0.5, MIN_BODY_CLEARANCE_M)
	var top_m := spec.body_centre.y + spec.body_size.y * 0.5
	_body_shape.size = Vector3(spec.body_size.x, top_m - bottom_m, spec.body_size.z)
	_body_centre = Vector3(spec.body_centre.x, (bottom_m + top_m) * 0.5, spec.body_centre.z)


func _move_past_obstacles(target: Transform3D) -> Dictionary:
	## Where the body ends up moving towards `target` (`origin`), how far it went (`distance_m`)
	## and the share of its speed it keeps (`speed_kept`): all of it when the way is clear;
	## against an obstacle, it goes to the contact and slides along the obstacle with the part
	## of the rest of its move that runs along it.
	var start := global_position
	var motion := target.origin - start
	if motion.is_zero_approx():
		return {"origin": target.origin, "distance_m": 0.0, "speed_kept": 1.0}
	var hit := _first_contact(target.basis, start, motion)
	if float(hit["share"]) >= 1.0:
		return {"origin": target.origin, "distance_m": motion.length(), "speed_kept": 1.0}
	var hit_share: float = hit["share"]
	var reached: Vector3 = start + motion * hit_share
	var rest: Vector3 = motion * (1.0 - hit_share)
	var normal: Vector3 = hit["normal"]
	normal.y = 0.0
	if normal.is_zero_approx():
		return {"origin": reached, "distance_m": (reached - start).length(), "speed_kept": 0.0}
	normal = normal.normalized()
	var along: Vector3 = rest - normal * minf(rest.dot(normal), 0.0)
	var slide_share := 0.0
	if not along.is_zero_approx():
		slide_share = _first_contact(target.basis, reached, along)["share"]
	var origin: Vector3 = reached + along * slide_share
	var kept: float = along.length() / rest.length() if not rest.is_zero_approx() else 0.0
	return {"origin": origin, "distance_m": (origin - start).length(), "speed_kept": kept}


func _first_contact(basis: Basis, from: Vector3, motion: Vector3) -> Dictionary:
	## How much of `motion` the body, turned to `basis`, makes from `from` before touching an
	## obstacle (`share`, 1 when clear), and the obstacle's surface normal there. Already into
	## an obstacle, it moves freely away from it and not at all into it.
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _body_shape
	query.collision_mask = CollisionLayers.OBSTACLES
	query.transform = Transform3D(basis, from) * Transform3D(Basis.IDENTITY, _body_centre)
	var space := get_world_3d().direct_space_state
	# A sweep ignores what the shape starts inside of: that is asked first.
	var touching := space.get_rest_info(query)
	if not touching.is_empty():
		var normal: Vector3 = touching["normal"]
		return {"share": 1.0 if motion.dot(normal) >= 0.0 else 0.0, "normal": normal}
	query.motion = motion
	var shares := space.cast_motion(query)
	if shares[0] >= 1.0:
		return {"share": 1.0, "normal": Vector3.ZERO}
	query.transform.origin += motion * shares[1]
	query.motion = Vector3.ZERO
	var contact := space.get_rest_info(query)
	var contact_normal: Vector3 = contact.get("normal", -motion.normalized())
	return {"share": shares[0], "normal": contact_normal}


func _on_ground(origin: Vector3, heading: Vector3) -> Transform3D:
	## The vehicle at `origin` facing `heading`, resting on the ground under its four wheels
	## (GroundContact), its wheels lifted to their own contacts. Where a wheel finds no ground,
	## the body keeps level at the height of the ground under its origin.
	var sideways := Vector3.UP.cross(heading)
	var contacts: Array[Vector3] = []
	for wheel in _wheels:
		var under_wheel := origin + sideways * wheel.position.x + heading * wheel.position.z
		var ground := _ground_below(under_wheel)
		if ground.is_empty():
			return _level_on_ground(origin, heading)
		contacts.append(ground["position"])
	var fit := GroundContact.fit(origin, contacts)
	var lifts: Array = fit["wheel_lifts_m"]
	for index in _wheels.size():
		_wheels[index].position.y = spec.wheel_radius_m + lifts[index]
	return fit["pose"]


func _level_on_ground(origin: Vector3, heading: Vector3) -> Transform3D:
	var ground := _ground_below(origin)
	if not ground.is_empty():
		origin.y = ground["position"].y
	return Transform3D(Basis(Vector3.UP.cross(heading), Vector3.UP, heading), origin)


func _ground_below(point: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * GROUND_PROBE_ABOVE_M, point + Vector3.DOWN * GROUND_PROBE_BELOW_M
	)
	return get_world_3d().direct_space_state.intersect_ray(query)


func _turn_wheels() -> void:
	var roll_rad := odometer_m / spec.wheel_radius_m
	for index in _wheels.size():
		var steer_rad := steering_rad if index < 2 else 0.0
		_wheels[index].basis = Basis(Vector3.UP, steer_rad) * Basis(Vector3.RIGHT, roll_rad)
