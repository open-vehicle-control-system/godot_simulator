class_name TestCase
extends Node
## Base of every test script: tests are its methods named `test_*`, run by run_tests.gd with
## the script in the scene tree, so a test may await physics frames.

const DEFAULT_TOLERANCE := 1e-6

var failures: Array[String] = []
var current_test := ""


func assert_true(condition: bool, message := "") -> void:
	## Records a failure unless `condition` holds.
	if not condition:
		_fail("expected true", message)


func assert_eq(actual: Variant, expected: Variant, message := "") -> void:
	## Records a failure unless `actual == expected`.
	if typeof(actual) != typeof(expected) or actual != expected:
		_fail("expected %s, got %s" % [var_to_str(expected), var_to_str(actual)], message)


func assert_almost_eq(
	actual: Variant, expected: Variant, tolerance := DEFAULT_TOLERANCE, message := ""
) -> void:
	## Records a failure unless `actual` is within `tolerance` of `expected`: numbers, or
	## vectors and colours by their distance.
	var distance: float
	if actual is float or actual is int:
		distance = absf(actual - expected)
	elif actual is Color:
		distance = (_as_vector(actual) - _as_vector(expected)).length()
	else:
		distance = (actual - expected).length()
	if distance > tolerance:
		_fail(
			"expected %s within %s, got %s" % [var_to_str(expected), tolerance, var_to_str(actual)],
			message
		)


func fail(message: String) -> void:
	## Records a failure.
	_fail("failed", message)


func wait_physics_frames(count: int) -> void:
	## Lets `count` physics steps run.
	for step in count:
		await get_tree().physics_frame


func _fail(what: String, message: String) -> void:
	var where := current_test if current_test != "" else "?"
	failures.append("%s: %s%s" % [where, what, (" (%s)" % message) if message != "" else ""])


static func _as_vector(colour: Color) -> Vector4:
	return Vector4(colour.r, colour.g, colour.b, colour.a)
