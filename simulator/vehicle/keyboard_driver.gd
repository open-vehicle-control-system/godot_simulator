class_name KeyboardDriver
extends Node
## Drives the vehicle from the arrow keys (--keyboard), for looking around a track without OVCS.

var _vehicle: Vehicle


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
	_vehicle.actuate(
		KeyboardDrive.next(
			_vehicle.actuation.steering_rad,
			_vehicle.speed_m_s,
			_vehicle.driven_wheel_speed_rad_s(),
			keys,
			delta,
			_vehicle.spec
		)
	)
