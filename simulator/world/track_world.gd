class_name TrackWorld
extends RefCounted
## Builds a track pack's world: its tiles, streamed, and the environment (sky, sun, tone
## mapping) it is lit by.

const DEFAULT_SUN_DIRECTION := Vector3(0.39, 0.62, -0.68)
const SUN_ENERGY := 3.2
const SUN_COLOUR := Color(1.0, 0.95, 0.87)
const SUN_ANGULAR_SIZE_DEG := 1.2
const SHADOW_DISTANCE_M := 320.0
const SKY_ENERGY := 1.0
const AMBIENT_ENERGY := 1.0
const EXPOSURE := 0.85
const WHITE := 6.0
const FOG_DENSITY_PER_M := 0.00018
const SSAO_RADIUS_M := 1.2
const SSAO_INTENSITY := 2.2
const GLOW_INTENSITY := 0.25
const GLOW_THRESHOLD := 1.4


static func load_world(track: TrackSpec) -> Dictionary:
	## `{"world": TrackTiles}` with the tiles around the track's spawn loaded, the nearest with
	## their collision, drawn with the track's surfaces, trees and signs; or `{"error": reason}`.
	var found := TrackTiles.create(track)
	if found.has("error"):
		return found
	var world: TrackTiles = found["tiles"]
	var problem := world.load_around(track.spawn_position)
	if problem != "":
		world.free()
		return {"error": problem}
	return {"world": world}


static func lighting(track: TrackSpec) -> Dictionary:
	## `{"environment": Environment, "sun": DirectionalLight3D}`: the track's sky, the sun
	## where the pack puts it (or where its sky shows it), ambient light, atmosphere and tone
	## mapping. A sky is turned so its sun is where the light comes from.
	return lighting_under(track, read_sky(track))


static func read_sky(track: TrackSpec) -> Dictionary:
	## `{"panorama": Image, "sun": Vector3}`: the track's sky and where it shows the sun, or
	## `{}` for a track without a sky. Touches no scene, so it runs on a worker thread.
	if track.sky_path == "":
		return {}
	var panorama := Image.load_from_file(track.sky_path)
	return {"panorama": panorama, "sun": SkySun.direction(panorama)}


static func lighting_under(track: TrackSpec, sky_read: Dictionary) -> Dictionary:
	## `lighting` under the sky `read_sky` read.
	var lit := Environment.new()
	var sky := Sky.new()
	var sun_direction := DEFAULT_SUN_DIRECTION.normalized()
	if track.sun_given:
		sun_direction = track.sun_direction()
	if not sky_read.is_empty():
		var panorama := PanoramaSkyMaterial.new()
		panorama.panorama = ImageTexture.create_from_image(sky_read["panorama"])
		panorama.energy_multiplier = SKY_ENERGY
		sky.sky_material = panorama
		var sky_sun: Vector3 = sky_read["sun"]
		if track.sun_given:
			lit.sky_rotation = Vector3(0.0, SkySun.yaw_between(sky_sun, sun_direction), 0.0)
		else:
			sun_direction = sky_sun
	else:
		sky.sky_material = ProceduralSkyMaterial.new()
	lit.background_mode = Environment.BG_SKY
	lit.sky = sky
	lit.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	lit.ambient_light_energy = AMBIENT_ENERGY
	lit.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	lit.tonemap_mode = Environment.TONE_MAPPER_ACES
	lit.tonemap_exposure = EXPOSURE
	lit.tonemap_white = WHITE
	lit.ssao_enabled = true
	lit.ssao_radius = SSAO_RADIUS_M
	lit.ssao_intensity = SSAO_INTENSITY
	lit.glow_enabled = true
	lit.glow_intensity = GLOW_INTENSITY
	lit.glow_hdr_threshold = GLOW_THRESHOLD
	lit.fog_enabled = true
	lit.fog_density = FOG_DENSITY_PER_M
	lit.fog_aerial_perspective = 1.0
	lit.fog_sky_affect = 0.0
	return {"environment": lit, "sun": _sun(sun_direction)}


static func _sun(towards_sun: Vector3) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.light_energy = SUN_ENERGY
	light.light_color = SUN_COLOUR
	light.light_angular_distance = SUN_ANGULAR_SIZE_DEG
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	light.directional_shadow_blend_splits = true
	light.directional_shadow_max_distance = SHADOW_DISTANCE_M
	light.basis = Basis.looking_at(-towards_sun)
	return light
