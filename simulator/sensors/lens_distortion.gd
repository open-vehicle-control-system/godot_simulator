class_name LensDistortion
extends RefCounted
## A lens's distortion in OpenCV's model, over normalised image coordinates (x right, y down,
## the optical axis at the origin, in units of the focal length): radial k1, k2, k3 and
## tangential p1, p2. `sensors/shaders/distortion.inc` undistorts the same way on the GPU.

const UNDISTORTION_STEPS := 12
## How close to its point an undistorted border point must distort back, in focal lengths.
const FOLD_TOLERANCE := 1e-3
const BORDER_SAMPLES := 16

var k1: float
var k2: float
var p1: float
var p2: float
var k3: float


func _init(opencv_coefficients: Array) -> void:
	## From `[k1, k2, p1, p2, k3]`, OpenCV's order.
	k1 = opencv_coefficients[0]
	k2 = opencv_coefficients[1]
	p1 = opencv_coefficients[2]
	p2 = opencv_coefficients[3]
	k3 = opencv_coefficients[4]


func coefficients() -> Array:
	## `[k1, k2, p1, p2, k3]`, OpenCV's order.
	return [k1, k2, p1, p2, k3]


func distorted(point: Vector2) -> Vector2:
	## Where the lens shows the point a pinhole shows at `point`.
	return point * _radial(point) + _tangential(point)


func undistorted(point: Vector2) -> Vector2:
	## Where a pinhole shows what the lens shows at `point`.
	var pinhole := point
	for step in UNDISTORTION_STEPS:
		pinhole = (point - _tangential(pinhole)) / _radial(pinhole)
	return pinhole


func overscan(half_extent: Vector2) -> float:
	## How many times wider and higher than an image reaching `half_extent` from its centre
	## the pinhole view holding all the lens shows in it is; 1 at least.
	var widest := 1.0
	for point in _border(half_extent):
		var pinhole := undistorted(point)
		widest = maxf(widest, absf(pinhole.x) / half_extent.x)
		widest = maxf(widest, absf(pinhole.y) / half_extent.y)
	return widest


func folds(half_extent: Vector2) -> bool:
	## True when, within an image reaching `half_extent`, the lens shows a point twice: its
	## border cannot be undistorted.
	for point in _border(half_extent):
		if distorted(undistorted(point)).distance_to(point) > FOLD_TOLERANCE:
			return true
	return false


func _radial(point: Vector2) -> float:
	var r2 := point.length_squared()
	return 1.0 + r2 * (k1 + r2 * (k2 + r2 * k3))


func _tangential(point: Vector2) -> Vector2:
	var r2 := point.length_squared()
	return Vector2(
		2.0 * p1 * point.x * point.y + p2 * (r2 + 2.0 * point.x * point.x),
		p1 * (r2 + 2.0 * point.y * point.y) + 2.0 * p2 * point.x * point.y
	)


static func _border(half_extent: Vector2) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for sample in BORDER_SAMPLES + 1:
		var along := 2.0 * sample / BORDER_SAMPLES - 1.0
		for side in [-1.0, 1.0]:
			points.append(Vector2(along * half_extent.x, side * half_extent.y))
			points.append(Vector2(side * half_extent.x, along * half_extent.y))
	return points
