class_name SurfaceMaterials
extends RefCounted
## Draws a track's world with the simulator's surfaces: each glTF material a rule of the pack
## covers is replaced by that surface's material, built from the pack's textures.

const SHADERS := {
	"terrain": preload("res://world/shaders/terrain.gdshader"),
	"roof": preload("res://world/shaders/roof.gdshader"),
	"facade": preload("res://world/shaders/facade.gdshader"),
	"seats": preload("res://world/shaders/seats.gdshader"),
}
const MEAN_SAMPLE_PX := 32
const GRAIN_SAMPLE_PX := 96
## How much of its grain every layer shows: the deviation of its luminance over its mean.
const GRAIN_SHOWN := 0.22
const MIN_GRAIN_POWER := 0.25
## A road map pixel away from any road, and a lots map pixel outside any lot.
const OFF_ROAD := Color(0.0, 0.0, 15.0 / 255.0, 1.0)
const OUTSIDE_LOTS := Color(0.0, 1.0, 0.0, 1.0)
## The texels of a lot in the lots' data texture: its frame, its surface, its bays, then two
## per row.
const LOT_HEADER_TEXELS := 3

var _track: TrackSpec
var _textures := {}  # path -> ImageTexture
var _materials := {}  # rule and glTF material -> Material
var _layer_parameters := {}  # shader parameter -> value, shared by the ground's materials


func _init(track: TrackSpec) -> void:
	_track = track


static func apply(world: Node3D, track: TrackSpec) -> String:
	## Replaces the materials of `world` that `track`'s rules cover; returns what went wrong,
	## or "".
	var materials := SurfaceMaterials.new(track)
	for node in world.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.mesh.get_surface_count():
			var drawn := mesh_instance.mesh.surface_get_material(surface)
			if drawn == null:
				continue
			var rule := track.surface_rule(mesh_instance.name, drawn.resource_name)
			if rule == null:
				continue
			var built := materials._material(rule, drawn)
			if built.has("error"):
				return built["error"]
			mesh_instance.set_surface_override_material(surface, built["material"])
	return ""


static func mean_colour(image: Image) -> Vector3:
	## The mean linear colour of an sRGB image.
	var small := image.duplicate() as Image
	small.resize(MEAN_SAMPLE_PX, MEAN_SAMPLE_PX, Image.INTERPOLATE_TRILINEAR)
	var total := Vector3.ZERO
	for row in MEAN_SAMPLE_PX:
		for column in MEAN_SAMPLE_PX:
			var colour := small.get_pixel(column, row).srgb_to_linear()
			total += Vector3(colour.r, colour.g, colour.b)
	return total / (MEAN_SAMPLE_PX * MEAN_SAMPLE_PX)


static func grain_power(image: Image) -> float:
	## The power that brings the grain of an sRGB texture to GRAIN_SHOWN, at most 1.
	var corner := (image.get_size() - Vector2i(GRAIN_SAMPLE_PX, GRAIN_SAMPLE_PX)) / 2
	var total := 0.0
	var total_of_squares := 0.0
	for row in GRAIN_SAMPLE_PX:
		for column in GRAIN_SAMPLE_PX:
			var colour := image.get_pixel(corner.x + column, corner.y + row).srgb_to_linear()
			var luminance := colour.get_luminance()
			total += luminance
			total_of_squares += luminance * luminance
	var count := float(GRAIN_SAMPLE_PX * GRAIN_SAMPLE_PX)
	var mean := total / count
	var deviation := sqrt(maxf(total_of_squares / count - mean * mean, 0.0))
	if deviation <= 0.0:
		return 1.0
	return clampf(GRAIN_SHOWN * mean / deviation, MIN_GRAIN_POWER, 1.0)


func _material(rule: SurfaceRule, drawn: Material) -> Dictionary:
	var key := "%d %s" % [rule.get_instance_id(), drawn.resource_name]
	if not _materials.has(key):
		var built := _build(rule, drawn)
		if built.has("error"):
			return built
		_materials[key] = built["material"]
	return {"material": _materials[key]}


