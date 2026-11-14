class_name TreesSpec
extends RefCounted
## A track pack's `trees`: the impostors that draw the trees its tiles list.

const KINDS := ["conifer", "broadleaf"]


class Impostor:
	extends RefCounted
	var atlas_path: String  ## the tree seen from `views` directions, side by side
	var views: int
	var width_m: float  ## of one view
	var height_m: float
	var kind: String  ## one of KINDS


var impostors: Array[Impostor] = []
var canopy_scene_path := ""  ## the woods as one coarse surface, or "" without one
## How far a tree is drawn before the canopy stands for it; 0 without a canopy: any distance.
var draw_distance_m := 0.0


static func parse(reader: ManifestReader, directory: String) -> TreesSpec:
	## The trees at `trees` in `reader`; `reader.error` tells what is wrong with them.
	var trees := TreesSpec.new()
	var impostor_readers := reader.readers("trees.impostors")
	reader.check(not impostor_readers.is_empty(), "trees.impostors")
	for impostor_reader in impostor_readers:
		var impostor := Impostor.new()
		impostor.atlas_path = impostor_reader.file("atlas", directory)
		impostor.views = int(impostor_reader.positive("views"))
		impostor.width_m = impostor_reader.positive("width_m")
		impostor.height_m = impostor_reader.positive("height_m")
		impostor.kind = impostor_reader.one_of("kind", KINDS)
		if reader.error == "":
			reader.error = impostor_reader.error
		trees.impostors.append(impostor)
	if reader.has("trees.canopy"):
		trees.canopy_scene_path = reader.file("trees.canopy.scene", directory)
		trees.draw_distance_m = reader.positive("trees.canopy.from_m")
	return trees
