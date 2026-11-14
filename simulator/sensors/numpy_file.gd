class_name NumpyFile
extends RefCounted
## Writes an image of 32-bit floats as a NumPy `.npy` file (format 1.0): `numpy.load` reads
## it as a float32 array of shape (height, width).

const MAGIC := [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0]
const HEADER_ALIGNMENT := 64
const HEADER_LENGTH_BYTES := 2
const FLOAT_BYTES := 4


static func float32_image(
	width_px: int, height_px: int, floats: PackedByteArray
) -> PackedByteArray:
	## The `.npy` file of `floats`: little-endian 32-bit floats, row by row from the top.
	assert(floats.size() == width_px * height_px * FLOAT_BYTES)
	var described := (
		"{'descr': '<f4', 'fortran_order': False, 'shape': (%d, %d), }" % [height_px, width_px]
	)
	var before_header := MAGIC.size() + HEADER_LENGTH_BYTES
	# The header ends with a line feed, padded so the floats start on the alignment.
	var header_length := (
		ceili(float(before_header + described.length() + 1) / HEADER_ALIGNMENT) * HEADER_ALIGNMENT
		- before_header
	)
	var file := PackedByteArray(MAGIC)
	file.resize(before_header)
	file.encode_u16(MAGIC.size(), header_length)
	file.append_array((described.rpad(header_length - 1) + "\n").to_ascii_buffer())
	file.append_array(floats)
	return file