func _build(rule: SurfaceRule, drawn: Material) -> Dictionary:
	if rule.kind == "plain":
		return {"material": _plain(rule)}
	var material := ShaderMaterial.new()
	material.shader = SHADERS[rule.kind]
	match rule.kind:
		"terrain":
			var problem := _set_ground(material, rule, drawn)
			if problem != "":
				return {"error": problem}
		"roof":
			var albedo := _texture(rule.textures_path + "_albedo.jpg")
			material.set_shader_parameter("roofing_albedo", albedo)
			material.set_shader_parameter(
				"roofing_normal", _texture(rule.textures_path + "_normal.jpg")
			)
			material.set_shader_parameter(
				"roofing_roughness", _texture(rule.textures_path + "_rough.jpg")
			)
			material.set_shader_parameter("size_m", rule.size_m)
			material.set_shader_parameter("roofing_mean", mean_colour(albedo.get_image()))
		"facade":
			material.set_shader_parameter(
				"wall_albedo", _texture(rule.textures_path + "_albedo.jpg")
			)
			material.set_shader_parameter(
				"wall_normal", _texture(rule.textures_path + "_normal.jpg")
			)
			material.set_shader_parameter(
				"wall_roughness", _texture(rule.textures_path + "_rough.jpg")
			)
			material.set_shader_parameter("size_m", rule.size_m)
			material.set_shader_parameter("windows", rule.windows)
			material.set_shader_parameter("tint", rule.tint)
		"seats":
			material.set_shader_parameter(
				"concrete_albedo", _texture(rule.textures_path + "_albedo.jpg")
			)
			material.set_shader_parameter(
				"concrete_roughness", _texture(rule.textures_path + "_rough.jpg")
			)
			material.set_shader_parameter("tint", rule.tint)
	return {"material": material}


func _plain(rule: SurfaceRule) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = _texture(rule.textures_path + "_albedo.jpg")
	material.albedo_color = rule.tint
	material.normal_enabled = true
	material.normal_texture = _texture(rule.textures_path + "_normal.jpg")
	material.roughness_texture = _texture(rule.textures_path + "_rough.jpg")
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE / rule.size_m
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _set_ground(material: ShaderMaterial, rule: SurfaceRule, drawn: Material) -> String:
	var map_path := rule.map_path(drawn.resource_name)
	var map := Image.load_from_file(map_path) if FileAccess.file_exists(map_path) else null
	if map == null:
		return "%s: the surface map %s is not in the pack" % [_track.id, map_path.get_file()]
	map.convert(Image.FORMAT_R8)
	material.set_shader_parameter("surface_map", ImageTexture.create_from_image(map))
	var tile := drawn.resource_name
	material.set_shader_parameter("track_map", _map(rule.track_map_path(tile), OFF_ROAD))
	material.set_shader_parameter("roads_map", _map(rule.roads_map_path(tile), OFF_ROAD))
	material.set_shader_parameter("lots_map", _map(rule.lots_map_path(tile), OUTSIDE_LOTS))
	material.set_shader_parameter("photo", (drawn as BaseMaterial3D).albedo_texture)
	material.set_shader_parameter("photo_black", _track.ground.photo_black)
	material.set_shader_parameter("photo_gain", _track.ground.photo_gain)
	material.set_shader_parameter("photo_gamma", _track.ground.photo_gamma)
	material.set_shader_parameter("photo_saturation", _track.ground.photo_saturation)
	if _layer_parameters.is_empty():
		_layer_parameters = _build_layers(_track.ground)
		if _track.ground.road_lines_path != "":
			_layer_parameters["road_lines"] = ImageTexture.create_from_image(
				Image.load_from_file(_track.ground.road_lines_path)
			)
			_layer_parameters["lap_length_m"] = _track.ground.lap_length_m
			_layer_parameters["road_layer"] = _track.ground.road_layer
		if _track.ground.roads_lines_path != "":
			_layer_parameters["roads_lines"] = ImageTexture.create_from_image(
				Image.load_from_file(_track.ground.roads_lines_path)
			)
			_layer_parameters["road_dashes"] = PackedVector2Array(_track.ground.road_dashes)
			_layer_parameters["road_line_width_m"] = _track.ground.road_line_width_m
		_layer_parameters["lots"] = lots_texture(_track.ground.lots)
	for parameter in _layer_parameters:
		material.set_shader_parameter(parameter, _layer_parameters[parameter])
	return ""


