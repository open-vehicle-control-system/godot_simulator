class_name SurfaceRule
extends RefCounted
## One entry of a track pack's `surfaces`: the meshes and glTF materials of the world it
## covers, by name, and the simulator surface that draws them with the pack's textures.

const KINDS := ["terrain", "roof", "facade", "plain", "seats"]
const WINDOWS := ["house", "hall", "office"]
## The three maps of a texture set, after its path in the pack.
const TEXTURE_SUFFIXES := ["_albedo.dds", "_normal.dds", "_rough.dds"]

var kind: String
var meshes := "*"  ## a glob over mesh names
var materials := "*"  ## a glob over glTF material names
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


func _read_textures(reader: ManifestReader, directory: String) -> void:
	for suffix in TEXTURE_SUFFIXES:
		reader.file("textures", directory, suffix)
	textures_path = directory.path_join(reader.text("textures"))


func _read_tint(reader: ManifestReader) -> void:
	var channels := reader.numbers("tint", 3)
	tint = Color(channels[0], channels[1], channels[2])
