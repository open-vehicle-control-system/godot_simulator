class_name MirrorsSpec
extends RefCounted
## A vehicle pack's `mirrors`: the model's material that is mirror glass, and how wide each
## mirror sees behind.

## A pinhole camera sees less than half the world.
const MAX_FIELD_OF_VIEW_DEG := 180.0

var material: String  ## the glTF material's name
var interior_hfov_deg: float
var door_hfov_deg: float


static func parse(reader: ManifestReader) -> MirrorsSpec:
	## The mirrors at `mirrors` in `reader`; `reader.error` tells what is wrong with them.
	var mirrors := MirrorsSpec.new()
	mirrors.material = reader.text("mirrors.material")
	mirrors.interior_hfov_deg = reader.positive("mirrors.interior_hfov_deg", MAX_FIELD_OF_VIEW_DEG)
	mirrors.door_hfov_deg = reader.positive("mirrors.door_hfov_deg", MAX_FIELD_OF_VIEW_DEG)
	return mirrors
