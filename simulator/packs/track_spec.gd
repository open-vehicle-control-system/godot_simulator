class_name TrackSpec
extends RefCounted
## A track pack's contents, in Godot's world frame (+Y up). pack.json gives positions in a ROS
## world frame (x, y, z up), mapped as vectors are: Godot (y, z, x).

const MAX_INDIRECT_LIGHT_STRENGTH := 4.0

var id: String
var name: String
var directory: String
var tiles: TilesSpec
var far_scene_path := ""  ## the coarse terrain of the whole area, or "" without one
var far_photo_path := ""
var sky_path := ""  ## an equirectangular panorama, or "" for a procedural sky
var sun_given := false
var sun_azimuth_rad := 0.0  ## towards the sun, about +Y from +Z towards +X
var sun_elevation_rad := 0.0
var visibility_m := 0.0  ## how far one sees through the haze; 0 when the pack has no `haze`
var indirect_light_strength := 1.0  ## of the light surfaces cast on each other; 0 for none
var ground: GroundSpec = null  ## null when the pack has no `ground`
var surfaces: Array[SurfaceRule] = []
var trees: TreesSpec = null  ## null when the pack has no `trees`
var signs: SignsSpec = null  ## null when the pack has no `signs`
var spawn_position: Vector3
var spawn_yaw_rad: float  ## about +Y, from +Z (Godot forward) towards +X; ROS yaw about z
var labelled := false  ## true when its world is drawn with segmentation labels: not a pack field


static func parse(manifest: Dictionary, directory: String) -> Dictionary:
	## `{"track": TrackSpec}` from a track pack's manifest, or `{"error": reason}`.
	var reader := ManifestReader.new(manifest["id"], manifest)
	var track_section: Variant = manifest.get("track")
	var reader_within_track := ManifestReader.new(
		manifest["id"], track_section if track_section is Dictionary else {}, "track."
	)
	var spec := TrackSpec.new()
	spec.id = manifest["id"]
	spec.directory = directory
	spec.name = reader.text("name")
	spec.tiles = TilesSpec.parse(reader_within_track, directory)
	if reader.has("track.far"):
		spec.far_scene_path = reader_within_track.file("far.scene", directory)
		spec.far_photo_path = reader_within_track.file("far.photo", directory)
	spec.spawn_position = reader.ros_vector("track.spawn.position_m")
	spec.spawn_yaw_rad = deg_to_rad(reader.number("track.spawn.yaw_deg"))
	if reader.has("track.sky"):
		var sky := reader.text("track.sky")
		spec.sky_path = directory.path_join(sky)
		if reader.error == "" and not FileAccess.file_exists(spec.sky_path):
			return {"error": "%s: track.sky names %s, which is not in the pack" % [spec.id, sky]}
	if reader.has("track.sun"):
		spec.sun_given = true
		spec.sun_azimuth_rad = deg_to_rad(reader.number("track.sun.azimuth_deg"))
		spec.sun_elevation_rad = deg_to_rad(reader.positive("track.sun.elevation_deg", 90.0))
	if reader.has("track.haze"):
		spec.visibility_m = reader.positive("track.haze.visibility_m")
	if reader.has("track.indirect_light"):
		var strength := reader.number("track.indirect_light.strength")
		reader.check(
			strength >= 0.0 and strength <= MAX_INDIRECT_LIGHT_STRENGTH,
			"track.indirect_light.strength"
		)
		spec.indirect_light_strength = strength
	if reader.has("track.ground"):
		spec.ground = GroundSpec.parse(reader_within_track, directory)
	if reader.has("track.surfaces"):
		spec._read_surfaces(reader, directory)
	spec._check_tile_maps(reader)
	if reader.has("track.trees"):
		spec.trees = TreesSpec.parse(reader_within_track, directory)
		if reader_within_track.error == "" and spec.trees.canopy_scene_path != "":
			reader_within_track.check(spec.far_photo_path != "", "trees.canopy needs track.far:")
	if reader.has("track.signs"):
		spec.signs = SignsSpec.parse(reader_within_track, directory)
	if reader.error == "":
		reader.error = reader_within_track.error
	if reader.error != "":
		return {"error": reader.error}
	return {"track": spec}


func surface_rule(mesh_name: String, material_name: String) -> SurfaceRule:
	## The first rule covering `material_name` on `mesh_name`, or null when it is drawn as its
	## glTF material.
	for rule in surfaces:
		if rule.covers(mesh_name, material_name):
			return rule
	return null


func sun_direction() -> Vector3:
	## The unit vector towards the sun.
	var level := cos(sun_elevation_rad)
	return Vector3(
		level * sin(sun_azimuth_rad), sin(sun_elevation_rad), level * cos(sun_azimuth_rad)
	)


func move_spawn(ros_position_m: Vector3, yaw_deg: float) -> void:
	## Starts the vehicle at this pose, given as `track.spawn` is in pack.json.
	spawn_position = Vector3(ros_position_m.y, ros_position_m.z, ros_position_m.x)
	spawn_yaw_rad = deg_to_rad(yaw_deg)


func spawn_transform() -> Transform3D:
	## Where the vehicle starts, facing along the spawn yaw.
	return Transform3D(Basis(Vector3.UP, spawn_yaw_rad), spawn_position)


func _read_surfaces(reader: ManifestReader, directory: String) -> void:
	for rule_reader in reader.readers("track.surfaces"):
		var rule := SurfaceRule.parse(rule_reader, directory)
		if reader.error == "":
			reader.error = rule_reader.error
		if rule.kind == "terrain" and reader.error == "" and ground == null:
			reader.error = "%s: track.surfaces needs track.ground for its terrain" % id
		surfaces.append(rule)


func _check_tile_maps(reader: ManifestReader) -> void:
	## A tile's road maps need the lines images `ground` names.
	for tile in tiles.tiles:
		if reader.error != "":
			return
		var has_lines := {
			"track": ground != null and ground.road_lines_path != "",
			"roads": ground != null and ground.roads_lines_path != "",
			"lots": ground != null,
		}
		for map in tile.maps:
			if not has_lines[map]:
				reader.error = (
					"%s: tile %s has a %s map, which needs track.ground%s"
					% [id, tile.key, map, {"track": ".road", "roads": ".roads", "lots": ""}[map]]
				)
