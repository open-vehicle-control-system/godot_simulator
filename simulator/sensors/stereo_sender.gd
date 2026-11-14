class_name StereoSender
extends Node
## Sends stereo pairs over the link at the camera rate, JPEG-encoded off the main thread. A
## pair due while the previous one is still encoding is skipped.

const JPEG_QUALITY := 0.85
const NO_TASK := -1

var _link: SimulatorLink
var _capture: Callable
var _period_s: float
var _next_capture_s := 0.0
var _drawn_time_s := 0.0
var _encoding_task := NO_TASK


func setup(link: SimulatorLink, capture: Callable, rate_hz: float) -> void:
	## Sends what `capture` returns (`[left, right]` images) over `link` `rate_hz` times a second.
	_link = link
	_capture = capture
	_period_s = 1.0 / rate_hz
	_drawn_time_s = link.time_s
	name = "StereoSender"


func _physics_process(_delta: float) -> void:
	if _link == null or not _link.connected or _link.time_s < _next_capture_s:
		return
	if _encoding_task != NO_TASK:
		if not WorkerThreadPool.is_task_completed(_encoding_task):
			return
		WorkerThreadPool.wait_for_task_completion(_encoding_task)
		_encoding_task = NO_TASK
	_next_capture_s += _period_s
	if _next_capture_s <= _link.time_s:
		_next_capture_s = _link.time_s + _period_s  # behind: resume the rate, never burst
	var pair: Array[Image] = _capture.call()
	if pair.any(func(image): return image == null or image.is_empty()):
		return  # nothing rendered yet
	var time_s := _drawn_time_s
	_encoding_task = WorkerThreadPool.add_task(_encode.bind(pair, time_s))


func _process(_delta: float) -> void:
	# Physics steps before drawing: a capture returns the frame drawn at this time.
	if _link != null:
		_drawn_time_s = _link.time_s


func _encode(pair: Array[Image], time_s: float) -> void:
	var left := pair[0].save_jpg_to_buffer(JPEG_QUALITY)
	var right := pair[1].save_jpg_to_buffer(JPEG_QUALITY)
	_send.call_deferred(time_s, left, right)


func _send(time_s: float, left: PackedByteArray, right: PackedByteArray) -> void:
	_link.send_image("left", time_s, "jpeg", left)
	_link.send_image("right", time_s, "jpeg", right)


func _exit_tree() -> void:
	if _encoding_task != NO_TASK:
		WorkerThreadPool.wait_for_task_completion(_encoding_task)
