extends "res://tests/run_tests.gd"
## Runs every tests/rendered/test_*.gd, which need a display and a GPU to render with:
## `godot --path simulator -s tests/rendered/run_rendered_tests.gd [-- NAME_FILTER]`.

const RENDERED_TESTS_DIR := "res://tests/rendered"


func _test_scripts() -> PackedStringArray:
	var scripts := PackedStringArray()
	for file in DirAccess.get_files_at(RENDERED_TESTS_DIR):
		if file.begins_with("test_") and file.ends_with(".gd"):
			scripts.append(RENDERED_TESTS_DIR.path_join(file))
	scripts.sort()
	return scripts
