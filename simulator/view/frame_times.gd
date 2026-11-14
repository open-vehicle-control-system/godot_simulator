class_name FrameTimes
extends Node
## Reports how long the simulator took to show its first frame and, every few seconds, how
## long the frames after it take while the track's tiles stream in: the worst one and how many
## ran over budget, what a physics step took (the vehicle's queries of the world, the tiles'
## collision), what the GPU spent rendering every viewport (the window, the stereo pair, the
## mirrors), where the vehicle was when it spent the most, and what was drawn.

const REPORT_INTERVAL_S := 5.0
const BUDGET_MS := 33.0

var _tiles: TrackTiles
var _vehicle: Node3D
var _viewports: Array[RID] = []
var _first_frame_drawn := false
var _last_frame_usec := 0
var _frames := 0
var _worst_ms := 0.0
var _over_budget := 0
var _since_report_s := 0.0
var _physics_ms := 0.0
var _worst_physics_ms := 0.0
var _gpu_ms := 0.0
var _worst_gpu_ms := 0.0
var _worst_gpu_at := Vector3.ZERO
var _draw_calls := 0
var _objects := 0
var _primitives := 0


func setup(tiles: TrackTiles, vehicle: Node3D) -> void:
	## Reports the frames of the simulator showing `tiles` around `vehicle`.
	_tiles = tiles
	_vehicle = vehicle
	name = "FrameTimes"
	_report_first_frame.call_deferred()


func _process(delta: float) -> void:
	if not _first_frame_drawn:
		return
	var now_usec := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var frame_ms := (now_usec - _last_frame_usec) / 1000.0
		_frames += 1
		_worst_ms = maxf(_worst_ms, frame_ms)
		if frame_ms > BUDGET_MS:
			_over_budget += 1
	_last_frame_usec = now_usec
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_physics_ms += physics_ms
	_worst_physics_ms = maxf(_worst_physics_ms, physics_ms)
	_measure_rendering()
	_since_report_s += delta
	if _since_report_s < REPORT_INTERVAL_S:
		return
	print(
		(
			"timing: %d frames, worst %.1f ms, %d over %d ms; %d tiles loaded, %d colliding%s"
			% [
				_frames,
				_worst_ms,
				_over_budget,
				BUDGET_MS,
				_tiles.loaded_keys().size(),
				_tiles.colliding_keys().size(),
				"" if _tiles.is_settled() else ", more loading",
			]
		)
	)
	var at := _worst_gpu_at
	var frames := maxi(_frames, 1)
	print(
		"timing: physics %.3f ms a step, worst %.3f ms" % [_physics_ms / frames, _worst_physics_ms]
	)
	print(
		(
			"timing: GPU %.1f ms a frame, worst %.1f ms at %.0f,%.0f,%.0f; "
			% [_gpu_ms / frames, _worst_gpu_ms, at.z, at.x, at.y]
		),
		(
			"%d draw calls, %d objects, %d thousand primitives a frame"
			% [_draw_calls / frames, _objects / frames, _primitives / frames / 1000]
		)
	)
	_since_report_s = 0.0
	_frames = 0
	_worst_ms = 0.0
	_over_budget = 0
	_physics_ms = 0.0
	_worst_physics_ms = 0.0
	_gpu_ms = 0.0
	_worst_gpu_ms = 0.0
	_draw_calls = 0
	_objects = 0
	_primitives = 0


func _measure_rendering() -> void:
	var frame_gpu_ms := 0.0
	for viewport in _viewports:
		frame_gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	_gpu_ms += frame_gpu_ms
	if frame_gpu_ms > _worst_gpu_ms:
		_worst_gpu_ms = frame_gpu_ms
		_worst_gpu_at = _vehicle.global_position
	_draw_calls += RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	)
	_objects += RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME
	)
	_primitives += RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	)


func _report_first_frame() -> void:
	await RenderingServer.frame_post_draw
	_first_frame_drawn = true
	_viewports.append(get_viewport().get_viewport_rid())
	for viewport: SubViewport in get_tree().root.find_children("*", "SubViewport", true, false):
		_viewports.append(viewport.get_viewport_rid())
	for viewport in _viewports:
		RenderingServer.viewport_set_measure_render_time(viewport, true)
	print(
		(
			"timing: first frame drawn %d ms after the engine started, at %.3f s Unix time"
			% [Time.get_ticks_msec(), Time.get_unix_time_from_system()]
		)
	)
