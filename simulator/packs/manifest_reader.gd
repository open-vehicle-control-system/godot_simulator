class_name ManifestReader
extends RefCounted
## Reads typed fields from a pack's manifest by dotted path, remembering the first field that is
## missing or of the wrong type: read every field, then check `error`.

var error := ""
var pack_id: String:
	get:
		return _pack_id
var _pack_id: String
var _manifest: Dictionary
var _within: String


func _init(pack_id: String, manifest: Dictionary, within := "") -> void:
	## Reads `manifest`, which sits at the dotted path `within` of the pack's manifest.
	_pack_id = pack_id
	_manifest = manifest
	_within = within


func has(path: String) -> bool:
	## True when the manifest holds `path`.
	return _lookup(path) != null


func is_text(path: String) -> bool:
	## True when the manifest holds a string at `path`.
	return _lookup(path) is String


func number(path: String) -> float:
	## The number at `path`, or 0 after recording an error.
	var found: Variant = _lookup(path)
	if found is float or found is int:
		return float(found)
	_record(path, "a number")
	return 0.0


func positive(path: String, below := INF) -> float:
	## The number at `path`, recording an error unless it is above 0 and below `below`.
	var found := number(path)
	check(found > 0.0 and found < below, path)
	return found


func check(condition: bool, path: String) -> void:
	## Records that the value at `path` is out of range unless `condition` holds.
	if error == "" and not condition:
		error = "%s: %s is out of range" % [_pack_id, _within + path]


func text(path: String) -> String:
	## The string at `path`, or "" after recording an error.
	var found: Variant = _lookup(path)
	if found is String:
		return found
	_record(path, "a string")
	return ""


func one_of(path: String, choices: Array) -> String:
	## The string at `path`, recording an error unless it is one of `choices`.
	var found := text(path)
	if error == "" and not found in choices:
		error = "%s: %s is not one of %s" % [_pack_id, _within + path, ", ".join(choices)]
	return found


func file(path: String, directory: String, suffix := "") -> String:
	## The path of the pack's file that `path` names (with `suffix` added), recording an error
	## when the pack does not hold it.
	var named := text(path)
	var full_path := directory.path_join(named + suffix)
	if error == "" and not FileAccess.file_exists(full_path):
		error = (
			"%s: %s names %s, which is not in the pack" % [_pack_id, _within + path, named + suffix]
		)
	return full_path


func numbers(path: String, count: int) -> Array[float]:
	## The `count` numbers at `path`, or zeros after recording an error.
	var found: Variant = _lookup(path)
	var read: Array[float] = []
	if found is Array and found.size() == count and found.all(_is_number):
		read.assign(found)
		return read
	_record(path, "a list of %d numbers" % count)
	read.resize(count)
	read.fill(0.0)
	return read


func list(path: String) -> Array:
	## The list at `path`, or an empty one after recording an error.
	var found: Variant = _lookup(path)
	if found is Array:
		return found
	_record(path, "a list")
	return []


func readers(path: String) -> Array[ManifestReader]:
	## A reader for each object of the list at `path`; they share nothing with this reader, so
	## check each one's `error`.
	var found: Variant = _lookup(path)
	var each: Array[ManifestReader] = []
	if not (found is Array and found.all(func(entry): return entry is Dictionary)):
		_record(path, "a list of objects")
		return each
	for index in found.size():
		each.append(
			ManifestReader.new(_pack_id, found[index], "%s%s[%d]." % [_within, path, index])
		)
	return each


func ros_vector(path: String) -> Vector3:
	## The ROS [x forward, y left, z up] vector at `path` in Godot's frame (+X left, +Y up,
	## +Z forward), or zero after recording an error. Sizes map the same way.
	var found: Variant = _lookup(path)
	if found is Array and found.size() == 3 and found.all(_is_number):
		return Vector3(found[1], found[2], found[0])
	_record(path, "a vector of three numbers")
	return Vector3.ZERO


func _lookup(path: String) -> Variant:
	var node: Variant = _manifest
	for key in path.split("."):
		if node is Array and key.is_valid_int() and int(key) >= 0 and int(key) < node.size():
			node = node[int(key)]
		elif node is Dictionary and node.has(key):
			node = node[key]
		else:
			return null
	return node


func _is_number(candidate: Variant) -> bool:
	return candidate is float or candidate is int


func _record(path: String, expected: String) -> void:
	if error == "":
		error = "%s: %s is missing or not %s" % [_pack_id, _within + path, expected]
