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
var _mutex := Mutex.new()  # guards _images: tiles are read on several threads
var _images := {}  # path -> Image
var _textures := {}  # path -> ImageTexture
var _materials := {}  # rule and glTF material -> Material
var _layer_parameters := {}  # shader parameter -> value, shared by the ground's materials
var _no_road: ImageTexture
var _no_lot: ImageTexture


func _init(track: TrackSpec) -> void:
	_track = track


func prepare() -> String:
	## Loads what every tile's ground is drawn with: the layers, the lines images and the
	## lots. Returns what is wrong with them, or "". To call once, before `apply`.
	_no_road = _one_pixel(OFF_ROAD)
	_no_lot = _one_pixel(OUTSIDE_LOTS)
	var ground := _track.ground
	if ground == null:
		return ""
	var problem := _load_layers(ground)
	if problem != "":
		return problem
	if ground.road_lines_path != "":
		_layer_parameters["road_lines"] = ImageTexture.create_from_image(
			Image.load_from_file(ground.road_lines_path)
		)
		_layer_parameters["lap_length_m"] = ground.lap_length_m
		_layer_parameters["road_layer"] = ground.road_layer
	if ground.roads_lines_path != "":
		_layer_parameters["roads_lines"] = ImageTexture.create_from_image(
			Image.load_from_file(ground.roads_lines_path)
		)
		_layer_parameters["road_dashes"] = PackedVector2Array(ground.road_dashes)
		_layer_parameters["road_line_width_m"] = ground.road_line_width_m
	_layer_parameters["lots"] = lots_texture(ground.lots)
	_layer_parameters["photo_black"] = ground.photo_black
	_layer_parameters["photo_gain"] = ground.photo_gain
	_layer_parameters["photo_gamma"] = ground.photo_gamma
	_layer_parameters["photo_saturation"] = ground.photo_saturation
	return ""


func read_ground(state: GLTFState, tile: TilesSpec.Tile) -> Dictionary:
	## `{"images": {shader parameter: Image}}`: the photo and maps the ground of `tile` is
	## drawn with, none for a tile whose scene `state` has no ground; or `{"error": reason}`.
	## Also reads the texture sets its other surfaces need. Runs on any thread.
	var images: Dictionary[String, Image] = {}
	var has_ground := false
	var meshes := state.get_meshes()
	for node in state.get_nodes():
		if node.mesh < 0:
			continue
		var mesh := meshes[node.mesh].mesh
		for surface in mesh.get_surface_count():
			var drawn := mesh.get_surface_material(surface)
			var rule := _track.surface_rule(
				node.resource_name, drawn.resource_name if drawn else ""
			)
			if rule == null:
				continue
			if rule.kind == "terrain":
				has_ground = true
			else:
				for suffix in SurfaceRule.TEXTURE_SUFFIXES:
					_image(rule.textures_path + suffix)
	if not has_ground:
		return {"images": images}
	for file in [".photo.jpg", ".surface.png"]:
		if not FileAccess.file_exists(tile.path(file)):
			return {"error": "%s is not in the pack" % (tile.key + file)}
	images["photo"] = Image.load_from_file(tile.path(".photo.jpg"))
	if images["photo"] == null:
		return {"error": "%s.photo.jpg does not load" % tile.key}
	# The terrain surface reads the photo at coarser levels: far away, and softened up close.
	images["photo"].generate_mipmaps()
	images["surface_map"] = Image.load_from_file(tile.path(".surface.png"))
	if images["surface_map"] == null:
		return {"error": "%s.surface.png does not load" % tile.key}
	images["surface_map"].convert(Image.FORMAT_R8)
	for kind in tile.maps:
		var map := Image.load_from_file(tile.path(".%s.png" % kind))
		if map == null:
			return {"error": "%s.%s.png does not load" % [tile.key, kind]}
		map.convert(Image.FORMAT_RGBA8)
		images[kind + "_map"] = map
	return {"images": images}


