class_name Vehicle
extends RigidBody3D
## The vehicle: a rigid body on four sprung wheels, moved only by its actuation (drive torque,
## brake torque, steering) through its tyres, over the world's ground and against what stands
## on it. Its driver sets the actuation: OVCS over the link, the keyboard, a speed hold or a
## drive log.
##
## Each wheel finds the ground with a ray down its suspension, along the body's up axis. Its
## spring is preloaded to carry its share of the weight at the pack's ride height, damped, with
## a bump stop at the end of its travel; anti-roll bars bring each axle's roll stiffness to its
## pack share of a total that leans the body ROLL_GRADIENT_RAD_PER_G. The tyres' forces
## (Wheels, Tyre) act at their contacts; the air's drag at the centre of mass; the body box
## collides with obstacles and, off its wheels, with the ground.
##
## Frame: +X left, +Y up, +Z forward, the origin on the ground at rest.

const GRAVITY_M_S2 := 9.81
## The body box never reaches lower above the ground at rest than this many wheel radii, so
## kerbs and the ground's own bumps pass under it.
const MIN_BODY_CLEARANCE_PER_WHEEL_RADIUS := 0.6
const WHEEL_NAMES := ["WheelFrontLeft", "WheelFrontRight", "WheelRearLeft", "WheelRearRight"]
## The link's names of the wheels, in the same order.
const WHEEL_KEYS := ["front_left", "front_right", "rear_left", "rear_right"]
## How far a wheel moves up or down from its rest position on the body, in wheel radii: a
## passenger car's 10 cm.
const SUSPENSION_TRAVEL_PER_WHEEL_RADIUS := 0.3
## The body's bounce on its springs, and how much of critical damping their dampers give.
const RIDE_FREQUENCY_HZ := 1.5
const SUSPENSION_DAMPING_RATIO := 0.35
## How far the body leans per g of cornering: a passenger car's 4 degrees.
const ROLL_GRADIENT_RAD_PER_G := 0.07
## Past its travel, a wheel meets a bump stop this many times stiffer than its spring.
const BUMP_STOP_STIFFNESS_FACTOR := 10.0
## The wheel's ray starts this many wheel radii above its highest position, so a wheel pushed
## past its bump stop still finds the ground.
const RAY_ABOVE_TRAVEL_PER_WHEEL_RADIUS := 1.0
const BODY_FRICTION := 0.4
## The brake torque that parks the vehicle, per newton of weight times the wheel radius: more
## than the tyres pass on.
const PARKING_BRAKE_PER_WEIGHT := 1.5

var spec: VehicleSpec
var actuation := Actuation.new()
var wheels: Wheels
var odometer_m := 0.0  ## along its heading, signed: reversing counts down
var speed_m_s := 0.0  ## of its origin along its heading
var steering_rad := 0.0  ## front wheels, bicycle equivalent, positive left
var yaw_rate_rad_s := 0.0
var wheel_in_contact: Array[bool] = [false, false, false, false]

var suspension_travel_m: float
var _wheel_nodes: Array[Node3D] = []
var _hubs: Array[Vector3] = []  ## each wheel's centre at rest, in the vehicle frame
var _compression_m := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _springs_n_per_m := PackedFloat64Array()
var _dampers_n_s_per_m := PackedFloat64Array()
var _anti_roll_n_per_m := PackedFloat64Array()  ## front axle, rear axle
var _loads_n := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _motion := {}
var _previous_velocity := Vector3.ZERO
var _has_previous_velocity := false


func setup(vehicle_spec: VehicleSpec, model: VehicleModel) -> void:
	## Shows `model` as this vehicle, with a wheel at each corner `vehicle_spec` gives, parked.
	spec = vehicle_spec
	name = "Vehicle"
	suspension_travel_m = SUSPENSION_TRAVEL_PER_WHEEL_RADIUS * spec.wheel_radius_m
	process_physics_priority = -10  # its motion is read by what follows
	_set_up_body()
	add_child(model.body)
	for part in model.cockpit_parts:
		add_child(part)
	for axle_z in [spec.front_axle_z, spec.rear_axle_z]:
		var track_m := spec.front_track_m if axle_z == spec.front_axle_z else spec.rear_track_m
		for side in [1.0, -1.0]:
			var pivot := Node3D.new()
			pivot.name = WHEEL_NAMES[_wheel_nodes.size()]
			pivot.position = Vector3(side * track_m * 0.5, spec.wheel_radius_m, axle_z)
			_hubs.append(pivot.position)
			var wheel := model.wheel.duplicate() as Node3D
			if side < 0.0:
				wheel.rotate_y(PI)  # outer face to the right
			pivot.add_child(wheel)
			add_child(pivot)
			_wheel_nodes.append(pivot)
	model.wheel.free()
	wheels = Wheels.of(spec)
	_set_up_suspension()
	park()
	_update_motion(1.0)


