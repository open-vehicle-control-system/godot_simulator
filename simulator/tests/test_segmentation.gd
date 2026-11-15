extends TestCase
## The segmentation classes and the labels what is drawn carries.

const LABEL_INCLUDE := "res://sensors/shaders/label.gdshaderinc"

var _worlds: Array[TrackTiles] = []


func test_shaders_label_with_the_ids_of_the_classes() -> void:
	var include := FileAccess.get_file_as_string(LABEL_INCLUDE)
	var pattern := RegEx.create_from_string("const float CLASS_(\\w+) = (\\d+)\\.0;")
	var found := pattern.search_all(include)
	assert_true(found.size() > 0, "no class in %s" % LABEL_INCLUDE)
	for constant in found:
		var class_id := constant.get_string(2).to_int()
		assert_eq(Segmentation.CLASSES[class_id]["name"], constant.get_string(1).to_lower())
	var layer := RegEx.create_from_string("LABEL_LAYER = 1u << (\\d+)u;").search(include)
	assert_eq(layer.get_string(1).to_int(), Segmentation.LABEL_LAYER - 1)


func test_every_class_has_its_own_colour() -> void:
	var colours := {}
	for described in Segmentation.described():
		colours[described["colour"]] = described["name"]
	assert_eq(colours.size(), Segmentation.CLASSES.size())
	assert_eq(Segmentation.described()[Segmentation.ROAD]["name"], "road")


func test_only_the_ground_truth_camera_lacks_the_label_layer() -> void:
	var camera := Camera3D.new()
	var label_bit := 1 << (Segmentation.LABEL_LAYER - 1)
	assert_eq(camera.cull_mask & label_bit, label_bit, "a camera sees every layer")
	assert_eq(Segmentation.ground_truth_cull_mask(), camera.cull_mask & ~label_bit)
	camera.free()


func test_a_labelled_track_draws_each_surface_with_the_class_of_its_kind() -> void:
	var cases := {
		"roof": Segmentation.BUILDING,
		"facade": Segmentation.BUILDING,
		"seats": Segmentation.BUILDING,
		"plain": Segmentation.STRUCTURE,
	}
	for kind in cases:
		var mesh := _surface_drawn_as(kind, true)
		var material := mesh.get_surface_override_material(0)
		assert_eq(material.next_pass, Segmentation.label_pass(cases[kind]), kind)
		assert_eq(material.next_pass.get_shader_parameter("class_id"), float(cases[kind]), kind)


func test_a_track_that_is_not_labelled_has_no_label_pass() -> void:
	var mesh := _surface_drawn_as("roof", false)
	assert_true(mesh.get_surface_override_material(0).next_pass == null)


func test_labels_what_every_mesh_under_a_node_is_drawn_with_but_glass() -> void:
	var vehicle := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = BoxMesh.new()
	var paint := StandardMaterial3D.new()
	body.mesh.surface_set_material(0, paint)
	var wheel := MeshInstance3D.new()
	wheel.mesh = CylinderMesh.new()
	var window := MeshInstance3D.new()
	window.mesh = QuadMesh.new()
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	window.set_surface_override_material(0, glass)
	# How Godot imports glTF's BLEND glass.
	var windscreen := MeshInstance3D.new()
	windscreen.mesh = QuadMesh.new()
	var sorted_glass := StandardMaterial3D.new()
	sorted_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	windscreen.set_surface_override_material(0, sorted_glass)
	var grille := MeshInstance3D.new()
	grille.mesh = QuadMesh.new()
	var cut_out := StandardMaterial3D.new()
	cut_out.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	grille.set_surface_override_material(0, cut_out)
	vehicle.add_child(body)
	body.add_child(wheel)
	body.add_child(window)
	body.add_child(windscreen)
	body.add_child(grille)

	Segmentation.label_under(vehicle, Segmentation.VEHICLE)
	Segmentation.label_under(vehicle, Segmentation.VEHICLE)

	var label := Segmentation.label_pass(Segmentation.VEHICLE)
	assert_eq(paint.next_pass, label)
	assert_eq(wheel.get_active_material(0).next_pass, label, "a mesh without material")
	assert_true(label.next_pass == null, "labelled twice")
	assert_true(glass.next_pass == null, "glass shows what is behind it")
	assert_true(sorted_glass.next_pass == null, "glass drawn after a depth pre-pass too")
	assert_eq(cut_out.next_pass, label, "a cut-out is opaque where it is drawn")
	vehicle.free()


func _surface_drawn_as(kind: String, labelled: bool) -> MeshInstance3D:
	## The mesh of a generated track whose only material a rule of `kind` draws.
	var directory := PackFixtures.fresh_directory("segmentation_%s" % kind)
	var manifest := PackFixtures.ground_manifest("labels")
	var rule := {
		"materials": "M_Photo_*",
		"surface": kind,
		"textures": "textures/grass",
		"size_m": 3.0,
		"windows": "house",
		"tint": [1.0, 1.0, 1.0],
	}
	manifest["track"]["surfaces"] = [rule]
	var pack := PackFixtures.write_pack(directory, manifest)
	PackFixtures.write_photo_world(pack, "M_Photo_1")
	PackFixtures.write_ground_files(pack)
	var track: TrackSpec = PackLibrary.scan([directory]).load_track("labels")["track"]
	track.labelled = labelled
	var world: TrackTiles = TrackWorld.load_world(track)["world"]
	_worlds.append(world)
	return world.find_child("Terrain_a", true, false)


func _exit_tree() -> void:
	for world in _worlds:
		world.free()
