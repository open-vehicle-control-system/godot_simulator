class_name FrameTimes
extends Node
## Reports how long the simulator took to show its first frame and, every few seconds, how
## long the frames after it take while the track's tiles stream in: the worst one and how many
## ran over budget.

const REPORT_INTERVAL_S := 5.0
const BUDGET_MS := 33.0

var _tiles: TrackTiles
var _first_frame_drawn := false
var _last_frame_usec := 0
var _frames := 0
var _worst_ms := 0.0
var _over_budget := 0
var _since_report_s := 0.0


func setup(tiles: TrackTiles) -> void:
	## Reports the frames of the simulator showing `tiles`.
	_tiles = tiles
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
	_since_report_s = 0.0
	_frames = 0
	_worst_ms = 0.0
	_over_budget = 0


func _report_first_frame() -> void:
	await RenderingServer.frame_post_draw
	_first_frame_drawn = true
	print(
		(
			"timing: first frame drawn %d ms after the engine started, at %.3f s Unix time"
			% [Time.get_ticks_msec(), Time.get_unix_time_from_system()]
		)
	)