func actuate(next: Actuation) -> void:
	## Drives by `next` from the next physics step on.
	actuation = next


func park() -> void:
	## Brakes hard enough to hold the vehicle on any slope its tyres hold on, no drive, keeping
	## the steering.
	actuate(
		Actuation.of(
			0.0,
			parking_brake_torque_n_m(),
			actuation.steering_rad,
			actuation.driveline_inertia_kg_m2
		)
	)


func parking_brake_torque_n_m() -> float:
	return PARKING_BRAKE_PER_WEIGHT * spec.mass_kg * GRAVITY_M_S2 * spec.wheel_radius_m


func place(where: Transform3D, rolling_m_s := 0.0) -> void:
	## Moves the vehicle to `where` (its origin on the ground), at rest or rolling straight
	## ahead at `rolling_m_s` without slip.
	global_transform = where
	linear_velocity = where.basis.z.normalized() * rolling_m_s
	angular_velocity = Vector3.ZERO
	wheels.roll_at(rolling_m_s)
	for index in 4:
		_compression_m[index] = 0.0
		wheel_in_contact[index] = false
	_has_previous_velocity = false
	_update_motion(1.0)


func motion_state() -> Dictionary:
	## The pose in the world and, in the vehicle frame, the velocities and what an IMU reads
	## (the motion's acceleration plus gravity's reaction), all of the origin.
	return _motion


func wheel_states() -> Dictionary:
	## Per wheel (WHEEL_KEYS): `angle_rad` turned since the start, `omega_rad_s`, both
	## positive rolling forward, and `in_contact` with the ground.
	var states := {}
	for index in 4:
		states[WHEEL_KEYS[index]] = {
			"angle_rad": wheels.angle_rad[index],
			"omega_rad_s": wheels.omega_rad_s[index],
			"in_contact": wheel_in_contact[index],
		}
	return states


func driven_wheel_speed_rad_s() -> float:
	## The driven wheels' mean spin: what the motor turns with, through the gearbox.
	var sum_rad_s := 0.0
	var count := 0
	for axle in wheels.driven_axles:
		for index in axle:
			sum_rad_s += wheels.omega_rad_s[index]
			count += 1
	return sum_rad_s / count


func wheel_steering_rad(index: int) -> float:
	## The angle of wheel `index` for the bicycle-equivalent steering: Ackermann's, the inner
	## wheel turning more.
	if index >= 2:
		return 0.0
	var turning_rad := actuation.steering_rad
	if absf(turning_rad) < 1e-6:
		return turning_rad
	var wheelbase_m := spec.wheelbase_m()
	var radius_m := wheelbase_m / tan(turning_rad)  # positive: the centre to the left
	var side_m := spec.front_track_m * 0.5 * (1.0 if index == 0 else -1.0)
	return atan(wheelbase_m / (radius_m - side_m))


