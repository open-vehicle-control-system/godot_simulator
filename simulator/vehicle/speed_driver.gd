class_name SpeedDriver
extends Node
## Drives the vehicle at a speed and steering by SpeedControl: held (--hold), or as a drive log
## tells (--drive-log), its time counted in physics steps from the first: the same drive at the
## same step, run after run.

var _vehicle: Vehicle
var _log: DriveLog = null
var _held := [0.0, 0.0]  # speed_m_s, steering_rad
var _control := SpeedControl.new()
var _time_s := 0.0


func hold(vehicle: Vehicle, speed_m_s: float, steering_rad: float) -> void:
	## Holds `vehicle` at `speed_m_s` with its front wheels at `steering_rad` from now on.
	_vehicle = vehicle
	_held = [speed_m_s, steering_rad]
	name = "SpeedDriver"


func follow(vehicle: Vehicle, log: DriveLog) -> void:
	## Drives `vehicle` as `log` tells from now on.
	_vehicle = vehicle
	_log = log
	name = "SpeedDriver"


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_vehicle):
		queue_free()
		return
	var drive: Array = _log.drive_at(_time_s) if _log != null else _held
	_vehicle.actuate(_control.next(drive[0], drive[1], _vehicle.speed_m_s, delta, _vehicle.spec))
	_time_s += delta
