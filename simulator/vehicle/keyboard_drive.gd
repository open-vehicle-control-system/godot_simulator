class_name KeyboardDrive
extends RefCounted
## Speed and steering from the arrow keys, for driving a track without OVCS (--keyboard). Pure.
##
## Up is full throttle through the vehicle's powertrain (Powertrain), Down brakes and, once
## stopped, reverses; Left and Right steer, less at speed, and the steering returns to centre
## when released. With no key the vehicle coasts, slowed by the air and rolling.

const BRAKING_M_S2 := 8.0
const REVERSE_ACCELERATION_M_S2 := 3.0
const MAX_REVERSE_SPEED_M_S := 4.0
const MAX_STEERING_RAD := 0.5
const STEERING_RATE_RAD_S := 1.2
## At this speed and above the steering lock has shrunk to STEERING_SHARE_AT_FADE_SPEED of
## MAX_STEERING_RAD: enough left to steer into a slide.
const STEERING_FADE_SPEED_M_S := 50.0
const STEERING_SHARE_AT_FADE_SPEED := 0.4
## Below this speed Down reverses instead of braking.
const STOPPED_M_S := 0.05


static func next(
	drive: Dictionary, keys: Dictionary, delta_s: float, spec: VehicleSpec
) -> Dictionary:
	## `drive` (`speed_m_s`, `steering_rad`) of the vehicle `spec` describes after `delta_s`
	## with `keys` held (`up`, `down`, `left`, `right`: true when held).
	var speed_m_s := _next_speed(drive["speed_m_s"], keys, delta_s, spec)
	return {"speed_m_s": speed_m_s, "steering_rad": _next_steering(drive, speed_m_s, keys, delta_s)}


static func _next_speed(
	speed_m_s: float, keys: Dictionary, delta_s: float, spec: VehicleSpec
) -> float:
	var up: bool = keys.get("up", false)
	var down: bool = keys.get("down", false)
	if up and speed_m_s < -STOPPED_M_S:
		return minf(speed_m_s + BRAKING_M_S2 * delta_s, 0.0)
	if up:
		return _full_throttle_speed(speed_m_s, delta_s, spec)
	if down and speed_m_s > STOPPED_M_S:
		return maxf(speed_m_s - BRAKING_M_S2 * delta_s, 0.0)
	if down:
		return maxf(speed_m_s - REVERSE_ACCELERATION_M_S2 * delta_s, -MAX_REVERSE_SPEED_M_S)
	var coasting_m_s2 := Powertrain.coasting_deceleration_m_s2(spec, speed_m_s)
	return move_toward(speed_m_s, 0.0, coasting_m_s2 * delta_s)


static func _full_throttle_speed(speed_m_s: float, delta_s: float, spec: VehicleSpec) -> float:
	## The speed after `delta_s` at full throttle going forwards: it never runs the motor past
	## its rpm limit, nor drops below standstill.
	var forward_m_s := maxf(speed_m_s, 0.0)
	var next_m_s := (
		forward_m_s + Powertrain.full_throttle_acceleration_m_s2(spec, forward_m_s) * delta_s
	)
	var limit_m_s := maxf(forward_m_s, Powertrain.rpm_limited_speed_m_s(spec))
	return clampf(next_m_s, 0.0, limit_m_s)


static func _next_steering(
	drive: Dictionary, speed_m_s: float, keys: Dictionary, delta_s: float
) -> float:
	var speed_share := clampf(absf(speed_m_s) / STEERING_FADE_SPEED_M_S, 0.0, 1.0)
	var lock_rad := MAX_STEERING_RAD * lerpf(1.0, STEERING_SHARE_AT_FADE_SPEED, speed_share)
	var target_rad := 0.0
	if keys.get("left", false):
		target_rad += lock_rad
	if keys.get("right", false):
		target_rad -= lock_rad
	return move_toward(drive["steering_rad"], target_rad, STEERING_RATE_RAD_S * delta_s)
