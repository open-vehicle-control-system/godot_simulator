class_name InstrumentsSpec
extends RefCounted
## A vehicle pack's `instruments`: the cockpit's moving parts and their scales. Each names the
## model's node it turns and the axis it turns about by the right-hand rule, in Godot's vehicle
## frame, as its reading rises.


class Speedometer:
	extends RefCounted
	var node: String
	var axis: Vector3
	var dial: Array[Vector2] = []  ## (km/h, needle degrees) marks, in rising order


class RevCounter:
	extends RefCounted
	var node: String
	var axis: Vector3
	var deg_per_rpm: float
	var max_rpm: float  ## the dial's last mark


class SteeringWheel:
	extends RefCounted
	var node: String
	var axis: Vector3  ## turned about as the vehicle steers left
	var ratio: float  ## steering wheel angle per front wheel angle
	var lock_deg: float  ## as far as it turns either way


var speedometer: Speedometer = null  ## null when the pack has none
var rev_counter: RevCounter = null
var steering_wheel: SteeringWheel = null


static func parse(reader: ManifestReader) -> InstrumentsSpec:
	## The instruments at `instruments` in `reader`; `reader.error` tells what is wrong with
	## them.
	var instruments := InstrumentsSpec.new()
	if reader.has("instruments.speedometer"):
		instruments.speedometer = Speedometer.new()
		instruments.speedometer.node = reader.text("instruments.speedometer.node")
		instruments.speedometer.axis = _axis(reader, "instruments.speedometer.axis")
		instruments.speedometer.dial = _dial(reader, "instruments.speedometer.km_h_to_deg")
	if reader.has("instruments.rev_counter"):
		var rev_counter := RevCounter.new()
		rev_counter.node = reader.text("instruments.rev_counter.node")
		rev_counter.axis = _axis(reader, "instruments.rev_counter.axis")
		rev_counter.deg_per_rpm = reader.positive("instruments.rev_counter.deg_per_rpm")
		rev_counter.max_rpm = reader.positive("instruments.rev_counter.max_rpm")
		instruments.rev_counter = rev_counter
	if reader.has("instruments.steering_wheel"):
		var steering_wheel := SteeringWheel.new()
		steering_wheel.node = reader.text("instruments.steering_wheel.node")
		steering_wheel.axis = _axis(reader, "instruments.steering_wheel.axis")
		steering_wheel.ratio = reader.positive("instruments.steering_wheel.ratio")
		steering_wheel.lock_deg = reader.positive("instruments.steering_wheel.lock_deg")
		instruments.steering_wheel = steering_wheel
	return instruments


static func _axis(reader: ManifestReader, path: String) -> Vector3:
	var axis := reader.ros_vector(path)
	reader.check(not axis.is_zero_approx(), path)
	return axis.normalized()


static func _dial(reader: ManifestReader, path: String) -> Array[Vector2]:
	## The dial's marks: two or more `[reading, degrees]`, their readings rising.
	var dial: Array[Vector2] = []
	var marks := reader.list(path)
	for index in marks.size():
		var mark := reader.numbers("%s.%d" % [path, index], 2)
		reader.check(dial.is_empty() or mark[0] > dial[-1].x, "%s.%d" % [path, index])
		dial.append(Vector2(mark[0], mark[1]))
	reader.check(dial.size() >= 2, path)
	return dial
