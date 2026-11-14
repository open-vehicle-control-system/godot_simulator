class_name GpuReadback
extends RefCounted
## Reads textures back from the GPU a few frames after asking, and counts those not back yet:
## the rendering device must not be torn down while it still owes one.

## Frames drawn at most while waiting for what the device owes.
const FRAMES_TO_FLUSH := 8

static var _awaited := 0


static func read(texture: RID, deliver: Callable) -> void:
	## Hands the bytes of `texture`, as drawn last, to `deliver` within a few frames.
	_awaited += 1
	RenderingServer.get_rendering_device().texture_get_data_async(
		texture, 0, _on_read.bind(deliver)
	)


static func finish_all() -> void:
	## Draws frames until every texture asked for is back.
	for frame in FRAMES_TO_FLUSH:
		if _awaited == 0:
			return
		RenderingServer.force_draw(false)


static func _on_read(bytes: PackedByteArray, deliver: Callable) -> void:
	_awaited -= 1
	if deliver.is_valid():
		deliver.call(bytes)
