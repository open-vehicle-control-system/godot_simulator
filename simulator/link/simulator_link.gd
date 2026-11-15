class_name SimulatorLink
extends Node
## The TCP client of OVCS's simulator link (SimulatorCore.Link): applies the drives OVCS sends
## to the vehicle and sends the vehicle's state every physics step, and camera images when
## given them. It keeps the motor rpm OVCS last reported, for the rev counter.
##
## With no drive for DRIVE_TIMEOUT_S, or no connection, the vehicle is commanded to stop. With
## no instruments for INSTRUMENTS_TIMEOUT_S, or no connection, the motor rpm reads 0.

const RECONNECT_S := 1.0
const DRIVE_TIMEOUT_S := 0.5
const INSTRUMENTS_TIMEOUT_S := 0.5
## Unsent bytes beyond which images are dropped: states keep flowing to a slow reader.
const MAX_IMAGE_BACKLOG_BYTES := 2 * 1024 * 1024
## Unsent bytes beyond which OVCS has stopped reading: the connection is dropped.
const MAX_BACKLOG_BYTES := 32 * 1024 * 1024

var connected := false
var time_s := 0.0  ## since the simulation started: the clock states and images carry

var _vehicle: Vehicle
var _host: String
var _port: int
var _peer := StreamPeerTCP.new()
var _framer := LinkProtocol.Framer.new()
var _retry_in_s := 0.0
var _since_drive_s := INF
var _motor_rpm := 0.0
var _motor_rpm_received_s := -INF  ## on time_s's clock
var _outgoing := PackedByteArray()


func setup(vehicle: Vehicle, host: String, port: int) -> void:
	## Links `vehicle` to the OVCS link listening on `host:port`.
	_vehicle = vehicle
	_host = host
	_port = port
	name = "SimulatorLink"


func send_image(
	camera: String, image_time_s: float, format: String, image: PackedByteArray
) -> void:
	## Sends an encoded camera image taken at `image_time_s`, if connected and OVCS keeps up.
	if connected and _outgoing.size() <= MAX_IMAGE_BACKLOG_BYTES:
		_send(LinkProtocol.encode_image(camera, image_time_s, format, image))


func motor_rpm() -> float:
	## The motor rpm OVCS last reported, signed as its motor controller reports it; 0 when the
	## last report is older than INSTRUMENTS_TIMEOUT_S or there is none.
	if time_s - _motor_rpm_received_s > INSTRUMENTS_TIMEOUT_S:
		return 0.0
	return _motor_rpm


func _physics_process(delta: float) -> void:
	if _vehicle == null:
		return
	time_s += delta
	_since_drive_s += delta
	_keep_connected(delta)
	if connected:
		_read_messages()
	if _since_drive_s > DRIVE_TIMEOUT_S:
		_vehicle.stop()
	if connected:
		var state := _vehicle.motion_state()
		state["time_s"] = time_s
		state["odometer_m"] = _vehicle.odometer_m
		_send(LinkProtocol.encode_state(state))


func _keep_connected(delta: float) -> void:
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not connected:
			connected = true
			_framer = LinkProtocol.Framer.new()
			_outgoing.clear()
			print("link: connected to %s:%d" % [_host, _port])
		return
	if connected:
		_disconnect("lost the connection")
	if status == StreamPeerTCP.STATUS_CONNECTING:
		return
	_retry_in_s -= delta
	if _retry_in_s <= 0.0:
		_retry_in_s = RECONNECT_S
		_peer = StreamPeerTCP.new()
		_peer.connect_to_host(_host, _port)


func _read_messages() -> void:
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	var received := _peer.get_data(available)
	if received[0] != OK:
		return
	for payload in _framer.push(received[1]):
		var message := LinkProtocol.decode(payload)
		if message.has("error"):
			push_warning("link: dropped a packet: %s" % message["error"])
			continue
		if message["type"] == "drive":
			_since_drive_s = 0.0
			_vehicle.command(message["speed_m_s"], message["steering_rad"])
		else:
			_motor_rpm = message["motor_rpm"]
			_motor_rpm_received_s = time_s
	if _framer.broken:
		_disconnect("received a length no OVCS packet has")


func _send(packet: PackedByteArray) -> void:
	## Queues `packet` and writes what the socket takes now: never blocks the main thread.
	_outgoing.append_array(packet)
	if _outgoing.size() > MAX_BACKLOG_BYTES:
		_disconnect("OVCS stopped reading")
		return
	var written := _peer.put_partial_data(_outgoing)
	if written[0] != OK and written[0] != ERR_BUSY:
		_disconnect("could not send")
		return
	_outgoing = _outgoing.slice(written[1])


func _disconnect(reason: String) -> void:
	print("link: %s" % reason)
	connected = false
	_since_drive_s = INF
	_motor_rpm_received_s = -INF
	_outgoing.clear()
	_peer.disconnect_from_host()
	_vehicle.stop()
