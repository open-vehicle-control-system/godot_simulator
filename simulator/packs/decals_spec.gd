class_name DecalsSpec
extends RefCounted
## A track pack's `decals`: the kinds its tiles lay on the ground, and how far they show.


class Kind:
	extends RefCounted
	var id: String
	var textures_path: String  ## its maps' path without their suffixes


var kinds: Array[Kind] = []
var draw_distance_m: float


static func parse(reader: ManifestReader, directory: String) -> DecalsSpec:
	## The decals at `decals` in `reader`; `reader.error` tells what is wrong with them.
	var decals := DecalsSpec.new()
	var kind_readers := reader.readers("decals.kinds")
	reader.check(not kind_readers.is_empty(), "decals.kinds")
	for kind_reader in kind_readers:
		var kind := Kind.new()
		kind.id = kind_reader.text("id")
		for suffix in RoadDecals.TEXTURE_SUFFIXES:
			kind.textures_path = kind_reader.file("textures", directory, suffix).trim_suffix(suffix)
		if reader.error == "":
			reader.error = kind_reader.error
		decals.kinds.append(kind)
	decals.draw_distance_m = reader.positive("decals.draw_distance_m")
	return decals


func ids() -> Array[String]:
	## The id of every kind.
	var found: Array[String] = []
	for kind in kinds:
		found.append(kind.id)
	return found
