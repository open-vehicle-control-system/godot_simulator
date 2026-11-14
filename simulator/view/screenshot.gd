class_name Screenshot
extends Node
## Saves the window as a PNG once the world has rendered for a while, reports what a frame
## costs to render (the window, and the other viewports: stereo cameras, mirrors), then quits.

const SETTLE_FRAMES := 180
const MEASURED_FRAMES := 60

var _path := ""
var _frames := 0
var _cpu_ms := 0.0
var _gpu_ms := 0.0
var _other_viewports: Array[RID] = []
var _other_gpu_ms := 0.0


func setup(path: String) -> void:
	## Saves the window to `path`.
	_path = path
	name = "Screenshot"
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == SETTLE_FRAMES - MEASURED_FRAMES:
		_measure_other_viewports()
	if _frames > SETTLE_FRAMES - MEASURED_FRAMES:
		for other in _other_viewports:
			_other_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(other)
		var viewport := get_viewport().get_viewport_rid()
		_cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(viewport)
		_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	if _frames < SETTLE_FRAMES:
		return
	set_process(false)
	await RenderingServer.frame_post_draw
	var problem := get_viewport().get_texture().get_image().save_png(_path)
	if problem != OK:
		printerr("screenshot: %s cannot be written" % _path)
	print(
		(
			"screenshot: %s, window rendered in %.2f ms on the GPU and %.2f ms on the CPU per frame"
			% [_path, _gpu_ms / MEASURED_FRAMES, _cpu_ms / MEASURED_FRAMES]
		)
	)
	print(
		(
			"screenshot: its %d other viewports rendered in %.2f ms on the GPU per frame"
			% [_other_viewports.size(), _other_gpu_ms / MEASURED_FRAMES]
		)
	)
	get_tree().quit()


func _measure_other_viewports() -> void:
	for viewport: SubViewport in get_tree().root.find_children("*", "SubViewport", true, false):
		_other_viewports.append(viewport.get_viewport_rid())
		RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(), true)
