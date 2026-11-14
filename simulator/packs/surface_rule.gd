class_name SurfaceRule
extends RefCounted
## One entry of a track pack's `surfaces`: the meshes and glTF materials of the world it
## covers, by name, and the simulator surface that draws them with the pack's textures.

const KINDS := ["terrain", "roof", "facade", "plain", "seats"]
const WINDOWS := ["house", "hall", "office"]
## The three maps of a texture set, after its path in the pack.
const TEXTURE_SUFFIXES := ["_albedo.jpg", "_normal.jpg", "_rough.jpg"]

var kind: String
var meshes := "*"  ## a glob over mesh names
var materials := "*"  ## a glob over glTF material names
## terrain: the surface map and the track map, `*` standing for what the `*` of `materials` is
var map_pattern := ""
var track_map_pattern := ""  ## "" when the terrain has no road
var roads_map_pattern := ""  ## "" when the terrain has no roads around the lap
var lots_map_pattern := ""  ## "" when the terrain has no parking lots
var textures_path := ""  ## roof, facade, plain, seats: the texture set, without its suffixes
var size_m := 1.0  ## roof, facade, plain: the width the texture set covers
var windows := 0  ## facade: the index in WINDOWS
var tint := Color.WHITE  ## facade, plain, seats


static func parse(reader: ManifestReader, directory: String) -> SurfaceRule:
	## The rule `reader` holds; `reader.error` tells what is wrong with it.
	var rule := SurfaceRule.new()
	rule.kind = reader.one_of("surface", KINDS)
	if reader.has("meshes"):
		rule.meshes = reader.text("meshes")
	if reader.has("materials"):
		rule.materials = reader.text("materials")
	match rule.kind:
		"terrain":
			rule.map_pattern = directory.path_join(reader.text("map"))
			if reader.has("track_map"):
				rule.track_map_pattern = directory.path_join(reader.text("track_map"))
			if reader.has("roads_map"):
				rule.roads_map_pattern = directory.path_join(reader.text("roads_map"))
			if reader.has("lots_map"):
				rule.lots_map_pattern = directory.path_join(reader.text("lots_map"))
		"facade":
			rule._read_textures(reader, directory)
			rule.size_m = reader.positive("size_m")
			rule.windows = WINDOWS.find(reader.one_of("windows", WINDOWS))
			rule._read_tint(reader)
		"plain":
			rule._read_textures(reader, directory)
			rule.size_m = reader.positive("size_m")
			rule._read_tint(reader)
		"roof":
			rule._read_textures(reader, directory)
			rule.size_m = reader.positive("size_m")
		"seats":
			rule._read_textures(reader, directory)
			rule._read_tint(reader)
	return rule


func covers(mesh_name: String, material_name: String) -> bool:
	## True when this rule draws `material_name` on `mesh_name`.
	return mesh_name.match(meshes) and material_name.match(materials)


func map_path(material_name: String) -> String:
	## The surface map of the tile `material_name` shows.
	return map_pattern.replace("*", captured(material_name))


func track_map_path(material_name: String) -> String:
	## The track map of the tile `material_name` shows; a tile away from the road has none.
	return track_map_pattern.replace("*", captured(material_name))


func roads_map_path(material_name: String) -> String:
	## The roads map of the tile `material_name` shows; a tile no road passes has none.
	return roads_map_pattern.replace("*", captured(material_name))


func lots_map_path(material_name: String) -> String:
	## The lots map of the tile `material_name` shows; a tile without a lot has none.
	return lots_map_pattern.replace("*", captured(material_name))


func captured(material_name: String) -> String:
	## What the `*` of `materials` stands for in `material_name`.
	var star := materials.find("*")
	if star < 0:
		return ""
	var after_star := materials.length() - star - 1
	return material_name.substr(star, material_name.length() - star - after_star)


func _read_textures(reader: ManifestReader, directory: String) -> void:
	for suffix in TEXTURE_SUFFIXES:
		reader.file("textures", directory, suffix)
	textures_path = directory.path_join(reader.text("textures"))


func _read_tint(reader: ManifestReader) -> void:
	var channels := reader.numbers("tint", 3)
	tint = Color(channels[0], channels[1], channels[2])
