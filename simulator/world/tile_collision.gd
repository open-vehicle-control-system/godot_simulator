class_name TileCollision
extends RefCounted
## A tile's collision: its ground as a height map, the triangles of what stands on it, and a
## cylinder per tree trunk and post. The shapes of the triangles cost the most to make: they
## can be made ahead, a lot at a time.


static func make_next_shape(content: TileContent) -> bool:
	## Makes the shape of one more lot of the tile's obstacles; false when all are made.
	var made := content.obstacle_shapes.size()
	if made >= content.obstacle_faces.size():
		return false
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(content.obstacle_faces[made])
	content.obstacle_shapes.append(shape)
	return true


static func build(content: TileContent, tiles: TilesSpec) -> Node3D:
	## The collision of a loaded tile, to add under the tile's scene.
	var collision := Node3D.new()
	collision.name = "Collision"
	var body := StaticBody3D.new()
	body.name = "Solid"
	var ground := HeightMapShape3D.new()
	ground.map_width = tiles.ground_samples()
	ground.map_depth = tiles.ground_samples()
	ground.map_data = content.heights_m
	var ground_shape := CollisionShape3D.new()
	ground_shape.name = "Ground"
	ground_shape.shape = ground
	# A height map is centred on its shape, a unit between its samples.
	var centre := content.tile.corner + Vector2.ONE * tiles.tile_size_m * 0.5
	ground_shape.position = Vector3(centre.x, 0.0, centre.y)
	ground_shape.scale = Vector3(tiles.ground_step_m, 1.0, tiles.ground_step_m)
	body.add_child(ground_shape)
	while make_next_shape(content):
		pass
	for shape in content.obstacle_shapes:
		var obstacles := CollisionShape3D.new()
		obstacles.shape = shape
		body.add_child(obstacles)
	collision.add_child(body)
	if not content.trunk_feet.is_empty():
		collision.add_child(TreeTrunks.new(content.trunk_feet))
	if not content.post_feet.is_empty():
		var posts := PostBodies.new()
		for index in content.post_feet.size():
			var size := content.post_sizes[index]
			posts.add_post(content.post_feet[index], size.x, size.y)
		collision.add_child(posts)
	return collision
