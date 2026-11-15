class_name KeyboardDriver
extends Node
## Drives the vehicle from the arrow keys (--keyboard), for looking around a track without OVCS.

var _vehicle: Vehicle
var _drive := {"speed_m_s": 0.0, "steering_rad": 0.0}


func setup(vehicle: Vehicle) -> void:
	## Drives `vehicle` from now on.
	_vehicle = vehicle
	name = "KeyboardDriver"


func _physics_process(delta: float) -> void:
	var keys := {
		"up": Input.is_physical_key_pressed(KEY_UP),
		"down": Input.is_physical_key_pressed(KEY_DOWN),
		"left": Input.is_physical_key_pressed(KEY_LEFT),
		"right": Input.is_physical_key_pressed(KEY_RIGHT),
	}
	# An obstacle may have stopped the vehicle: drive on from its real speed.
	_drive["speed_m_s"] = _vehicle.speed_m_s
	_drive = KeyboardDrive.next(_drive, keys, delta, _vehicle.spec)
	_vehicle.command(_drive["speed_m_s"], _drive["steering_rad"])
