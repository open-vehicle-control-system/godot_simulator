class_name ComputeShader
extends RefCounted
## Compiles the simulator's compute shaders: GLSL files whose `#include "file"` lines stand
## for the file of that name next to them.


static func compile(device: RenderingDevice, path: String) -> RID:
	## The shader of the GLSL compute source at `path`, on `device`.
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = with_includes(path)
	var compiled := device.shader_compile_spirv_from_source(source)
	assert(compiled.compile_error_compute == "", "%s: %s" % [path, compiled.compile_error_compute])
	return device.shader_create_from_spirv(compiled)


static func with_includes(path: String) -> String:
	## The source at `path`, each `#include "file"` line replaced by that file.
	var lines := PackedStringArray()
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("#include"):
			lines.append(with_includes(path.get_base_dir().path_join(line.get_slice('"', 1))))
		else:
			lines.append(line)
	return "\n".join(lines)
