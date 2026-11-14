extends TestCase
## The OVCS simulator link's packets, against bytes OVCS's SimulatorCore.Link.Protocol encodes.

# SimulatorCore.Link.Protocol.encode(%Drive{speed_m_s: 2.5, steering_rad: -0.125})
const OVCS_DRIVE_PAYLOAD_HEX := (
	"00367B2274797065223A226472697665222C2273706565645F6D5F73223A322E352C"
	+ "227374656572696E675F726164223A2D302E3132357D"
)


func test_decodes_a_drive_ovcs_encoded() -> void:
	var payload := OVCS_DRIVE_PAYLOAD_HEX.hex_decode()

	var message := LinkProtocol.decode(payload)

	assert_eq(message, {"type": "drive", "speed_m_s": 2.5, "steering_rad": -0.125})


func test_rejects_malformed_payloads_naming_why() -> void:
	var cases := {
		"truncated": PackedByteArray([0]),
		"header longer than the payload": PackedByteArray([0, 9, 123]),
		"invalid header": _payload("not json"),
		"no type": _payload('{"speed_m_s":1}'),
		"unknown message vehicle": _payload('{"type":"vehicle"}'),
		"invalid field drive.speed_m_s": _payload('{"type":"drive","steering_rad":0}'),
		"invalid field drive.steering_rad":
		_payload('{"type":"drive","speed_m_s":1,"steering_rad":"x"}'),
	}
	for reason in cases:
		assert_eq(LinkProtocol.decode(cases[reason]), {"error": reason}, reason)


func test_frames_a_payload_with_its_32_bit_length_then_header_length() -> void:
	var packet := LinkProtocol.packet({"type": "drive", "speed_m_s": 2.5}, PackedByteArray([7, 8]))

	var header_json := '{"type":"drive","speed_m_s":2.5}'
	assert_eq(_u32_big_endian(packet, 0), 2 + header_json.length() + 2)
	assert_eq((packet[4] << 8) | packet[5], header_json.length())
	assert_eq(packet.slice(6, 6 + header_json.length()).get_string_from_utf8(), header_json)
	assert_eq(packet.slice(6 + header_json.length()), PackedByteArray([7, 8]))


func test_encodes_the_state_in_ros_frames() -> void:
	# Godot: +X left, +Y up, +Z forward. The vehicle faces world +X (Godot), turned 90° left.
	var pose := Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3(1.0, 2.0, 3.0))
	var state := {
		"time_s": 1.5,
		"odometer_m": 12.25,
		"pose": pose,
		"linear_velocity_m_s": Vector3(0.0, 0.0, 4.0),
		"angular_velocity_rad_s": Vector3(0.0, 0.5, 0.0),
		"linear_acceleration_m_s2": Vector3(0.25, 9.75, 1.0),
	}

	var header := _header(LinkProtocol.encode_state(state))

	assert_eq(header["type"], "state")
	assert_eq(header["time_s"], 1.5)
	assert_eq(header["odometer_m"], 12.25)
	assert_eq(header["position_m"], [3.0, 1.0, 2.0])
	assert_eq(header["linear_velocity_m_s"], [4.0, 0.0, 0.0])
	assert_eq(header["angular_velocity_rad_s"], [0.0, 0.0, 0.5])
	assert_eq(header["linear_acceleration_m_s2"], [1.0, 0.25, 9.75])
	# Godot's 90° about +Y is ROS's 90° about +z: (0, 0, sin 45°, cos 45°).
	var orientation: Array = header["orientation"]
	assert_almost_eq(
		Vector4(orientation[0], orientation[1], orientation[2], orientation[3]),
		Vector4(0.0, 0.0, sqrt(0.5), sqrt(0.5)),
		1e-9
	)


func test_encodes_an_image_with_its_body() -> void:
	var jpeg := PackedByteArray([0xFF, 0xD8, 0xFF])

	var packet := LinkProtocol.encode_image("left", 2.0, "jpeg", jpeg)

	assert_eq(_header(packet), {"type": "image", "camera": "left", "time_s": 2.0, "format": "jpeg"})
	assert_eq(packet.slice(packet.size() - 3), jpeg)


func test_framer_yields_payloads_split_across_reads_and_several_in_one() -> void:
	var first := LinkProtocol.packet({"type": "drive", "speed_m_s": 1, "steering_rad": 0})
	var second := LinkProtocol.packet({"type": "drive", "speed_m_s": 2, "steering_rad": 0})
	var stream := first + second
	var framer := LinkProtocol.Framer.new()

	var at_split := framer.push(stream.slice(0, 5))
	var rest := framer.push(stream.slice(5))

	assert_eq(at_split.size(), 0)
	assert_eq(rest.size(), 2)
	assert_eq(LinkProtocol.decode(rest[0])["speed_m_s"], 1.0)
	assert_eq(LinkProtocol.decode(rest[1])["speed_m_s"], 2.0)


func test_framer_refuses_a_length_beyond_the_links_limit() -> void:
	var framer := LinkProtocol.Framer.new()

	framer.push(PackedByteArray([0x01, 0x00, 0x00, 0x01]))

	assert_true(framer.broken, "a 16 MiB + 1 length is not a packet the link sends")


func _payload(header_json: String) -> PackedByteArray:
	var json := header_json.to_utf8_buffer()
	return PackedByteArray([json.size() >> 8, json.size() & 0xFF]) + json


func _u32_big_endian(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24)
		| (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8)
		| bytes[offset + 3]
	)


func _header(packet: PackedByteArray) -> Dictionary:
	var header_length := (packet[4] << 8) | packet[5]
	return JSON.parse_string(packet.slice(6, 6 + header_length).get_string_from_utf8())
