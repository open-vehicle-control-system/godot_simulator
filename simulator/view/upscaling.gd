class_name Upscaling
extends Node
## Draws the window's 3D smaller and upscales it to its size with FSR 2, which costs the GPU
## less than drawing every pixel: at a level asked for (--upscale), and always on a window larger
## than MAX_DRAWN_PIXELS, so a full screen on a 4K or 5K display keeps its frame rate. Follows the
## window's size. For the window only: what a camera measures is drawn as it is.

## The share of the viewport's width and height that is drawn, by level.
const SCALES := {"quality": 0.67, "balanced": 0.59, "performance": 0.5}
## Every pixel drawn, however large the window.
const NATIVE := "native"
## The most pixels the window's 3D is drawn with: 2560 x 1440. A larger window is drawn at this
## and upscaled.
const MAX_DRAWN_PIXELS := 2560 * 1440

var _window: Window
var _level := ""


static func levels() -> Array:
	## The levels --upscale takes.
	return SCALES.keys() + [NATIVE]


static func scale_for(size_px: Vector2i, level: String) -> float:
	## The share of the width and height of a viewport of `size_px` drawn at `level` (a key of
	## SCALES, NATIVE, or "" for the cap alone).
	if level == NATIVE:
		return 1.0
	var scale: float = SCALES.get(level, 1.0)
	var pixels := float(size_px.x) * float(size_px.y)
	if pixels > MAX_DRAWN_PIXELS:
		scale = minf(scale, sqrt(MAX_DRAWN_PIXELS / pixels))
	return scale


static func apply(viewport: Viewport, size_px: Vector2i, level: String) -> void:
	## Draws `viewport`, `size_px` large, as `level` asks: upscaled with FSR 2 below every pixel.
	var scale := scale_for(size_px, level)
	if scale >= 1.0:
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = 1.0
	else:
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
		viewport.scaling_3d_scale = scale


func setup(window: Window, level: String) -> void:
	## Upscales `window` at `level` from now on, as its size changes.
	_window = window
	_level = level
	name = "Upscaling"
	_window.size_changed.connect(_fit)
	_fit()


func _exit_tree() -> void:
	if _window != null and _window.size_changed.is_connected(_fit):
		_window.size_changed.disconnect(_fit)


func _fit() -> void:
	apply(_window, _window.size, _level)
