extends SceneTree
## Compresses images into DDS textures with their mipmaps, with the engine's own encoders, so
## a pack's textures look in the simulator as their sources do:
##
##   godot --headless --script tools/compress_textures.gd -- KIND SOURCE OUT [KIND SOURCE OUT...]
##
## KIND is `colour` (BC1, or BC3 when SOURCE has an alpha channel) or `normal` (BC5: x and y).

const SOURCES := {"colour": Image.COMPRESS_SOURCE_SRGB, "normal": Image.COMPRESS_SOURCE_NORMAL}


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	var failed := arguments.size() % 3 != 0
	for index in range(0, arguments.size() - 2, 3):
		if not _compress(arguments[index], arguments[index + 1], arguments[index + 2]):
			printerr("compress_textures: cannot write %s" % arguments[index + 2])
			failed = true
	quit(1 if failed else 0)


func _compress(kind: String, source: String, out: String) -> bool:
	var image := Image.load_from_file(source)
	if image == null or not SOURCES.has(kind):
		return false
	if image.detect_alpha() == Image.ALPHA_NONE:
		image.convert(Image.FORMAT_RGB8)
	image.generate_mipmaps()
	if image.compress(Image.COMPRESS_S3TC, SOURCES[kind]) != OK:
		return false
	return image.save_dds(out) == OK
