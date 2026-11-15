class_name LinkTestServer
extends RefCounted
## OVCS's side of the simulator link, for tests: accepts the simulator, sends actuations and
## instruments, and collects the headers and bodies the simulator sends.

var port: int
var headers: Array[Dictionary] = []
var bodies: Array[PackedByteArray] = []
var _server := TCPServer.new()
var _peer: StreamPeerTCP
var _framer := LinkProtocol.Framer.new()


func _init() -> void:
	_server.listen(0, "127.0.0.1")
	port = _server.get_local_port()


func poll() -> void:
	## Accepts a waiting simulator and reads what it sent.
	if _server.is_connection_available():
		_peer = _server.take_connection()
		_framer = LinkProtocol.Framer.new()
	if _peer == null:
		return
	_peer.poll()
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	for payload in _framer.push(_peer.get_data(available)[1]):
		var header_length := (payload[0] << 8) | payload[1]
		headers.append(
			JSON.parse_string(payload.slice(2, 2 + header_length).get_string_from_utf8())
		)
		bodies.append(payload.slice(2 + header_length))


func connected() -> bool:
	## True while a simulator is connected.
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send_actuation(
	drive_torque_nm: float,
	brake_torque_nm: float,
	steering_rad: float,
	driveline_inertia_kg_m2 := 1.0,
	time_s := 0.0
) -> void:
	## Sends an actuation to the connected simulator.
	(
		_peer
		. put_data(
			(
				LinkProtocol
				. packet(
					{
						"type": "actuation",
						"time_s": time_s,
						"drive_torque_nm": drive_torque_nm,
						"brake_torque_nm": brake_torque_nm,
						"steering_rad": steering_rad,
						"driveline_inertia_kg_m2": driveline_inertia_kg_m2,
					}
				)
			)
		)
	)


func send_instruments(motor_rpm: float) -> void:
	## Sends the motor's rpm to the connected simulator.
	_peer.put_data(LinkProtocol.packet({"type": "instruments", "motor_rpm": motor_rpm}))


func drop_simulator() -> void:
	## Closes the connection to the simulator.
	_peer.disconnect_from_host()
	_peer = null


func of_type(type: String) -> Array[Dictionary]:
	## The headers received of this `type`.
	return headers.filter(func(header): return header["type"] == type)


func stop() -> void:
	## Closes the connection and stops listening.
	if _peer != null:
		_peer.disconnect_from_host()
	_server.stop()
