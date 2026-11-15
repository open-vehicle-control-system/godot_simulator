class_name VehicleFixtures
extends RefCounted
## Vehicles for tests, standing on generated ground.

## Half the side of the flat ground `on_flat_ground` builds.
const GROUND_HALF_SIDE_M := 2000.0


static func on_flat_ground(test: Node, spec: VehicleSpec, where := Transform3D.IDENTITY) -> Vehicle:
	## A vehicle of `spec` standing at `where` on flat ground at height 0, settled on its springs.
	test.add_child(flat_ground())
	var vehicle := Vehicle.new()
	test.add_child(vehicle)
	vehicle.setup(spec, VehicleModel.build(spec)["model"])
	vehicle.place(where)
	await test.wait_physics_frames(Engine.physics_ticks_per_second)
	return vehicle


static func flat_ground() -> StaticBody3D:
	## A ground slab whose top is at height 0.
	var ground := StaticBody3D.new()
	ground.collision_layer = CollisionLayers.GROUND
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(GROUND_HALF_SIDE_M * 2.0, 1.0, GROUND_HALF_SIDE_M * 2.0)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0.0, -0.5, 0.0)
	return ground


static func small_car() -> VehicleSpec:
	## The test packs' small car.
	var directory := PackFixtures.fresh_directory("vehicle_fixture")
	PackFixtures.write_pack(directory, PackFixtures.vehicle_manifest("small_car"))
	return PackLibrary.scan([directory]).load_vehicle("small_car")["vehicle"]


static func hold(test: Node, vehicle: Vehicle, speed_m_s: float, steering_rad: float) -> void:
	## Holds `vehicle` at `speed_m_s` and `steering_rad` by a SpeedDriver from the next step on.
	var driver: SpeedDriver = (
		vehicle.get_meta("speed_driver") if vehicle.has_meta("speed_driver") else null
	)
	if driver == null:
		driver = SpeedDriver.new()
		test.add_child(driver)
		vehicle.set_meta("speed_driver", driver)
	driver.hold(vehicle, speed_m_s, steering_rad)


static func release(vehicle: Vehicle) -> void:
	## Stops holding `vehicle`: from now on only what the test actuates moves it.
	if vehicle.has_meta("speed_driver"):
		var driver: SpeedDriver = vehicle.get_meta("speed_driver")
		vehicle.remove_meta("speed_driver")
		driver.free()
