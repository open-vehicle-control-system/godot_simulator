class_name StereoFrame
extends RefCounted
## What the stereo camera shows of one frame: its images by name (`left`, `right` and, with
## ground truth, `segmentation`) and its maps of 32-bit floats by name (`depth`, `disparity`),
## row by row from the top.

var size_px: Vector2i
var images: Dictionary[String, Image] = {}
var maps: Dictionary[String, PackedByteArray] = {}

var _parts_awaited := 0
var _deliver := Callable()


func _init(image_size_px: Vector2i) -> void:
	size_px = image_size_px


func deliver_after(parts: int, deliver: Callable) -> void:
	## Hands this frame to `deliver` once `part_arrived` was called `parts` times.
	_parts_awaited = parts
	_deliver = deliver


func part_arrived() -> void:
	## Counts one of the awaited parts as read into this frame.
	_parts_awaited -= 1
	if _parts_awaited == 0 and _deliver.is_valid():
		_deliver.call(self)
