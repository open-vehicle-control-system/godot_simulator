class_name Instruments
extends Node
## The cockpit's moving parts: the speedometer and rev counter needles and the steering wheel,
## each turned about its own pivot to show the vehicle's speed, its motor's speed in the gear in
## use (Powertrain) and its steering, by the scales of the vehicle pack's `instruments`
## (InstrumentScales).

const KM_H_PER_M_S := 3.6


## A part of the model and where it rests at a reading of zero.
class Part:
	extends RefCounted
	var node: Node3D
	var rest: Basis
	var axis: Vector3

	func turn_to(angle_deg: float) -> void:
		node.basis = InstrumentScales.turned(rest, axis, angle_deg)


var _vehicle: Vehicle
var _speedometer_needle: Part = null
var _rev_counter_needle: Part = null
var _steering_wheel: Part = null


func setup(vehicle: Vehicle, cockpit_parts: Array[Node3D]) -> String:
	## Turns the parts of `cockpit_parts` that the vehicle's instruments name as `vehicle`
	## moves. Returns "" or what is wrong with the pack.
	_vehicle = vehicle
	name = "Instruments"
	var instruments := vehicle.spec.instruments
	var named := {}
	if instruments.speedometer != null:
		named["speedometer"] = [instruments.speedometer.node, instruments.speedometer.axis]
	if instruments.rev_counter != null:
		named["rev_counter"] = [instruments.rev_counter.node, instruments.rev_counter.axis]
	if instruments.steering_wheel != null:
		named["steering_wheel"] = [instruments.steering_wheel.node, instruments.steering_wheel.axis]
	var parts := {}
	for instrument in named:
		var node_name: String = named[instrument][0]
		var found := cockpit_parts.filter(func(part): return String(part.name) == node_name)
		if found.is_empty():
			return (
				"%s: vehicle.instruments.%s.node names %s, which is not a cockpit part of the model"
				% [vehicle.spec.id, instrument, node_name]
			)
		var part := Part.new()
		part.node = found[0]
		part.rest = part.node.basis
		part.axis = named[instrument][1]
		parts[instrument] = part
	_speedometer_needle = parts.get("speedometer")
	_rev_counter_needle = parts.get("rev_counter")
	_steering_wheel = parts.get("steering_wheel")
	return ""


func _process(_delta: float) -> void:
	if _vehicle == null:
		return
	var spec := _vehicle.spec
	var instruments := spec.instruments
	if _speedometer_needle != null:
		var speed_km_h := absf(_vehicle.speed_m_s) * KM_H_PER_M_S
		_speedometer_needle.turn_to(
			InstrumentScales.dial_angle_deg(instruments.speedometer.dial, speed_km_h)
		)
	if _rev_counter_needle != null:
		var rev_counter := instruments.rev_counter
		var rpm := Powertrain.motor_rpm(spec, _vehicle.speed_m_s)
		_rev_counter_needle.turn_to(
			InstrumentScales.rev_counter_angle_deg(
				rpm, rev_counter.deg_per_rpm, rev_counter.max_rpm
			)
		)
	if _steering_wheel != null:
		var steering_wheel := instruments.steering_wheel
		_steering_wheel.turn_to(
			InstrumentScales.steering_wheel_angle_deg(
				_vehicle.steering_rad, steering_wheel.ratio, steering_wheel.lock_deg
			)
		)
