extends TestCase
## The assertions the other tests rely on.


func test_records_a_failed_equality_with_both_values() -> void:
	var probe := TestCase.new()

	probe.assert_eq(2, 3, "two is three")

	assert_eq(probe.failures.size(), 1)
	assert_true(probe.failures[0].contains("two is three"), probe.failures[0])
	assert_true(probe.failures[0].contains("expected 3, got 2"), probe.failures[0])
	probe.free()


func test_records_nothing_when_assertions_hold() -> void:
	var probe := TestCase.new()

	probe.assert_eq("a", "a")
	probe.assert_true(true)
	probe.assert_almost_eq(1.0, 1.0005, 0.001)

	assert_eq(probe.failures.size(), 0)
	probe.free()


func test_compares_vectors_within_a_tolerance() -> void:
	var probe := TestCase.new()

	probe.assert_almost_eq(Vector3(1, 2, 3), Vector3(1, 2, 3.01), 0.001)

	assert_eq(probe.failures.size(), 1)
	probe.free()
