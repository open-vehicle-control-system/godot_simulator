extends SceneTree
## Runs every tests/test_*.gd headless and quits with 1 if a test failed:
## `godot --headless --path simulator -s tests/run_tests.gd [-- NAME_FILTER]`.

const TESTS_DIR := "res://tests"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var name_filter := ""
	if not OS.get_cmdline_user_args().is_empty():
		name_filter = OS.get_cmdline_user_args()[0]
	var failures: Array[String] = []
	var test_count := 0
	for script_path in _test_scripts():
		var script: GDScript = load(script_path)
		if script == null or not script.can_instantiate():
			failures.append("%s: does not load" % script_path.get_file())
			continue
		var test_case: TestCase = script.new()
		root.add_child(test_case)
		for method in test_case.get_method_list():
			var test_name: String = method["name"]
			if not test_name.begins_with("test_"):
				continue
			if name_filter != "" and not test_name.contains(name_filter):
				continue
			test_count += 1
			test_case.current_test = "%s:%s" % [script_path.get_file(), test_name]
			await test_case.call(test_name)
			# What the test added or queued to free is gone before the next one starts: no
			# body of one test stands in the next one's way.
			for child in test_case.get_children():
				child.queue_free()
			await process_frame
		failures.append_array(test_case.failures)
		test_case.queue_free()
		await process_frame
	for failure in failures:
		printerr("FAIL ", failure)
	print("%d tests, %d failures" % [test_count, failures.size()])
	quit(1 if not failures.is_empty() or test_count == 0 else 0)


func _test_scripts() -> PackedStringArray:
	var scripts := PackedStringArray()
	for file in DirAccess.get_files_at(TESTS_DIR):
		if file.begins_with("test_") and file.ends_with(".gd") and file != "test_case.gd":
			scripts.append(TESTS_DIR.path_join(file))
	scripts.sort()
	return scripts
