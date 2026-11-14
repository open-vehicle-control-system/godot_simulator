class_name ShapeBody
extends Node3D
## Shapes as collision in one static physics body registered with the physics server directly,
## as tree trunks are: the body holds the shapes as they were built, where a CollisionShape3D
## node has a debug build of the engine build its shape again.

var _body := PhysicsServer3D.body_create()
var _shapes: Array[Shape3D] = []


func _init(layer: int) -> void:
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(_body, layer)


func add_shape(shape: Shape3D, placed: Transform3D) -> void:
	## Holds `shape` at `placed`.
	_shapes.append(shape)
	PhysicsServer3D.body_add_shape(_body, shape.get_rid(), placed)


func shape_count() -> int:
	## How many shapes it holds.
	return _shapes.size()


func _enter_tree() -> void:
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


func _exit_tree() -> void:
	PhysicsServer3D.body_set_space(_body, RID())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		PhysicsServer3D.free_rid(_body)
