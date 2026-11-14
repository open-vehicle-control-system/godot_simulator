class_name InstanceBatch
extends RefCounted
## Copies of one mesh to draw together, about a centre the copies are culled by. Filled on any
## thread, it touches no server until `instantiate` makes it a node, on the main thread.

var name: String
var mesh: Mesh
var count := 0
var has_colours := false
var has_custom_data := false
var centre := Vector3.ZERO  ## where the node stands: the copies are stored about it
## How far from the camera its centre may be for the batch to be drawn; 0 for any distance.
var visible_within_m := 0.0
var cast_shadow := GeometryInstance3D.SHADOW_CASTING_SETTING_ON
var _buffer := PackedFloat32Array()  # per copy, as MultiMesh.buffer: transform, colour, custom


func _init(batch_name: String, drawn: Mesh, colours := false, custom_data := false) -> void:
	name = batch_name
	mesh = drawn
	has_colours = colours
	has_custom_data = custom_data


func add(placed: Transform3D, colour := Color.WHITE, custom_data := Color.BLACK) -> void:
	## Adds a copy at `placed`, with the colour and custom data the batch has.
	var basis := placed.basis
	var origin := placed.origin - centre
	_buffer.append_array(
		[
			basis.x.x,
			basis.y.x,
			basis.z.x,
			origin.x,
			basis.x.y,
			basis.y.y,
			basis.z.y,
			origin.y,
			basis.x.z,
			basis.y.z,
			basis.z.z,
			origin.z
		]
	)
	if has_colours:
		_buffer.append_array([colour.r, colour.g, colour.b, colour.a])
	if has_custom_data:
		_buffer.append_array([custom_data.r, custom_data.g, custom_data.b, custom_data.a])
	count += 1


func instantiate() -> MultiMeshInstance3D:
	## The batch as a node.
	var copies := MultiMesh.new()
	copies.transform_format = MultiMesh.TRANSFORM_3D
	copies.use_colors = has_colours
	copies.use_custom_data = has_custom_data
	copies.mesh = mesh
	copies.instance_count = count
	copies.buffer = _buffer
	var drawn := MultiMeshInstance3D.new()
	drawn.name = name
	drawn.multimesh = copies
	drawn.position = centre
	drawn.visibility_range_end = visible_within_m
	drawn.cast_shadow = cast_shadow
	return drawn
