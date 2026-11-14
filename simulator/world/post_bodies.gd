class_name PostBodies
extends Node3D
## Posts and poles as collision: one static physics body holding an upright cylinder per post,
## registered with the physics server directly, as tree trunks are.

var _body := PhysicsServer3D.body_create()
var _shapes: Dictionary[Vector2, CylinderShape3D] = {}


func _init() -> void:
	name = "PostBodies"
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)


func add_post(foot: Vector3, diameter_m: float, height_m: float) -> void:
	## Stands a post of this size on `foot`.
	var size := Vector2(diameter_m, height_m)
	if not _shapes.has(size):
		var cylinder := CylinderShape3D.new()
		cylinder.radius = diameter_m * 0.5
		cylinder.height = height_m
		_shapes[size] = cylinder
	var centre := Transform3D(Basis.IDENTITY, foot + Vector3.UP * height_m * 0.5)
	PhysicsServer3D.body_add_shape(_body, _shapes[size].get_rid(), centre)


func _enter_tree() -> void:
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


func _exit_tree() -> void:
	PhysicsServer3D.body_set_space(_body, RID())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		PhysicsServer3D.free_rid(_body)
