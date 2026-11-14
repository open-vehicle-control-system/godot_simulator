extends TestCase
## Where each view looks from, relative to the vehicle.

const LENGTH_M := 3.9


func test_cockpit_looks_ahead_from_the_drivers_eye() -> void:
	var spec := _spec()
	var vehicle := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(5.0, 0.0, 0.0))

	var pose := ViewPoses.pose("cockpit", vehicle, spec, vehicle.basis.z)

	assert_almost_eq(pose.origin, vehicle * spec.driver_eye, 1e-5)
	var looking := -pose.basis.z
	assert_almost_eq(looking, Vector3(cos(deg_to_rad(-3.0)), sin(deg_to_rad(-3.0)), 0.0), 1e-4)


func test_chase_follows_behind_and_above_scaled_to_the_vehicle() -> void:
	var spec := _spec()
	var vehicle := Transform3D.IDENTITY

	var pose := ViewPoses.pose("chase", vehicle, spec, Vector3.BACK)

	assert_true(pose.origin.z < -LENGTH_M, "behind: %s" % pose.origin)
	assert_true(pose.origin.y > 1.0, "above: %s" % pose.origin)
	assert_true(-pose.basis.z.z > 0.9, "looking forward")


func test_every_view_has_a_pose() -> void:
	for view in ViewPoses.VIEWS:
		var pose := ViewPoses.pose(view, Transform3D.IDENTITY, _spec(), Vector3.BACK)
		assert_true(pose.basis.determinant() > 0.99, view)


func test_next_view_cycles_through_them_all() -> void:
	var view := "front"

	view = ViewPoses.next_view(view)

	assert_eq(view, "chase")
	assert_eq(ViewPoses.next_view("chase"), "cockpit")


func test_only_the_drivers_seat_sees_the_mirrors() -> void:
	for view in ViewPoses.VIEWS:
		assert_eq(ViewPoses.sees_mirrors(view), view == "cockpit", view)


func _spec() -> VehicleSpec:
	var spec := VehicleSpec.new()
	spec.body_size = Vector3(1.6, 1.0, LENGTH_M)
	spec.driver_eye = Vector3(0.38, 1.1, -0.2)
	spec.driver_pitch_deg = -3.0
	return spec
