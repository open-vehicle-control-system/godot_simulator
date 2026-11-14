class_name TreeTrunks
extends Node3D
## Tree trunks as collision: one static physics body holding a cylinder per tree, registered
## with the physics server directly, because a scene node per tree makes large forests slow to
## load.

const RADIUS_M := 0.3
const HEIGHT_M := 3.0

var _body := PhysicsServer3D.body_create()
var _trunk := CylinderShape3D.new()


func _init(standing_at: Array[Vector3]) -> void:
	name = "TreeTrunks"
	_trunk.radius = RADIUS_M
	_trunk.height = HEIGHT_M
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	for foot in standing_at:
		var centre := Transform3D(Basis.IDENTITY, foot + Vector3.UP * HEIGHT_M * 0.5)
		PhysicsServer3D.body_add_shape(_body, _trunk.get_rid(), centre)


func _enter_tree() -> void:
	PhysicsServer3D.body_set_space(_body, get_world_3d().space)


func _exit_tree() -> void:
	PhysicsServer3D.body_set_space(_body, RID())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		PhysicsServer3D.free_rid(_body)
