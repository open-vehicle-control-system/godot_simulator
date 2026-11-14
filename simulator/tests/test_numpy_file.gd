extends TestCase
## Float images written as NumPy `.npy` files.


func test_writes_the_header_numpy_reads_then_the_floats() -> void:
	var floats := PackedFloat32Array([1.5, 2.5, 3.5, 4.5, 5.5, 6.5]).to_byte_array()

	var file := NumpyFile.float32_image(3, 2, floats)

	assert_eq(file.slice(0, 8), PackedByteArray([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0]))
	var header_length := file.decode_u16(8)
	assert_eq((10 + header_length) % 64, 0, "the floats start on 64 bytes")
	var header := file.slice(10, 10 + header_length).get_string_from_ascii()
	assert_true(
		header.begins_with("{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }"), header
	)
	assert_true(header.ends_with("\n"), "the header ends its line")
	assert_eq(file.slice(10 + header_length), floats)
