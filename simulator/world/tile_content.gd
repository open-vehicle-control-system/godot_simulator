class_name TileContent
extends RefCounted
## One tile as read from its pack: what its scene is built from, and what its collision is
## built from. Reading fills it on any thread; its scene is built on the main thread.

var tile: TilesSpec.Tile
var error := ""  ## why the tile did not load, or ""
var document: GLTFDocument  ## its meshes as read, until the scene is built
var state: GLTFState
var ground_images: Dictionary[String, Image] = {}  ## its photo and maps, by shader parameter
var batches: Array[InstanceBatch] = []  ## its trees and signs
var decals: Array[Dictionary] = []  ## its decals as RoadDecals read them
var scene: Node3D  ## its meshes, trees and signs, drawn with the track's surfaces
var ground_patches: Array[GroundPatch] = []  ## the ground's heights
## The triangles of every mesh that is not ground, in lots small enough to make a shape of
## within a frame.
var obstacle_faces: Array[PackedVector3Array] = []
var ground_shapes: Array[HeightMapShape3D] = []  ## made so far, a patch each
var obstacle_shapes: Array[ConcavePolygonShape3D] = []  ## made so far, a lot each
var trunk_feet: Array[Vector3] = []
var post_feet: Array[Vector3] = []
var post_sizes: Array[Vector2] = []  ## each post's (diameter, height)
