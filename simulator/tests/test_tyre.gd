extends TestCase
## A tyre's force from its tread's deflection: Pacejka's magic formula over the combined slip.


func test_a_small_slip_pushes_by_the_tyres_stiffness() -> void:
	var tyre := _tyre()
	var load_n := tyre.static_load_n
	var lateral_slip := 0.002
	var longitudinal_slip := 0.002

	var across := tyre.force_n(Vector2(0.0, lateral_slip * tyre.lateral_relaxation_m), load_n)
	var along := tyre.force_n(
		Vector2(longitudinal_slip * tyre.longitudinal_relaxation_m, 0.0), load_n
	)

	assert_almost_eq(across.y, tyre.cornering_stiffness_n_per_rad * lateral_slip, 2.0)
	assert_almost_eq(across.x, 0.0, 1e-9)
	assert_almost_eq(along.x, tyre.slip_stiffness_n * longitudinal_slip, 2.0)


func test_never_pushes_harder_than_its_friction_and_slides_a_little_below_it() -> void:
	var tyre := _tyre()
	var load_n := tyre.static_load_n
	var peak := 0.0
	for step in 200:
		var deflection := Vector2(0.0, step * 0.002)
		peak = maxf(peak, tyre.force_n(deflection, load_n).y)
	var sliding := tyre.force_n(tyre.limit_deflection(Vector2(0.0, 10.0), load_n), load_n).y

	assert_almost_eq(peak, tyre.friction * load_n, load_n * 0.01)
	assert_true(
		sliding < peak and sliding > 0.7 * peak, "sliding %.0f N of %.0f N" % [sliding, peak]
	)


func test_pushing_along_the_road_leaves_less_grip_across_it() -> void:
	var tyre := _tyre()
	var load_n := tyre.static_load_n
	var across_m := 0.02

	var cornering := tyre.force_n(Vector2(0.0, across_m), load_n)
	var braking_and_cornering := tyre.force_n(Vector2(-0.02, across_m), load_n)

	assert_true(braking_and_cornering.y < 0.8 * cornering.y, str(braking_and_cornering))
	assert_true(braking_and_cornering.x < 0.0, "brakes")
	assert_true(braking_and_cornering.length() <= tyre.friction * load_n * 1.001)


func test_a_loaded_tyre_holds_more_but_less_per_newton_of_load() -> void:
	var tyre := _tyre()
	var light := tyre.peak_force_n(tyre.static_load_n)
	var heavy := tyre.peak_force_n(tyre.static_load_n * 1.5)

	assert_true(heavy > light, "holds more")
	assert_true(heavy / 1.5 < light, "less per newton")
	assert_eq(tyre.force_n(Vector2(0.01, 0.01), 0.0), Vector2.ZERO, "unloaded, it holds nothing")


func test_its_peak_comes_where_the_magic_formula_peaks() -> void:
	var argument := Tyre.peak_argument(1.3, -1.5)
	var formula := func(t: float) -> float: return sin(1.3 * atan(t + 1.5 * (t - atan(t))))

	assert_almost_eq(formula.call(argument), 1.0, 1e-9)


func _tyre() -> Tyre:
	return Tyre.of(VehicleFixtures.small_car(), true)
