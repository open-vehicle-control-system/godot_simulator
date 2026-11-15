class_name Route
extends RefCounted
## A track's centre line (`track.route`): points in its world, closed for a circuit, with the
## distance along it and its curvature. Pure. Distances wrap around a closed route.

## A route needs this many points.
const MIN_POINTS := 2
## Curvature is taken over this length of the line either side of a point: a corner's, not
## its points' jitter.
const CURVATURE_SPAN_M := 6.0

var points: PackedVector3Array = []  ## in Godot's world frame
var closed := false
var length_m := 0.0
var _distances_m := PackedFloat64Array()  ## along the line to each point
var _curvatures := PackedFloat64Array()  ## 1/m at each point, positive turning left


static func parse(reader: ManifestReader, directory: String) -> Route:
	## The route in the file `route` names in `reader`; `reader.error` tells what is wrong.
	var route := Route.new()
	var path := reader.file("route", directory)
	if reader.error != "":
		return route
	var read: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var file := ManifestReader.new(
		reader.pack_id, read if read is Dictionary else {}, path.get_file() + ": "
	)
	var listed := file.list("points_m")
	for index in listed.size():
		route.points.append(file.ros_vector("points_m.%d" % index))
	file.check(route.points.size() >= MIN_POINTS, "points_m")
	route.closed = file.boolean("closed")
	if file.error == "":
		route._measure()
		file.check(route.length_m > 0.0, "points_m")
	if reader.error == "":
		reader.error = file.error
	return route


static func of(line: PackedVector3Array, is_closed: bool) -> Route:
	## The route along `line`.
	var route := Route.new()
	route.points = line
	route.closed = is_closed
	route._measure()
	return route


func nearest_m(position: Vector3, near_m := -1.0) -> float:
	## The distance along the route of its point nearest to `position` across the ground (its
	## height aside); with `near_m` at or above 0, looked for only within a few points of it.
	var count := _segments()
	var first := 0
	var last := count - 1
	if near_m >= 0.0 and count > 64:
		var at := _index_at(near_m)
		first = at - 32
		last = at + 32
	var best_m := 0.0
	var best_square := INF
	var flat := Vector2(position.x, position.z)
	for step in range(first, last + 1):
		var index := posmod(step, count) if closed else clampi(step, 0, count - 1)
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		var start := Vector2(a.x, a.z)
		var segment := Vector2(b.x, b.z) - start
		var share := 0.0
		if segment.length_squared() > 0.0:
			share = clampf((flat - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		var square := (start + segment * share).distance_squared_to(flat)
		if square < best_square:
			best_square = square
			best_m = _distances_m[index] + share * segment.length()
	return best_m


func point_at(distance_m: float) -> Vector3:
	## The point `distance_m` along the route: wrapped on a closed one, its end beyond an open one.
	var along := _wrapped(distance_m)
	var index := _index_at(along)
	var a := points[index]
	var b := points[(index + 1) % points.size()]
	var span := _distances_m[index + 1] - _distances_m[index]
	return a.lerp(b, (along - _distances_m[index]) / span if span > 0.0 else 0.0)


func curvature_at(distance_m: float) -> float:
	## The line's curvature `distance_m` along it, 1/m, positive turning left.
	return _curvatures[_index_at(_wrapped(distance_m))]


func offset_m(position: Vector3, distance_m: float) -> float:
	## How far `position` is across the ground from the route's point `distance_m` along it.
	var on := point_at(distance_m)
	return Vector2(position.x - on.x, position.z - on.z).length()


func _measure() -> void:
	_distances_m = PackedFloat64Array([0.0])
	for index in _segments():
		var a := points[index]
		var b := points[(index + 1) % points.size()]
		_distances_m.append(_distances_m[-1] + Vector2(b.x - a.x, b.z - a.z).length())
	length_m = _distances_m[-1]
	_curvatures.resize(points.size())
	for index in points.size():
		var here := _distances_m[index]
		var before := _index_at(_wrapped(here - CURVATURE_SPAN_M))
		var after := _index_at(_wrapped(here + CURVATURE_SPAN_M))
		# The heading turns between the two segments' middles.
		var span_m := _middle_m(after) - _middle_m(before)
		if closed and span_m < 0.0:
			span_m += length_m
		# Godot's yaw grows from +Z towards +X: left, in the vehicle's frame.
		_curvatures[index] = (
			angle_difference(_heading(before), _heading(after)) / span_m if span_m > 0.0 else 0.0
		)


func _middle_m(segment: int) -> float:
	return (_distances_m[segment] + _distances_m[segment + 1]) * 0.5


func _heading(segment: int) -> float:
	## The yaw of the line's segment `segment`, about +Y from +Z towards +X.
	var index := segment
	var a := points[index]
	var b := points[(index + 1) % points.size()]
	return atan2(b.x - a.x, b.z - a.z)


func _segments() -> int:
	return points.size() if closed else points.size() - 1


func _wrapped(distance_m: float) -> float:
	if closed:
		return fposmod(distance_m, length_m)
	return clampf(distance_m, 0.0, length_m)


func _index_at(distance_m: float) -> int:
	## The segment `distance_m` along the route lies on.
	var index := _distances_m.bsearch(_wrapped(distance_m), true) - 1
	return clampi(index, 0, _segments() - 1)
