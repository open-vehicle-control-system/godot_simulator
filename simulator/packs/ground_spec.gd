class_name GroundSpec
extends RefCounted
## A track pack's `ground`: the layers its surface maps name by index, the grade that turns
## its orthophoto's colours into albedo, and what lies on it: the lap's road, the roads around
## it and the parking lots.

const MAX_LAYERS := 10
const MAX_DASHES := 4
const MAX_LOTS := 255
const MAX_LOT_ROWS := 16


class Layer:
	extends RefCounted
	var textures_path: String  ## the texture set, without its suffixes
	var size_m: float  ## the width the texture set covers
	var photo: float  ## how far the layer takes the photo's colour, 0 to 1
	var joints_m := 0.0  ## the size of the slabs the layer is laid in; 0 when it has none


class LotRow:
	extends RefCounted
	## A row of bays in its lot's frame: dividers a bay's width apart.
	var along_m: Vector2  ## the first and the last divider
	var across_m: Vector2  ## the dividers' ends
	var ends: Vector2  ## 1 where a line closes the row at each of `across_m`


class Lot:
	extends RefCounted
	## A parking lot, in Godot's world frame.
	var layer: int
	var colour: Vector3  ## linear albedo
	var origin: Vector2  ## (x, z) of its frame's origin
	var along: Vector2  ## (x, z) of the unit vector its rows run along
	var across: Vector2  ## (x, z) of the unit vector to the left of `along`, seen from above
	var bay_width_m: float
	var rows: Array[LotRow] = []


var layers: Array[Layer] = []
var slope_layer := 0  ## the index of the layer steep faces are drawn with
var road_lines_path := ""  ## "" when the ground has no road
var lap_length_m := 0.0
var road_layer := 0  ## the index of the layer the road's asphalt is drawn with
var roads_lines_path := ""  ## "" when the ground has no roads around the lap
var road_dashes: Array[Vector2] = []  ## each dashed pattern's (dash, gap) in metres
var road_line_width_m := 0.0
var lots: Array[Lot] = []
var photo_black := Vector3.ZERO  ## the photo's haze, linear RGB
var photo_gain := Vector3.ONE
var photo_gamma := 1.0
var photo_saturation := 1.0


static func parse(reader: ManifestReader, directory: String) -> GroundSpec:
	## The ground at `ground` in `reader`; `reader.error` tells what is wrong with it.
	var ground := GroundSpec.new()
	var layer_readers := reader.readers("ground.layers")
	reader.check(layer_readers.size() >= 1 and layer_readers.size() <= MAX_LAYERS, "ground.layers")
	for layer_reader in layer_readers:
		var layer := Layer.new()
		for suffix in SurfaceRule.TEXTURE_SUFFIXES:
			layer_reader.file("textures", directory, suffix)
		layer.textures_path = directory.path_join(layer_reader.text("textures"))
		layer.size_m = layer_reader.positive("size_m")
		layer.photo = layer_reader.number("photo")
		layer_reader.check(layer.photo >= 0.0 and layer.photo <= 1.0, "photo")
		if layer_reader.has("joints_m"):
			layer.joints_m = layer_reader.positive("joints_m")
		if reader.error == "":
			reader.error = layer_reader.error
		ground.layers.append(layer)
	var black := reader.numbers("ground.photo_grade.black", 3)
	var gain := reader.numbers("ground.photo_grade.gain", 3)
	ground.photo_black = Vector3(black[0], black[1], black[2])
	ground.photo_gain = Vector3(gain[0], gain[1], gain[2])
	ground.photo_gamma = reader.positive("ground.photo_grade.gamma")
	ground.photo_saturation = reader.number("ground.photo_grade.saturation")
	ground.slope_layer = int(reader.number("ground.slope_layer"))
	reader.check(
		ground.slope_layer >= 0 and ground.slope_layer < ground.layers.size(), "ground.slope_layer"
	)
	if reader.has("ground.road"):
		ground.road_lines_path = reader.file("ground.road.lines", directory)
		ground.lap_length_m = reader.positive("ground.road.lap_length_m")
		ground.road_layer = int(reader.number("ground.road.layer"))
		reader.check(
			ground.road_layer >= 0 and ground.road_layer < ground.layers.size(), "ground.road.layer"
		)
	if reader.has("ground.roads"):
		ground._read_roads(reader, directory)
	if reader.has("ground.lots"):
		ground._read_lots(reader, directory)
	return ground


func _read_roads(reader: ManifestReader, directory: String) -> void:
	roads_lines_path = reader.file("ground.roads.lines", directory)
	road_line_width_m = reader.positive("ground.roads.line_width_m")
	var dashes := reader.list("ground.roads.dashes_m")
	reader.check(dashes.size() <= MAX_DASHES, "ground.roads.dashes_m")
	for index in dashes.size():
		var dash := reader.numbers("ground.roads.dashes_m.%d" % index, 2)
		reader.check(dash[0] > 0.0 and dash[1] > 0.0, "ground.roads.dashes_m")
		road_dashes.append(Vector2(dash[0], dash[1]))


func _read_lots(reader: ManifestReader, directory: String) -> void:
	var path := reader.file("ground.lots", directory)
	if reader.error != "":
		return
	var listed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var lots_reader := ManifestReader.new(reader.pack_id, {"lots": listed}, path.get_file() + ": ")
	var lot_readers := lots_reader.readers("lots")
	lots_reader.check(lot_readers.size() <= MAX_LOTS, "lots")
	for lot_reader in lot_readers:
		lots.append(_read_lot(lot_reader))
		if lots_reader.error == "":
			lots_reader.error = lot_reader.error
	if reader.error == "":
		reader.error = lots_reader.error


func _read_lot(reader: ManifestReader) -> Lot:
	var lot := Lot.new()
	lot.layer = int(reader.number("layer"))
	reader.check(lot.layer >= 0 and lot.layer < layers.size(), "layer")
	var colour := reader.numbers("colour", 3)
	lot.colour = Vector3(colour[0], colour[1], colour[2])
	# The pack's frame is ROS's: its (x, y) are Godot's (z, x).
	var origin := reader.numbers("origin_m", 2)
	lot.origin = Vector2(origin[1], origin[0])
	var yaw := deg_to_rad(reader.number("yaw_deg"))
	lot.along = Vector2(sin(yaw), cos(yaw))
	lot.across = Vector2(cos(yaw), -sin(yaw))
	lot.bay_width_m = reader.number("bay_width_m")
	var row_readers := reader.readers("rows")
	reader.check(row_readers.size() <= MAX_LOT_ROWS, "rows")
	reader.check(row_readers.is_empty() or lot.bay_width_m > 0.0, "bay_width_m")
	for row_reader in row_readers:
		var row := LotRow.new()
		var along := row_reader.numbers("along_m", 2)
		var across := row_reader.numbers("across_m", 2)
		var ends := row_reader.numbers("ends", 2)
		row.along_m = Vector2(along[0], along[1])
		row.across_m = Vector2(across[0], across[1])
		row.ends = Vector2(ends[0], ends[1])
		lot.rows.append(row)
		if reader.error == "":
			reader.error = row_reader.error
	return lot