func _physics_process(delta: float) -> void:
	if spec == null:
		return
	_update_motion(delta)
	odometer_m += speed_m_s * delta
	for index in 4:
		var pivot := _wheel_nodes[index]
		var compression_m := (
			_compression_m[index] if wheel_in_contact[index] else -suspension_travel_m
		)
		pivot.position = _hubs[index] + Vector3.UP * compression_m
		pivot.basis = (
			Basis(Vector3.UP, wheel_steering_rad(index))
			* Basis(Vector3.RIGHT, wheels.angle_rad[index])
		)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if spec == null:
		return
	var delta_s := state.step
	var placed := state.transform
	var up := placed.basis.y.normalized()
	var forward := placed.basis.z.normalized()
	var centre := placed.origin + state.center_of_mass
	var space := state.get_space_state()
	var hits: Array[Dictionary] = []
	for index in 4:
		var hub := placed * _hubs[index]
		var query := PhysicsRayQueryParameters3D.create(
			(
				hub
				+ (
					up
					* (
						suspension_travel_m
						+ RAY_ABOVE_TRAVEL_PER_WHEEL_RADIUS * spec.wheel_radius_m
					)
				)
			),
			hub - up * (suspension_travel_m + spec.wheel_radius_m),
			CollisionLayers.OBSTACLES | CollisionLayers.GROUND,
			[get_rid()]
		)
		var hit := space.intersect_ray(query)
		var in_contact := not hit.is_empty()
		var compression_m := -suspension_travel_m
		if in_contact:
			compression_m = (hit["position"] + up * spec.wheel_radius_m - hub).dot(up)
		var rate_m_s := 0.0
		if in_contact and wheel_in_contact[index]:
			rate_m_s = (compression_m - _compression_m[index]) / delta_s
		_compression_m[index] = compression_m
		wheel_in_contact[index] = in_contact
		_loads_n[index] = _spring_force_n(index, compression_m, rate_m_s) if in_contact else 0.0
		hits.append(hit)
	_add_anti_roll()
	var contacts: Array[Dictionary] = []
	var directions: Array = []
	for index in 4:
		_loads_n[index] = maxf(_loads_n[index], 0.0)
		var hit := hits[index]
		if hit.is_empty():
			contacts.append({"along_m_s": 0.0, "across_m_s": 0.0, "load_n": 0.0})
			directions.append([])
			continue
		var normal: Vector3 = hit["normal"]
		var heading := forward.rotated(up, wheel_steering_rad(index))
		var along := (heading - normal * heading.dot(normal)).normalized()
		var across := normal.cross(along)
		var point: Vector3 = hit["position"]
		var velocity := state.linear_velocity + state.angular_velocity.cross(point - centre)
		(
			contacts
			. append(
				{
					"along_m_s": velocity.dot(along),
					"across_m_s": velocity.dot(across),
					"load_n": _loads_n[index],
				}
			)
		)
		directions.append([along, across])
	var forces := wheels.advance(
		contacts,
		actuation.drive_torque_n_m,
		_brake_torques_n_m(),
		actuation.driveline_inertia_kg_m2,
		delta_s
	)
	for index in 4:
		if hits[index].is_empty():
			continue
		var along: Vector3 = directions[index][0]
		var across: Vector3 = directions[index][1]
		var force: Vector3 = (
			up * _loads_n[index] + along * forces[index].x + across * forces[index].y
		)
		state.apply_force(force, hits[index]["position"] - placed.origin)
	var velocity := state.linear_velocity
	var drag_n_s2_per_m2 := 0.5 * Powertrain.AIR_DENSITY_KG_M3 * spec.powertrain.drag_area_m2
	state.apply_central_force(-velocity * velocity.length() * drag_n_s2_per_m2)


func _spring_force_n(index: int, compression_m: float, rate_m_s: float) -> float:
	var force_n := (
		wheels.tyres[index].static_load_n
		+ _springs_n_per_m[index] * compression_m
		+ _dampers_n_s_per_m[index] * rate_m_s
	)
	if compression_m > suspension_travel_m:
		force_n += (
			BUMP_STOP_STIFFNESS_FACTOR
			* _springs_n_per_m[index]
			* (compression_m - suspension_travel_m)
		)
	return force_n


func _add_anti_roll() -> void:
	## Each axle's bar moves load from its less compressed wheel to its more compressed one,
	## while both touch the ground.
	for axle in 2:
		var left := axle * 2
		var right := left + 1
		if not (wheel_in_contact[left] and wheel_in_contact[right]):
			continue
		var force_n := _anti_roll_n_per_m[axle] * (_compression_m[left] - _compression_m[right])
		_loads_n[left] += force_n
		_loads_n[right] -= force_n


func _brake_torques_n_m() -> PackedFloat64Array:
	## Each wheel's brake: the total split by the brakes' bias, the rear's share kept its margin
	## below the rear's share of the load, as a proportioning valve does.
	var total_n_m := actuation.brake_torque_n_m
	var load_n := _loads_n[0] + _loads_n[1] + _loads_n[2] + _loads_n[3]
	var rear_load_share := (
		(_loads_n[2] + _loads_n[3]) / load_n
		if load_n > 0.0
		else (spec.front_axle_z - spec.centre_of_gravity_z) / spec.wheelbase_m()
	)
	var rear_share := clampf(
		minf(1.0 - spec.brake_bias_front, rear_load_share - spec.rear_brake_margin), 0.0, 1.0
	)
	var front_n_m := total_n_m * (1.0 - rear_share) * 0.5
	var rear_n_m := total_n_m * rear_share * 0.5
	return PackedFloat64Array([front_n_m, front_n_m, rear_n_m, rear_n_m])


