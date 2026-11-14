class_name SkySun
extends RefCounted
## Finds the sun in an equirectangular panorama. Pure.

const SEARCH_WIDTH_PX := 256
const SEARCH_HEIGHT_PX := 128


static func direction(panorama: Image) -> Vector3:
	## The unit vector towards the panorama's brightest spot, as a sky shows it unrotated.
	var small := panorama.duplicate() as Image
	small.convert(Image.FORMAT_RGBF)
	small.resize(SEARCH_WIDTH_PX, SEARCH_HEIGHT_PX, Image.INTERPOLATE_BILINEAR)
	var brightest := Vector2i.ZERO
	var most := -1.0
	for row in SEARCH_HEIGHT_PX:
		for column in SEARCH_WIDTH_PX:
			var luminance := small.get_pixel(column, row).get_luminance()
			if luminance > most:
				most = luminance
				brightest = Vector2i(column, row)
	return pixel_direction(
		(brightest.x + 0.5) / SEARCH_WIDTH_PX, (brightest.y + 0.5) / SEARCH_HEIGHT_PX
	)


static func pixel_direction(across: float, down: float) -> Vector3:
	## The direction a sky shows the panorama's point (`across`, `down`) in, each in [0, 1].
	var around := (across - 0.5) * TAU
	var from_zenith := down * PI
	return Vector3(
		sin(from_zenith) * sin(around), cos(from_zenith), -sin(from_zenith) * cos(around)
	)


static func yaw_between(from: Vector3, to: Vector3) -> float:
	## The angle about +Y that turns the heading of `from` onto the heading of `to`.
	return atan2(to.x, to.z) - atan2(from.x, from.z)