static func lots_texture(lots: Array[GroundSpec.Lot]) -> ImageTexture:
	## The lots as a float texture, one row of texels per lot: (origin x, origin z, along x,
	## along z), (colour, layer), (bay width, rows), then per row of bays (along from, along
	## to, across from, across to) and (line at across from, line at across to).
	var width := LOT_HEADER_TEXELS + 2 * GroundSpec.MAX_LOT_ROWS
	var image := Image.create_empty(width, maxi(lots.size(), 1), false, Image.FORMAT_RGBAF)
	for index in lots.size():
		var lot := lots[index]
		image.set_pixel(0, index, Color(lot.origin.x, lot.origin.y, lot.along.x, lot.along.y))
		image.set_pixel(1, index, Color(lot.colour.x, lot.colour.y, lot.colour.z, lot.layer))
		image.set_pixel(2, index, Color(lot.bay_width_m, lot.rows.size(), 0.0, 0.0))
		for row_index in lot.rows.size():
			var row := lot.rows[row_index]
			var texel := LOT_HEADER_TEXELS + 2 * row_index
			image.set_pixel(
				texel, index, Color(row.along_m.x, row.along_m.y, row.across_m.x, row.across_m.y)
			)
			image.set_pixel(texel + 1, index, Color(row.ends.x, row.ends.y, 0.0, 0.0))
	return ImageTexture.create_from_image(image)


func _build_layers(ground: GroundSpec) -> Dictionary:
	## The ground's layers as texture arrays, every layer at the first one's size.
	var maps := {"_albedo.jpg": [], "_normal.jpg": [], "_rough.jpg": []}
	var sizes_m := PackedFloat32Array()
	var means := PackedVector3Array()
	var photo := PackedFloat32Array()
	var grain := PackedFloat32Array()
	var joints_m := PackedFloat32Array()
	var side_px := 0
	for layer in ground.layers:
		for suffix in maps:
			var image := Image.load_from_file(layer.textures_path + suffix)
			if side_px == 0:
				side_px = image.get_width()
			if image.get_size() != Vector2i(side_px, side_px):
				image.resize(side_px, side_px, Image.INTERPOLATE_LANCZOS)
			image.convert(Image.FORMAT_RGB8)
			if suffix == "_albedo.jpg":
				means.append(mean_colour(image))
				grain.append(grain_power(image))
			image.generate_mipmaps()
			maps[suffix].append(image)
		sizes_m.append(layer.size_m)
		photo.append(layer.photo)
		joints_m.append(layer.joints_m)
	var parameters := {
		"layer_size_m": sizes_m,
		"layer_mean": means,
		"layer_photo": photo,
		"layer_grain": grain,
		"layer_joints_m": joints_m,
		"slope_layer": ground.slope_layer,
	}
	var names := {
		"_albedo.jpg": "layer_albedo",
		"_normal.jpg": "layer_normal",
		"_rough.jpg": "layer_roughness"
	}
	for suffix in maps:
		var array := Texture2DArray.new()
		array.create_from_images(maps[suffix])
		parameters[names[suffix]] = array
	return parameters


func _map(path: String, nothing: Color) -> ImageTexture:
	## The map of a tile at `path`, or one pixel of `nothing` when the tile has none.
	var key := "%s %s" % [path, nothing]
	if not _textures.has(key):
		var map: Image
		if path != "" and FileAccess.file_exists(path):
			map = Image.load_from_file(path)
			map.convert(Image.FORMAT_RGBA8)
		else:
			map = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
			map.fill(nothing)
		_textures[key] = ImageTexture.create_from_image(map)
	return _textures[key]


func _texture(path: String) -> ImageTexture:
	if not _textures.has(path):
		var image := Image.load_from_file(path)
		image.generate_mipmaps()
		_textures[path] = ImageTexture.create_from_image(image)
	return _textures[path]
