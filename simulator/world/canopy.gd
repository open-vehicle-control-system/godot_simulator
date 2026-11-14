class_name Canopy
extends Node3D
## A track's woods from afar: one coarse surface over the crowns, coloured as they are and
## shaded as the far terrain's photo shows them, drawn where the trees are not drawn one by
## one. It rises from the ground among the last trees drawn, and stands whole where they
## start to shrink.

const SHADER := preload("res://world/shaders/canopy.gdshader")


static func build(track: TrackSpec, photo: Texture2D) -> Dictionary:
	## `{"canopy": Canopy}` from the pack's canopy scene, under the far terrain's `photo`, or
	## `{"error": reason}`.
	var trees := track.trees
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(trees.canopy_scene_path, state) != OK:
		return {"error": "%s does not load" % trees.canopy_scene_path.get_file()}
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("photo", photo)
	if track.ground != null:
		material.set_shader_parameter("photo_black", track.ground.photo_black)
		material.set_shader_parameter("photo_gamma", track.ground.photo_gamma)
	var risen_at_m := Forest.fade_start_m(trees.draw_distance_m)
	var rises_from_m := 2.0 * risen_at_m - trees.draw_distance_m
	material.set_shader_parameter("rises_from_m", rises_from_m)
	material.set_shader_parameter("risen_at_m", risen_at_m)
	var canopy := Canopy.new()
	canopy.name = "Canopy"
	var scene := document.generate_scene(state)
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var piece := node as MeshInstance3D
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		piece.visibility_range_begin = maxf(0.0, rises_from_m - reach_m(piece.get_aabb()))
	canopy.add_child(scene)
	return {"canopy": canopy}


static func reach_m(bounds: AABB) -> float:
	## How far from its middle a piece with these bounds reaches.
	return bounds.size.length() * 0.5 + bounds.get_center().length()
