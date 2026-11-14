class_name TileCollision
extends RefCounted
## A tile's collision: its ground as height maps, a patch each, in a body of its own layer,
## the triangles of what stands on it in lots, and a cylinder per tree trunk and post. The
## height maps and the lots cost the most to make: they can be made ahead, one at a time.

## Where a query meets nothing.
const FAR_FROM_EVERYTHING := Vector3(0.0, 1.0e6, 0.0)


static func prepare_next_shape(content: TileContent, space: PhysicsDirectSpaceState3D) -> bool:
	## Makes one more shape of the tile's collision and has the physics engine build it; false
	## when all are made.
	var shape := _make_next_shape(content)
	if shape == null:
		return false
	# The engine builds a shape the first time one is used in a space: a query does that.
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, FAR_FROM_EVERYTHING)
	space.get_rest_info(query)
	return true


static func build(content: TileContent, tiles: TilesSpec) -> Node3D:
	## The collision of a loaded tile, to add under the tile's scene.
	while _make_next_shape(content) != null:
		pass
	var collision := Node3D.new()
	collision.name = "Collision"
	var ground := ShapeBody.new(CollisionLayers.GROUND)
	ground.name = "Ground"
	var step_m := tiles.ground_step_m
	var between_samples := Basis.from_scale(Vector3(step_m, 1.0, step_m))
	for index in content.ground_shapes.size():
		# A height map is centred on its shape, a unit between its samples.
		var centre := content.tile.corner + content.ground_patches[index].centre_m(step_m)
		ground.add_shape(
			content.ground_shapes[index],
			Transform3D(between_samples, Vector3(centre.x, 0.0, centre.y))
		)
	collision.add_child(ground)
	var solid := ShapeBody.new(CollisionLayers.OBSTACLES)
	solid.name = "Solid"
	for shape in content.obstacle_shapes:
		solid.add_shape(shape, Transform3D.IDENTITY)
	collision.add_child(solid)
	if not content.trunk_feet.is_empty():
		collision.add_child(TreeTrunks.new(content.trunk_feet))
	if not content.post_feet.is_empty():
		var posts := PostBodies.new()
		for index in content.post_feet.size():
			var size := content.post_sizes[index]
			posts.add_post(content.post_feet[index], size.x, size.y)
		collision.add_child(posts)
	return collision


static func _make_next_shape(content: TileContent) -> Shape3D:
	## The height map of one more patch of the tile's ground, then the shape of one more lot of
	## its obstacles; null when all are made.
	var patches_made := content.ground_shapes.size()
	if patches_made < content.ground_patches.size():
		var patch := content.ground_patches[patches_made]
		var ground := HeightMapShape3D.new()
		ground.map_width = patch.samples
		ground.map_depth = patch.samples
		ground.map_data = patch.heights_m
		content.ground_shapes.append(ground)
		return ground
	var lots_made := content.obstacle_shapes.size()
	if lots_made >= content.obstacle_faces.size():
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(content.obstacle_faces[lots_made])
	content.obstacle_shapes.append(shape)
	return shape
