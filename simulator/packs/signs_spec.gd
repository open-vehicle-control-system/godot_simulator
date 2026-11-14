class_name SignsSpec
extends RefCounted
## A track pack's `signs`: the faces of the road signs its tiles list, and the size and cycle
## of their traffic signals.

const MIN_OUTLINE_POINTS := 3


class Face:
	extends RefCounted
	var id: String
	var image_path: String  ## what the plate's front shows, across its outline's bounding box
	var outline := PackedVector2Array()  ## convex, metres about the plate's centre, y up


var faces: Array[Face] = []
var lens_diameter_m: float
var green_s: float
var amber_s: float
var red_s: float


static func parse(reader: ManifestReader, directory: String) -> SignsSpec:
	## The signs at `signs` in `reader`; `reader.error` tells what is wrong with them.
	var signs := SignsSpec.new()
	for face_reader in reader.readers("signs.faces"):
		var face := Face.new()
		face.id = face_reader.text("id")
		face.image_path = face_reader.file("image", directory)
		for point in face_reader.list("outline_m"):
			var is_point: bool = point is Array and point.size() == 2
			face_reader.check(is_point and point.all(_is_number), "outline_m")
			if face_reader.error == "":
				face.outline.append(Vector2(point[0], point[1]))
		face_reader.check(face.outline.size() >= MIN_OUTLINE_POINTS, "outline_m")
		if reader.error == "":
			reader.error = face_reader.error
		signs.faces.append(face)
	signs.lens_diameter_m = reader.positive("signs.signal.lens_diameter_m")
	var cycle := reader.numbers("signs.signal.cycle_s", 3)
	reader.check(cycle.min() > 0.0, "signs.signal.cycle_s")
	signs.green_s = cycle[0]
	signs.amber_s = cycle[1]
	signs.red_s = cycle[2]
	return signs


func face(id: String) -> Face:
	## The face named `id`, or null.
	for candidate in faces:
		if candidate.id == id:
			return candidate
	return null


static func _is_number(candidate: Variant) -> bool:
	return candidate is float or candidate is int
