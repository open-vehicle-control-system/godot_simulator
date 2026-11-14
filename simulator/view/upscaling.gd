class_name Upscaling
extends RefCounted
## Draws a viewport's 3D smaller and upscales it to its size with FSR 2, which costs the GPU
## less than drawing every pixel. For the window only: what a camera measures is drawn as it is.

## The share of the viewport's width and height that is drawn, by level.
const SCALES := {"quality": 0.67, "balanced": 0.59, "performance": 0.5}


static func apply(viewport: Viewport, level: String) -> void:
	## Upscales `viewport` from the size of `level`, a key of SCALES.
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	viewport.scaling_3d_scale = SCALES[level]