func apply(scene: Node3D, ground_images: Dictionary[String, Image]) -> void:
	## Replaces the materials of a tile's `scene` that the track's rules cover, its ground
	## drawn with the images `read_ground` read for it. On the main thread.
	var ground_material: ShaderMaterial = null
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.mesh.get_surface_count():
			var drawn := mesh_instance.mesh.surface_get_material(surface)
			if drawn == null:
				continue
			var rule := _track.surface_rule(mesh_instance.name, drawn.resource_name)
			if rule == null:
				continue
			if rule.kind == "terrain":
				if ground_material == null:
					ground_material = _ground_material(ground_images)
				mesh_instance.set_surface_override_material(surface, ground_material)
			else:
				mesh_instance.set_surface_override_material(
					surface, _material(rule, drawn.resource_name)
				)


static func load_dds(path: String) -> Image:
	## The DDS texture at `path` with its mipmaps, as it is stored; null when it does not load.
	var image := Image.new()
	if image.load_dds_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	return image


static func mean_colour(image: Image) -> Vector3:
	## The mean linear colour of an sRGB image.
	var small := _readable(image)
	small.resize(MEAN_SAMPLE_PX, MEAN_SAMPLE_PX, Image.INTERPOLATE_TRILINEAR)
	var total := Vector3.ZERO
	for row in MEAN_SAMPLE_PX:
		for column in MEAN_SAMPLE_PX:
			var colour := small.get_pixel(column, row).srgb_to_linear()
			total += Vector3(colour.r, colour.g, colour.b)
	return total / (MEAN_SAMPLE_PX * MEAN_SAMPLE_PX)


static func grain_power(image: Image) -> float:
	## The power that brings the grain of an sRGB texture to GRAIN_SHOWN, at most 1.
	image = _readable(image)
	var sampled := Vector2i(GRAIN_SAMPLE_PX, GRAIN_SAMPLE_PX).min(image.get_size())
	var corner := (image.get_size() - sampled) / 2
	var total := 0.0
	var total_of_squares := 0.0
	for row in sampled.y:
		for column in sampled.x:
			var colour := image.get_pixel(corner.x + column, corner.y + row).srgb_to_linear()
			var luminance := colour.get_luminance()
			total += luminance
			total_of_squares += luminance * luminance
	var count := float(sampled.x * sampled.y)
	var mean := total / count
	var deviation := sqrt(maxf(total_of_squares / count - mean * mean, 0.0))
	if deviation <= 0.0:
		return 1.0
	return clampf(GRAIN_SHOWN * mean / deviation, MIN_GRAIN_POWER, 1.0)


static func _readable(image: Image) -> Image:
	## A copy of `image` whose pixels can be read: its first level, decompressed.
	var copy := image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.clear_mipmaps()
	return copy


func _material(rule: SurfaceRule, material_name: String) -> Material:
	var key := "%d %s" % [rule.get_instance_id(), material_name]
	if not _materials.has(key):
		_materials[key] = _build(rule)
	return _materials[key]


func _build(rule: SurfaceRule) -> Material:
	var material := _surface(rule)
	if _track.labelled:
		material.next_pass = Segmentation.label_pass(Segmentation.SURFACE_CLASSES[rule.kind])
	return material


func _surface(rule: SurfaceRule) -> Material:
	if rule.kind == "plain":
		return _plain(rule)
	var material := ShaderMaterial.new()
	material.shader = SHADERS[rule.kind]
	match rule.kind:
		"roof":
			var albedo_path := rule.textures_path + "_albedo.dds"
			material.set_shader_parameter("roofing_albedo", _texture(albedo_path))
			material.set_shader_parameter(
				"roofing_normal", _texture(rule.textures_path + "_normal.dds")
			)
			material.set_shader_parameter(
				"roofing_roughness", _texture(rule.textures_path + "_rough.dds")
			)
			material.set_shader_parameter("size_m", rule.size_m)
			material.set_shader_parameter("roofing_mean", mean_colour(_image(albedo_path)))
		"facade":
			material.set_shader_parameter(
				"wall_albedo", _texture(rule.textures_path + "_albedo.dds")
			)
			material.set_shader_parameter(
				"wall_normal", _texture(rule.textures_path + "_normal.dds")
			)
			material.set_shader_parameter(
				"wall_roughness", _texture(rule.textures_path + "_rough.dds")
			)
			material.set_shader_parameter("size_m", rule.size_m)
			material.set_shader_parameter("windows", rule.windows)
			material.set_shader_parameter("tint", rule.tint)
		"seats":
			material.set_shader_parameter(
				"concrete_albedo", _texture(rule.textures_path + "_albedo.dds")
			)
			material.set_shader_parameter(
				"concrete_roughness", _texture(rule.textures_path + "_rough.dds")
			)
			material.set_shader_parameter("tint", rule.tint)
	return material


