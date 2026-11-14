extends TestCase
## Every shader of the simulator compiles: one that does not draws its surface white.


func test_every_shader_compiles() -> void:
	var paths := _shaders_under("res://")
	assert_true(paths.size() > 0, "no shader found")
	for path in paths:
		var shader := load(path) as Shader
		# A shader that fails to compile exposes no uniform.
		assert_true(shader.get_shader_uniform_list().size() > 0, "%s does not compile" % path)


func _shaders_under(directory: String) -> Array[String]:
	var found: Array[String] = []
	for name in DirAccess.get_files_at(directory):
		if name.ends_with(".gdshader"):
			found.append(directory.path_join(name))
	for name in DirAccess.get_directories_at(directory):
		if not name.begins_with("."):
			found.append_array(_shaders_under(directory.path_join(name)))
	return found
