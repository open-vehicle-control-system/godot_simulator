class_name RoadDecals
extends RefCounted
## A track's decals, tile by tile: tyre marks, stains, patches and covers projected down onto
## the ground, and on nothing else, fading out at the pack's draw distance.

const TEXTURE_SUFFIXES := ["_albedo.png", "_normal.png", "_orm.png"]
## The render layer the ground is on besides the first: the only one decals project onto, so
## they never mark the vehicle, a wall or a tree.
const GROUND_LAYER := 1 << 1
## How far down a decal projects, from a metre above its position to a metre below.
const DEPTH_M := 2.0
## Over what share of its draw distance a decal fades out.
const FADE_SHARE := 0.25
## Over what share of its depth's halves a decal fades, above and below the ground.
const VERTICAL_FADE := 0.5
## Faces steeper than this receive less of a decal: it does not smear down a bank or a kerb's side.
const NORMAL_FADE := 0.5

var _decals: DecalsSpec
var _textures: Dictionary[String, Array] = {}  # kind id -> its albedo, normal and ORM textures


func _init(decals: DecalsSpec) -> void:
	_decals = decals
	for kind in decals.kinds:
		var maps := []
		for suffix in TEXTURE_SUFFIXES:
			var image := Image.load_from_file(kind.textures_path + suffix)
			image.generate_mipmaps()
			maps.append(ImageTexture.create_from_image(image))
		_textures[kind.id] = maps


func tile_decals(placed: Dictionary, file_name: String) -> Dictionary:
	## `{"decals": Array[Dictionary]}` from the `decals` a tile lists, each its `kind`,
	## `transform`, `size` and `opacity`; or `{"error": reason}`. Makes no node, so it runs on
	## any thread.
	var reader := ManifestReader.new(file_name, placed)
	var read: Array[Dictionary] = []
	for decal in reader.readers("decals"):
		var size := decal.numbers("size_m", 2)
		var laid := {
			"kind": decal.one_of("kind", _decals.ids()),
			"transform":
			Transform3D(
				Basis(Vector3.UP, deg_to_rad(decal.number("yaw_deg"))),
				decal.ros_vector("position_m")
			),
			"size": Vector3(size[1], DEPTH_M, size[0]),
			"opacity": decal.number("opacity"),
		}
		decal.check(size[0] > 0.0 and size[1] > 0.0, "size_m")
		decal.check(laid["opacity"] >= 0.0 and laid["opacity"] <= 1.0, "opacity")
		if reader.error == "":
			reader.error = decal.error
		read.append(laid)
	if reader.error != "":
		return {"error": reader.error}
	return {"decals": read}


func lay(read: Array[Dictionary]) -> Node3D:
	## The decals `tile_decals` read, under one node. On the main thread.
	var laid := Node3D.new()
	laid.name = "Decals"
	for placed in read:
		var maps: Array = _textures[placed["kind"]]
		var decal := Decal.new()
		decal.transform = placed["transform"]
		decal.size = placed["size"]
		decal.texture_albedo = maps[0]
		decal.texture_normal = maps[1]
		decal.texture_orm = maps[2]
		decal.modulate = Color(1.0, 1.0, 1.0, placed["opacity"])
		decal.cull_mask = GROUND_LAYER
		decal.upper_fade = VERTICAL_FADE
		decal.lower_fade = VERTICAL_FADE
		decal.normal_fade = NORMAL_FADE
		decal.distance_fade_enabled = true
		decal.distance_fade_length = _decals.draw_distance_m * FADE_SHARE
		decal.distance_fade_begin = _decals.draw_distance_m - decal.distance_fade_length
		laid.add_child(decal)
	return laid
