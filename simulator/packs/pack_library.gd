class_name PackLibrary
extends RefCounted
## The packs found on a search path, by id. A pack is a directory holding a pack.json whose
## `format`, `kind` and `id` this library reads; the kind's loader reads the rest.

const FORMAT := 1
const KINDS := ["track", "vehicle"]
const ID_PATTERN := "^[a-z0-9_]+$"

## What made a pack unusable while scanning: unreadable manifests, ids found twice.
var errors: Array[String] = []
var _packs := {}  # id -> {"kind", "directory", "manifest"}


static func scan(directories: Array) -> PackLibrary:
	## Reads every pack directly under each of `directories`.
	var library := PackLibrary.new()
	var duplicated := {}
	for directory in directories:
		for child in DirAccess.get_directories_at(directory):
			library._add(directory.path_join(child), duplicated)
	for id in duplicated:
		library._packs.erase(id)
	return library


func ids(kind: String) -> Array[String]:
	## The ids of the packs of `kind`, sorted.
	var found: Array[String] = []
	for id in _packs:
		if _packs[id]["kind"] == kind:
			found.append(id)
	found.sort()
	return found


func load_vehicle(id: String) -> Dictionary:
	## `{"vehicle": VehicleSpec}`, or `{"error": reason}`.
	if not _has(id, "vehicle"):
		return {"error": "no vehicle pack %s" % id}
	return VehicleSpec.parse(_packs[id]["manifest"], _packs[id]["directory"])


func load_track(id: String) -> Dictionary:
	## `{"track": TrackSpec}`, or `{"error": reason}`.
	if not _has(id, "track"):
		return {"error": "no track pack %s" % id}
	return TrackSpec.parse(_packs[id]["manifest"], _packs[id]["directory"])


func _has(id: String, kind: String) -> bool:
	return _packs.has(id) and _packs[id]["kind"] == kind


func _add(directory: String, duplicated: Dictionary) -> void:
	var manifest_path := directory.path_join("pack.json")
	if not FileAccess.file_exists(manifest_path):
		return
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var problem := _manifest_problem(manifest)
	if problem != "":
		errors.append("%s: %s" % [directory, problem])
		return
	var id: String = manifest["id"]
	if _packs.has(id):
		errors.append("%s: found twice, in %s and %s" % [id, _packs[id]["directory"], directory])
		duplicated[id] = true
		return
	_packs[id] = {"kind": manifest["kind"], "directory": directory, "manifest": manifest}


static func _manifest_problem(manifest: Variant) -> String:
	if not manifest is Dictionary:
		return "pack.json is not a JSON object"
	if manifest.get("format") != float(FORMAT):
		return "pack.json format is not %d" % FORMAT
	if not manifest.get("kind") in KINDS:
		return "pack.json kind is not one of %s" % [KINDS]
	var id: Variant = manifest.get("id")
	if not (id is String and RegEx.create_from_string(ID_PATTERN).search(id)):
		return "pack.json id is not lower-case letters, digits and underscores"
	return ""
