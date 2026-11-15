class_name LinkProtocol
extends RefCounted
## The OVCS simulator link's packets (OVCS SimulatorCore.Link.Protocol). Pure.
##
## On the wire each packet is a 32-bit big-endian length, then the payload: a 16-bit big-endian
## header length, a JSON header and the message's binary body, if any. `drive` and `instruments`
## come from OVCS; `state` and `image` go to it. Fields follow ROS conventions (REP-103): SI
## units, base_link x forward, y left, z up. Godot's vehicle frame is +X left, +Y up, +Z
## forward, so a ROS vector (x, y, z) is the Godot (z, x, y); worlds map the same way.

## The largest packet OVCS reads.
const MAX_PACKET_BYTES := 16 * 1024 * 1024
const MAX_HEADER_BYTES := 65535
## The number fields of each message OVCS sends.
const FIELDS := {"drive": ["speed_m_s", "steering_rad"], "instruments": ["motor_rpm"]}


## Splits a byte stream into payloads.
class Framer:
	extends RefCounted

	## True once the stream held a length no OVCS packet has: the connection is unusable.
	var broken := false
	var _pending := PackedByteArray()

	func push(bytes: PackedByteArray) -> Array[PackedByteArray]:
		## Adds received bytes; returns the payloads they complete.
		_pending.append_array(bytes)
		var payloads: Array[PackedByteArray] = []
		while not broken and _pending.size() >= 4:
			var length := (
				(_pending[0] << 24) | (_pending[1] << 16) | (_pending[2] << 8) | _pending[3]
			)
			if length > MAX_PACKET_BYTES:
				broken = true
				break
			if _pending.size() < 4 + length:
				break
			payloads.append(_pending.slice(4, 4 + length))
			_pending = _pending.slice(4 + length)
		return payloads


static func packet(header: Dictionary, body := PackedByteArray()) -> PackedByteArray:
	## The framed packet carrying `header` and `body`.
	var json := JSON.stringify(header, "", false, true).to_utf8_buffer()
	assert(json.size() <= MAX_HEADER_BYTES, "a link header must fit its 16-bit length")
	var stream := StreamPeerBuffer.new()
	stream.big_endian = true
	stream.put_u32(2 + json.size() + body.size())
	stream.put_u16(json.size())
	stream.put_data(json)
	stream.put_data(body)
	return stream.data_array


static func encode_state(state: Dictionary) -> PackedByteArray:
	## A `state` packet. `state` holds `time_s`, `odometer_m`, `pose` (the vehicle's Transform3D in
	## the Godot world) and, in the Godot vehicle frame, `linear_velocity_m_s`,
	## `angular_velocity_rad_s` and `linear_acceleration_m_s2` (what an IMU reads, gravity included).
	var pose: Transform3D = state["pose"]
	var rotation := pose.basis.orthonormalized().get_rotation_quaternion()
	return packet(
		{
			"type": "state",
			"time_s": state["time_s"],
			"odometer_m": state["odometer_m"],
			"position_m": to_ros(pose.origin),
			"orientation": [rotation.z, rotation.x, rotation.y, rotation.w],
			"linear_velocity_m_s": to_ros(state["linear_velocity_m_s"]),
			"angular_velocity_rad_s": to_ros(state["angular_velocity_rad_s"]),
			"linear_acceleration_m_s2": to_ros(state["linear_acceleration_m_s2"]),
		}
	)


static func encode_image(
	camera: String, time_s: float, format: String, image: PackedByteArray
) -> PackedByteArray:
	## An `image` packet: `format` is `jpeg` or `png`, `image` the encoded file.
	return packet({"type": "image", "camera": camera, "time_s": time_s, "format": format}, image)


static func decode(payload: PackedByteArray) -> Dictionary:
	## The message in `payload` (`{"type": "drive", "speed_m_s", "steering_rad"}` or
	## `{"type": "instruments", "motor_rpm"}`), or `{"error": reason}`.
	if payload.size() < 2:
		return {"error": "truncated"}
	var header_length := (payload[0] << 8) | payload[1]
	if payload.size() < 2 + header_length:
		return {"error": "header longer than the payload"}
	var json := JSON.new()
	if json.parse(payload.slice(2, 2 + header_length).get_string_from_utf8()) != OK:
		return {"error": "invalid header"}
	if not json.data is Dictionary:
		return {"error": "invalid header"}
	var header: Dictionary = json.data
	if not header.has("type"):
		return {"error": "no type"}
	var type = header["type"]
	if not FIELDS.has(type):
		return {"error": "unknown message %s" % type}
	var message := {"type": type}
	for field in FIELDS[type]:
		if not (header.get(field) is float or header.get(field) is int):
			return {"error": "invalid field %s.%s" % [type, field]}
		message[field] = float(header[field])
	return message


static func to_ros(godot: Vector3) -> Array:
	## A Godot vector as ROS's [x, y, z].
	return [godot.z, godot.x, godot.y]
