class_name KeyboardDrive
extends RefCounted
## Speed and steering from the arrow keys, for driving a track without OVCS (--keyboard). Pure.
##
## Up accelerates, Down brakes and, once stopped, reverses; Left and Right steer, less at speed,
## and the steering returns to centre when released. With no key the vehicle coasts to a stop.

const ACCELERATION_M_S2 := 3.0
const BRAKING_M_S2 := 8.0
const COASTING_M_S2 := 0.6
const MAX_SPEED_M_S := 50.0
const MAX_REVERSE_SPEED_M_S := 4.0
const MAX_STEERING_RAD := 0.5
const STEERING_RATE_RAD_S := 1.2
## At top speed the steering lock shrinks to this share of MAX_STEERING_RAD: enough left to
## steer into a slide.
const STEERING_SHARE_AT_TOP_SPEED := 0.4
## Below this speed Down reverses instead of braking.
const STOPPED_M_S := 0.05


static func next(drive: Dictionary, keys: Dictionary, delta_s: float) -> Dictionary:
	## `drive` (`speed_m_s`, `steering_rad`) after `delta_s` with `keys` held (`up`, `down`,
	## `left`, `right`: true when held).
	var speed_m_s := _next_speed(drive["speed_m_s"], keys, delta_s)
	return {"speed_m_s": speed_m_s, "steering_rad": _next_steering(drive, speed_m_s, keys, delta_s)}


static func _next_speed(speed_m_s: float, keys: Dictionary, delta_s: float) -> float:
	var up: bool = keys.get("up", false)
	var down: bool = keys.get("down", false)
	if up and speed_m_s < -STOPPED_M_S:
		return minf(speed_m_s + BRAKING_M_S2 * delta_s, 0.0)
	if up:
		return minf(speed_m_s + ACCELERATION_M_S2 * delta_s, MAX_SPEED_M_S)
	if down and speed_m_s > STOPPED_M_S:
		return maxf(speed_m_s - BRAKING_M_S2 * delta_s, 0.0)
	if down:
		return maxf(speed_m_s - ACCELERATION_M_S2 * delta_s, -MAX_REVERSE_SPEED_M_S)
	return move_toward(speed_m_s, 0.0, COASTING_M_S2 * delta_s)


static func _next_steering(
	drive: Dictionary, speed_m_s: float, keys: Dictionary, delta_s: float
) -> float:
	var speed_share := clampf(absf(speed_m_s) / MAX_SPEED_M_S, 0.0, 1.0)
	var lock_rad := MAX_STEERING_RAD * lerpf(1.0, STEERING_SHARE_AT_TOP_SPEED, speed_share)
	var target_rad := 0.0
	if keys.get("left", false):
		target_rad += lock_rad
	if keys.get("right", false):
		target_rad -= lock_rad
	return move_toward(drive["steering_rad"], target_rad, STEERING_RATE_RAD_S * delta_s)
