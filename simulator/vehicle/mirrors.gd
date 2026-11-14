class_name Mirrors
extends Node
## The vehicle's rear-view mirrors: each piece of mirror glass on the body shows what a camera
## at its centre, looking back along the vehicle, sees.
##
## The glass is the body's surface drawn with the material the pack names. Its vertices, by the
## side of the vehicle they are on, make up to three mirrors: left door, interior, right door.
## The views are rendered only while `live`: three more views of the world every frame are
## worth their cost only when the driver's seat looks at them.

const MirrorShader := preload("res://vehicle/mirror.gdshader")
const SIDES := ["left", "interior", "right"]
## Glass further from the centreline than this share of the body's width is a door mirror's.
const DOOR_MIRRORS_BEYOND := 0.25
const VIEW_WIDTH_PX := 384
const MIN_VIEW_HEIGHT_PX := 16
const NEAR_M := 0.05
const FAR_M := 1500.0

## Whether the mirrors show what is behind, rendered every frame.
var live := false:
	set = _set_live
var viewports: Array[SubViewport] = []  ## one per mirror, in SIDES' order
var cameras: Array[Camera3D] = []

var _glass := ShaderMaterial.new()


func setup(spec: VehicleSpec, body: Node3D, lighting: Environment) -> String:
	## Gives the mirror glass of `body` its views, lit as `lighting` without what a camera
	## adds to an image (the view through the windscreen adds it once to the whole frame).
	## Returns "" or what is wrong with the pack.
	name = "Mirrors"
	var surface := _glass_surface(body, spec.mirrors.material)
	if surface < 0:
		return (
			"%s: vehicle.mirrors.material names %s, which the model's Body is not drawn with"
			% [spec.id, spec.mirrors.material]
		)
	var door_mirrors_beyond_m := spec.body_size.x * DOOR_MIRRORS_BEYOND
	var mesh := (body as MeshInstance3D).mesh
	var boxes := glass_boxes(
		mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX], door_mirrors_beyond_m
	)
	_glass.shader = MirrorShader
	_glass.set_shader_parameter("door_mirrors_beyond_m", door_mirrors_beyond_m)
	var seen := _as_seen_in_a_mirror(lighting)
	for side in SIDES:
		if not boxes.has(side):
			continue
		var box: AABB = boxes[side]
		var hfov_deg := (
			spec.mirrors.interior_hfov_deg if side == "interior" else spec.mirrors.door_hfov_deg
		)
		var viewport := _view_from(body, box, hfov_deg, seen)
		_glass.set_shader_parameter("%s_view" % side, viewport.get_texture())
		_glass.set_shader_parameter("%s_low" % side, box.position)
		_glass.set_shader_parameter("%s_high" % side, box.end)
	(body as MeshInstance3D).set_surface_override_material(surface, _glass)
	_set_live(false)
	return ""


static func glass_boxes(vertices: PackedVector3Array, door_mirrors_beyond_m: float) -> Dictionary:
	## The box around each mirror's glass, by side (`left`, `interior`, `right`): a vertex
	## further than `door_mirrors_beyond_m` from the centreline is on that side's door mirror.
	var boxes := {}
	for vertex in vertices:
		var side := "interior"
		if absf(vertex.x) > door_mirrors_beyond_m:
			side = "left" if vertex.x > 0.0 else "right"
		boxes[side] = boxes[side].expand(vertex) if boxes.has(side) else AABB(vertex, Vector3.ZERO)
	return boxes


func _glass_surface(body: Node3D, material_name: String) -> int:
	if not body is MeshInstance3D:
		return -1
	var mesh := (body as MeshInstance3D).mesh
	for surface in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface)
		if material != null and material.resource_name == material_name:
			return surface
	return -1


func _as_seen_in_a_mirror(lighting: Environment) -> Environment:
	## `lighting` giving the scene's light as it is: no tone mapping, glow or ambient
	## occlusion.
	if lighting == null:
		return null
	var seen: Environment = lighting.duplicate()
	seen.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	seen.tonemap_exposure = 1.0
	seen.glow_enabled = false
	seen.ssao_enabled = false
	return seen


func _view_from(body: Node3D, box: AABB, hfov_deg: float, seen: Environment) -> SubViewport:
	var viewport := SubViewport.new()
	var height_px := roundi(VIEW_WIDTH_PX * box.size.y / maxf(box.size.x, 0.01))
	viewport.size = Vector2i(VIEW_WIDTH_PX, maxi(height_px, MIN_VIEW_HEIGHT_PX))
	viewport.use_hdr_2d = true  # the scene's light, not an image already fit for a screen
	var camera := Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH  # fov is horizontal
	camera.fov = hfov_deg
	camera.near = NEAR_M
	camera.far = FAR_M
	camera.environment = seen
	viewport.add_child(camera)
	add_child(viewport)
	camera.current = true
	# A camera looks along its -Z, the body's rear: it needs no turn.
	var holder := RemoteTransform3D.new()
	holder.position = box.get_center()
	body.add_child(holder)
	holder.remote_path = holder.get_path_to(camera)
	viewports.append(viewport)
	cameras.append(camera)
	return viewport


func _set_live(now_live: bool) -> void:
	live = now_live
	_glass.set_shader_parameter("live", live)
	for viewport in viewports:
		viewport.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if live else SubViewport.UPDATE_DISABLED
		)