func _update_motion(delta: float) -> void:
	var basis := global_basis.orthonormalized()
	var to_vehicle := basis.inverse()
	var centre := global_transform * center_of_mass
	var velocity := linear_velocity + angular_velocity.cross(global_position - centre)
	var acceleration := Vector3.ZERO
	if _has_previous_velocity:
		acceleration = (velocity - _previous_velocity) / delta
	_previous_velocity = velocity
	_has_previous_velocity = true
	var local_velocity := to_vehicle * velocity
	speed_m_s = local_velocity.z
	yaw_rate_rad_s = angular_velocity.dot(basis.y)
	steering_rad = actuation.steering_rad
	_motion = {
		"pose": global_transform,
		"linear_velocity_m_s": local_velocity,
		"angular_velocity_rad_s": to_vehicle * angular_velocity,
		"linear_acceleration_m_s2": to_vehicle * (acceleration + Vector3.UP * GRAVITY_M_S2),
	}


func _set_up_body() -> void:
	mass = spec.mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, spec.centre_of_gravity_height_m, spec.centre_of_gravity_z)
	# Pitch and roll as a uniform box of the body's size has them; yaw the pack's.
	var size := spec.body_size
	inertia = Vector3(
		spec.mass_kg * (size.z * size.z + size.y * size.y) / 12.0,
		spec.yaw_inertia_kg_m2,
		spec.mass_kg * (size.x * size.x + size.y * size.y) / 12.0
	)
	# Only the air and the tyres slow it: none of the engine's default damping.
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.0
	can_sleep = false
	continuous_cd = true
	collision_layer = CollisionLayers.VEHICLE
	collision_mask = CollisionLayers.OBSTACLES | CollisionLayers.GROUND
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = BODY_FRICTION
	var clearance_m := MIN_BODY_CLEARANCE_PER_WHEEL_RADIUS * spec.wheel_radius_m
	var top_m := spec.body_centre.y + spec.body_size.y * 0.5
	# A body lower than the clearance keeps a sliver above it.
	var bottom_m := minf(
		maxf(spec.body_centre.y - spec.body_size.y * 0.5, clearance_m), top_m - 0.5 * clearance_m
	)
	var box := BoxShape3D.new()
	box.size = Vector3(spec.body_size.x, top_m - bottom_m, spec.body_size.z)
	var shape := CollisionShape3D.new()
	shape.name = "BodyShape"
	shape.shape = box
	shape.position = Vector3(spec.body_centre.x, (bottom_m + top_m) * 0.5, spec.body_centre.z)
	add_child(shape)


func _set_up_suspension() -> void:
	## Springs for the ride frequency on each wheel's share of the mass, and anti-roll bars for
	## the rest of each axle's share of the roll stiffness.
	var angular_frequency := TAU * RIDE_FREQUENCY_HZ
	for index in 4:
		var corner_mass_kg := wheels.tyres[index].static_load_n / GRAVITY_M_S2
		var spring := corner_mass_kg * angular_frequency * angular_frequency
		_springs_n_per_m.append(spring)
		_dampers_n_s_per_m.append(2.0 * SUSPENSION_DAMPING_RATIO * sqrt(spring * corner_mass_kg))
	var roll_stiffness := (
		spec.mass_kg * GRAVITY_M_S2 * spec.centre_of_gravity_height_m / ROLL_GRADIENT_RAD_PER_G
	)
	for axle in 2:
		var track_m := spec.front_track_m if axle == 0 else spec.rear_track_m
		var share := (
			spec.front_roll_stiffness_share if axle == 0 else 1.0 - spec.front_roll_stiffness_share
		)
		# A spring pair resists roll by k t^2 / 2 per radian, a bar by k t^2.
		var from_springs := _springs_n_per_m[axle * 2] * track_m * track_m * 0.5
		_anti_roll_n_per_m.append(
			maxf(roll_stiffness * share - from_springs, 0.0) / (track_m * track_m)
		)
