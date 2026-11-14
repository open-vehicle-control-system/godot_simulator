class_name FarTerrain
extends Node3D
## The whole of a track's ground, coarse: a mesh per tile under one photo, shown where the
## tile itself is not loaded, so the horizon is never empty.

const SHADER := preload("res://world/shaders/far.gdshader")
const MESH_PREFIX := "Far_"

var photo: ImageTexture  ## the whole area from above

var _pieces: Dictionary[String, MeshInstance3D] = {}


static func build(track: TrackSpec) -> Dictionary:
	## `{"far": FarTerrain}` from the pack's far scene and photo, or `{"error": reason}`.
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(track.far_scene_path, state) != OK:
		return {"error": "%s: %s does not load" % [track.id, track.far_scene_path.get_file()]}
	var photo := Image.load_from_file(track.far_photo_path)
	if photo == null:
		return {"error": "%s: %s does not load" % [track.id, track.far_photo_path.get_file()]}
	photo.generate_mipmaps()
	var far := FarTerrain.new()
	far.name = "FarTerrain"
	far.photo = ImageTexture.create_from_image(photo)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("photo", far.photo)
	if track.ground != null:
		material.set_shader_parameter("photo_black", track.ground.photo_black)
		material.set_shader_parameter("photo_gain", track.ground.photo_gain)
		material.set_shader_parameter("photo_gamma", track.ground.photo_gamma)
		material.set_shader_parameter("photo_saturation", track.ground.photo_saturation)
	var scene := document.generate_scene(state)
	for node in scene.find_children(MESH_PREFIX + "*", "MeshInstance3D", true, false):
		var piece := node as MeshInstance3D
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		far._pieces[String(piece.name).trim_prefix(MESH_PREFIX)] = piece
	far.add_child(scene)
	return {"far": far}


func show_tile(key: String, shown: bool) -> void:
	## Shows or hides the far terrain over the tile `key`.
	if _pieces.has(key):
		_pieces[key].visible = shown


func is_shown(key: String) -> bool:
	## Whether the far terrain is drawn over the tile `key`.
	return _pieces.has(key) and _pieces[key].visible