func _plain(rule: SurfaceRule) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = _texture(rule.textures_path + "_albedo.dds")
	material.albedo_color = rule.tint
	material.normal_enabled = true
	material.normal_texture = _texture(rule.textures_path + "_normal.dds")
	material.roughness_texture = _texture(rule.textures_path + "_rough.dds")
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE / rule.size_m
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _ground_material(images: Dictionary[String, Image]) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADERS["terrain"]
	material.set_shader_parameter("track_map", _no_road)
	material.set_shader_parameter("roads_map", _no_road)
	material.set_shader_parameter("lots_map", _no_lot)
	for parameter in images:
		material.set_shader_parameter(parameter, ImageTexture.create_from_image(images[parameter]))
	for parameter in _layer_parameters:
		material.set_shader_parameter(parameter, _layer_parameters[parameter])
	return material


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


func _load_layers(ground: GroundSpec) -> String:
	## The ground's layers as texture arrays; their files are read side by side.
	var loaded: Array[Dictionary] = []
	loaded.resize(ground.layers.size())
	var group := WorkerThreadPool.add_group_task(
		_load_layer.bind(ground.layers, loaded), loaded.size()
	)
	WorkerThreadPool.wait_for_group_task_completion(group)
	var sizes_m := PackedFloat32Array()
	var means := PackedVector3Array()
	var photo := PackedFloat32Array()
	var grain := PackedFloat32Array()
	var joints_m := PackedFloat32Array()
	for index in loaded.size():
		var layer := ground.layers[index]
		for suffix in SurfaceRule.TEXTURE_SUFFIXES:
			var image: Image = loaded[index][suffix]
			var first: Image = loaded[0][suffix]
			if image == null:
				return (
					"%s: %s does not load" % [_track.id, (layer.textures_path + suffix).get_file()]
				)
			if image.get_size() != first.get_size() or image.get_format() != first.get_format():
				return (
					"%s: %s is not of the size and format of the first layer's"
					% [_track.id, (layer.textures_path + suffix).get_file()]
				)
		means.append(loaded[index]["mean"])
		grain.append(loaded[index]["grain"])
		sizes_m.append(layer.size_m)
		photo.append(layer.photo)
		joints_m.append(layer.joints_m)
	_layer_parameters = {
		"layer_size_m": sizes_m,
		"layer_mean": means,
		"layer_photo": photo,
		"layer_grain": grain,
		"layer_joints_m": joints_m,
		"slope_layer": ground.slope_layer,
	}
	var names := {
		"_albedo.dds": "layer_albedo",
		"_normal.dds": "layer_normal",
		"_rough.dds": "layer_roughness"
	}
	for suffix in names:
		var array := Texture2DArray.new()
		array.create_from_images(loaded.map(func(layer): return layer[suffix]))
		_layer_parameters[names[suffix]] = array
	return ""


func _load_layer(index: int, layers: Array[GroundSpec.Layer], loaded: Array[Dictionary]) -> void:
	var layer := {}
	for suffix in SurfaceRule.TEXTURE_SUFFIXES:
		layer[suffix] = load_dds(layers[index].textures_path + suffix)
	var albedo: Image = layer["_albedo.dds"]
	if albedo != null:
		layer["mean"] = mean_colour(albedo)
		layer["grain"] = grain_power(albedo)
	loaded[index] = layer


func _one_pixel(colour: Color) -> ImageTexture:
	var map := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	map.fill(colour)
	return ImageTexture.create_from_image(map)


func _image(path: String) -> Image:
	## The DDS texture at `path`, read once, on whichever thread asks first.
	_mutex.lock()
	if not _images.has(path):
		_images[path] = load_dds(path)
	var image: Image = _images[path]
	_mutex.unlock()
	return image


func _texture(path: String) -> ImageTexture:
	if not _textures.has(path):
		_textures[path] = ImageTexture.create_from_image(_image(path))
	return _textures[path]
