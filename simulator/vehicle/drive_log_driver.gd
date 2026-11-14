class_name DriveLogDriver
extends Node
## Drives the vehicle as a drive log tells (--drive-log), its time counted in physics steps
## from the first: the same drive at the same step, run after run.

var _vehicle: Vehicle
var _log: DriveLog
var _time_s := 0.0


func setup(vehicle: Vehicle, log: DriveLog) -> void:
	## Drives `vehicle` as `log` tells from now on.
	_vehicle = vehicle
	_log = log
	name = "DriveLogDriver"
	process_physics_priority = -1  # before the vehicle moves
	_command()


func _physics_process(delta: float) -> void:
	_time_s += delta
	_command()


func _command() -> void:
	var drive := _log.drive_at(_time_s)
	_vehicle.command(drive[0], drive[1])
