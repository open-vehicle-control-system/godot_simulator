---
title: Architecture
description: How the simulator, the packs and the OVCS link fit together.
---

The simulator stands where the vehicle's hardware would meet the world. OVCS's simulated
hardware computes how the vehicle moves from what its VMS commands and sends that motion over
the [simulator link](./simulator_link.md); the simulator moves the vehicle accordingly in a
track pack's world and sends back what the vehicle senses there.

```text
OVCS VMS ── CAN ── simulated hardware ── SimulatorCore.Link ──TCP── simulator
                                          ◄── state, stereo images ──┘
                                          drive (speed, steering) ──►
```

## Parts

| Script | Role |
|---|---|
| `main.gd` | Composition root: reads the options, loads the packs, wires everything |
| `simulator_options.gd` | The command-line options |
| `packs/pack_library.gd` | Finds packs on the search path by id |
| `packs/vehicle_spec.gd`, `packs/track_spec.gd` | A pack's manifest, validated, in Godot's frames |
| `packs/instruments_spec.gd`, `packs/mirrors_spec.gd` | A vehicle's cockpit instruments and mirrors, validated |
| `vehicle/vehicle_model.gd` | The vehicle's meshes, from its glTF or a placeholder |
| `vehicle/dynamic_bicycle.gd` | The dynamic bicycle model: tyres that slip. Pure |
| `vehicle/bicycle_model.gd` | The kinematic bicycle model, the slow limit of the dynamic one. Pure |
| `vehicle/vehicle.gd` | The vehicle: follows the commanded speed and steering on the ground, keeps an odometer, reports its motion |
| `vehicle/instrument_scales.gd` | Needle and steering wheel angles from the pack's scales. Pure |
| `vehicle/instruments.gd` | Turns the cockpit's needles and steering wheel as the vehicle moves |
| `vehicle/mirrors.gd`, `vehicle/mirror.gdshader` | The mirrors: a view looking back per piece of mirror glass |
| `world/track_world.gd` | The track's world around its spawn, and its lighting and haze |
| `packs/tiles_spec.gd` | A track's tiles, validated |
| `world/track_tiles.gd`, `world/tile_ring.gd` | The world, streamed: which tiles are loaded, collide and are freed as the vehicle moves |
| `world/tile_loader.gd`, `world/tile_content.gd` | A tile read from its files on a worker thread, then built into a scene on the main thread |
| `world/tile_collision.gd` | A tile's collision: its ground's heights, the meshes standing on it, trunks and posts |
| `world/ground_patch.gd` | A square piece of a tile's height grid, a height map each. Pure |
| `world/shape_body.gd`, `world/collision_layers.gd` | Shapes in one static body of the physics server; the layers of the ground and of what stands on it |
| `world/far_terrain.gd` | The coarse terrain shown where a tile is not loaded |
| `packs/surface_rule.gd`, `packs/ground_spec.gd`, `packs/trees_spec.gd`, `packs/signs_spec.gd` | A track's surfaces, ground layers, trees and signs, validated |
| `world/surface_materials.gd`, `world/shaders/` | The simulator's surfaces: materials built from the pack's textures and maps |
| `world/forest.gd`, `world/tree_trunks.gd` | A tile's trees as impostors, batched by cluster, and the silhouettes casting their shadows; their trunks as collision in one physics body |
| `world/canopy.gd` | The woods as one coarse surface, drawn where the trees are too far to be drawn one by one |
| `world/road_signs.gd`, `world/post_bodies.gd` | A tile's road signs and signals: a batch per sign face, one of posts, one of signal heads; its posts as collision in one physics body |
| `packs/decals_spec.gd`, `world/road_decals.gd` | A track's decals, validated; a tile's decals projected onto its ground alone |
| `world/instance_batch.gd` | Copies of one mesh about a centre, filled on any thread, drawn and culled together |
| `world/sky_sun.gd` | Finds the sun in a panorama. Pure |
| `view/screenshot.gd` | Saves the window and reports what the window and the other viewports cost to render |
| `view/upscaling.gd` | Draws the window smaller and upscales it with FSR 2 (`--upscale`) |
| `view/frame_times.gd` | Reports when the first frame was drawn, the worst frame times after it, a physics step's time, the GPU's time over all viewports and what was drawn (`--timing`) |
| `link/link_protocol.gd` | The link's packets and the Godot ↔ ROS frames. Pure |
| `link/simulator_link.gd` | The link's TCP client |
| `sensors/stereo_camera.gd` | The stereo pair's cameras and intrinsics |
| `sensors/lens_distortion.gd`, `sensors/shaders/distortion.inc` | A lens's distortion in OpenCV's model, on the CPU and on the GPU |
| `sensors/camera_effect.gd`, `sensors/shaders/camera.comp` | What makes a stereo camera's view the image of a camera: distortion, motion blur, vignetting, noise, exposure ([Stereo camera](./stereo.md#cameras-not-pinholes)) |
| `sensors/compute_shader.gd` | Compiles the compute shaders, with their includes |
| `sensors/stereo_sender.gd`, `sensors/stereo_recorder.gd` | Pairs to the link, frames to disk |
| `sensors/gpu_readback.gd` | Reads textures back from the GPU a few frames later, all of them before the simulator quits |
| `vehicle/drive_log.gd`, `vehicle/drive_log_driver.gd` | A drive over time read from a CSV, and the vehicle driven by it (`--drive-log`) |
| `world/tiles_at_once.gd` | Every tile around the vehicle in the scene before each frame, for a repeatable recording (`--record`) |
| `sensors/stereo_frame.gd`, `sensors/numpy_file.gd` | What the camera shows of one frame; a float map as a `.npy` file |
| `sensors/segmentation.gd`, `sensors/shaders/label.gdshader`, `label.gdshaderinc` | The segmentation classes, and how a surface shows its class to the ground truth camera |
| `sensors/ground_truth_camera.gd`, `sensors/ground_truth_effect.gd`, `sensors/shaders/ground_truth.comp` | The left camera's view as depth, disparity and segmentation ([Stereo camera](./stereo.md#ground-truth)) |
| `view/viewer.gd`, `view/view_poses.gd` | The views, the HUD and the keys |

Logic that only computes is in scripts of static functions, tested without a scene; nodes hold
runtime state. Dependencies come into each node's `setup()` from `main.gd`.

## Frames

Godot's vehicle frame is +X left, +Y up, +Z forward; ROS's `base_link` (REP-103) is x forward,
y left, z up. A ROS vector (x, y, z) is the Godot (z, x, y), a cyclic permutation, so
rotations map the same way. Packs and the link use ROS frames; only the simulator's inside uses
Godot's.

## The vehicle's motion

OVCS owns the speed: the vehicle rolls along its heading at the speed of the last drive, and
steers by its steering angle; it rests on the ground under its four wheels: a ray below each
wheel finds its contact, the body follows the plane through them (pitch and roll), and each
wheel rises or drops within a short suspension travel to touch its own contact. With no drive
for half a second, or no link, it is commanded to stop.

How it turns is a dynamic bicycle model (`DynamicBicycle`), one axle at each end, about the
centre of gravity: the vehicle can point elsewhere than it goes. Each axle's side force grows
with its slip angle (the angle between where its wheels roll and where they go), at first by its
cornering stiffness, up to a peak of its grip, then falls a little as the tyres slide (Pacejka's
magic formula). Braking moves load onto the front axle and accelerating onto the rear (mass ×
acceleration × centre-of-gravity height / wheelbase); cornering moves load from the inner wheels
to the outer ones, shared between the axles by roll stiffness. A tyre's stiffness grows less
than its load and its friction falls as its load rises, so the more loaded axle, and the axle
whose load cornering moves across most (the front, on a road car), loses grip: the vehicle
understeers at the limit. The force an axle carries along the road, to change the speed or to
hold it while sliding, takes its share of the grip (the friction circle): braking is split by the
brakes' bias, the rear kept below its share of the load as a proportioning valve does, traction
goes to the driven axle. Steady cornering never exceeds the grip. Every property of the vehicle
is its pack's `vehicle.dynamics` ([Pack format](./pack_format.md#vehicle-packs)); `--set`
overrides one for a run, to tune it.

Taken gently, corners follow the kinematic path. A road car as `tools/vehicle_dynamics.py`
describes it behaves as standard tests measure production cars: it understeers by about 2° per
g (ISO 4138), braking at 0.6 g in a 60 km/h, 50 m turn tightens its line a little without a
slide (ISO 7975), and lifting off at the limit tucks its nose in. Brakes biased to the rear
without a proportioning valve, or soft rear tyres, slide the tail out and can spin it; steering
into the slide catches it. The model steps in substeps of at most 4 ms (and half its fastest time
constant), and below 1 to 3 m/s it blends into the kinematic bicycle model about the rear axle,
so parking and standing still are steady. Over a wall, the slide loses the share of speed the
wall takes. The tyres pass on at most their grip along the road, whatever the speed command
asks.

The state OVCS reads is the origin's: the speed along the heading, the lateral velocity and yaw
rate from the model, and what an IMU there reads, the model's lateral acceleration (plus the yaw
acceleration's share at the origin) and gravity's reaction. The odometer counts the part of each
move along the heading: what the wheels roll. There is no longitudinal tyre slip (the speed is
OVCS's), no suspension dynamics (load moves across at once) and no aerodynamics; a
vehicle moved by its own forces is OVCS's TASK-81.

The vehicle does not pass through what it hits. Before every move its body box (raised off the
ground so kerbs never reach it) is swept along the move; if the track's collision is in
the way (walls, barriers, buildings, tree trunks, sign posts) it goes as far as is clear, then
slides along the obstacle with the part of the rest of its move that runs along it, keeping
that share of its speed: a scrape keeps most of it, a head-on hit stops it, odometer and speed
as OVCS then reads them. Steering always turns the vehicle, so it can turn away from what it
touches. The ground is on a physics layer
of its own (`CollisionLayers`) that the wheels' rays see and the sweep does not, so a crest or a
bank reaching the box never stops it. A sweep ignores what the box is already into, so that is
asked first: a body into an obstacle moves freely away from it, to back off or turn away, and
not at all further into it.

## Physics

The physics engine is Jolt (`physics/3d/physics_engine` in `project.godot`). Nothing is
simulated: the simulator only asks the world questions, four rays and a body sweep a step. Jolt
answers a ray in 1.9 µs and the sweep in 3 µs on Spa, where Godot Physics took 2.4 µs and
110 µs: over a lap a physics step takes 0.6 to 0.8 ms where it took 1.0 ms (the rest of a step
is the tiles' and the link's own work), and the worst frame is the same.

Jolt builds a shape the first time it is used in a space, not when its data is set, and a height
map costs it 45 ns a sample: 12 ms for a tile's 513 by 513 heights. So a tile's ground is cut
into patches of 128 squares a side (`GroundPatch`), a height map each, built in about a
millisecond, and every shape is built ahead by asking a query about it far from everything
(`TileCollision.prepare_next_shape`): those of the tiles loaded at start before the first
frame, which is drawn 0.14 s later for it. The shapes are held by bodies of the physics server
(`ShapeBody`), not by `CollisionShape3D` nodes: in a debug build of the engine, assigning a shape
to a node sets its debug colour, which has the shape built again.

## The world, streamed

A track is tiles ([Pack format](./pack_format.md#tiles)), and the simulator holds only those
near the vehicle, so a track of any size starts in about a second and costs the same to run.

- **Before the first frame** it loads what every tile shares (the ground's layers, the tree
  impostors, the sign faces, the far terrain) and the tiles within 200 m of the spawn, with
  their collision; the vehicle's model and the sky load on worker threads meanwhile. The
  vehicle is placed on real ground.
- **Afterwards** the tiles within 900 m of the vehicle are read on worker threads, nearest
  first, three at a time, and enter the scene one a frame; a tile is freed once 1100 m away,
  further than it is loaded from, so a tile at the border is not loaded and freed in turns.
  Where a tile is not loaded, the far terrain shows.
- **A worker thread only reads**: files, glTF, images, JSON. Everything that reaches the
  rendering or physics server (meshes, textures, materials, shapes) is made on the main
  thread when the tile enters the scene, a few milliseconds a tile.
- **Collision is only near the vehicle**: the tiles within 120 m of it, kept until 180 m.
  Checked every physics step before the vehicle moves; a tile that should collide and is not
  loaded (the vehicle was moved there) is loaded at once, so the ground rays and the body
  sweep never meet missing collision.
- **The ground collides as a height grid** the builder samples from the drawn ground, cut into
  square patches; only what stands on the ground collides as triangles, in lots of a few
  thousand. Each patch and each lot is a shape made and built within a millisecond or two, one
  a frame once the tile is in the scene, ahead of the vehicle's coming; a tile whose shapes
  are built starts colliding in 0.2 ms.

`--timing` prints when the first frame was drawn and, every five seconds, the worst frame and
how many ran over 33 ms, what a physics step took, what the GPU spent on all viewports (the window, the stereo pair, the
mirrors) with where the vehicle was when it spent the most, and the draw calls, objects and
primitives of a frame.

## Trees from near to far

Every viewport renders its own shadow maps, so what casts a shadow is drawn four times more
per viewport; with the stereo pair that is three viewports.

- **Near**, a tree is crossed cards cut out by its impostor's atlas, in a batch per impostor
  and 64 m cluster, so batches behind the camera or out of range are culled.
- **Its shadow** is cast by another batch of the same cluster: the cards' silhouette as
  rectangles of plain triangles, made once per impostor from a small mipmap of the atlas's
  alpha, drawn only into the shadow maps and only within the sun's shadow distance. The cards
  themselves cast nothing.
- **Towards the pack's draw distance** each tree shrinks to its foot, by its own distance to
  the camera; its cluster is culled once all of it is gone.
- **Beyond**, the canopy stands for the woods: one coarse surface per tile, of the whole
  track, loaded once at start, shaded by the far terrain's photo and drawn with round crowns.
  Near the camera it lies under the ground; it rises to the crowns over the distance before
  the trees start to shrink.
- **Haze** is exponential fog in the sky's colour, its density from the pack's visibility.

## The ground from near to far

A tile's ground is 33 thousand triangles of terrain and up to 25 thousand of road, and 41
tiles are loaded around the vehicle at Spa. As a tile is read, on its worker thread, each of
its ground meshes gets coarser levels (`TileLoader`, 20 ms a mesh), and the renderer draws the
coarsest whose error is under a pixel on screen, in the picture and in the shadow maps alike:
a change of level moves nothing by more than that, so nothing pops. Every level keeps all the
vertices of its mesh's border, so two tiles drawn at different levels meet without a crack.
Collision does not come from these meshes ([The world, streamed](#the-world-streamed)).

The sun is as wide as the real one, 0.53°: the edge of a shadow widens with the distance to
what casts it, and the renderer pays for that width in every lit pixel. At 1.2° the shadows
were softer than a clear day's and cost 4 ms more at Spa's heaviest view.

Measured at that view (ROS 880,363, yaw 123) and among Mettet's houses (ROS -430,245, yaw
32), frame cap lifted, RX 7800 XT, a 1080p window and the 1280 x 720 pair, GPU time of the
three viewports:

| | Spa | Mettet |
|---|---|---|
| Before | 14.2 ms, 10.8 million primitives | 5.0 ms, 9.2 million |
| The ground's levels | 13.2 ms, 7.3 million | 4.4 ms, 7.0 million |
| The sun at 0.53° | 10.3 ms | |
| Both | 9.6 ms | 4.4 ms |

What was tried and not kept, at the same views:

- **Occlusion culling**, with the terrain (a coarse level of it, lowered by a metre) and the
  buildings as occluders: 200 to 460 fewer draw calls of 5400 and 2500, and 0.0 to 0.1 ms.
  Shadow maps are not occlusion culled, and they are most of a frame; in the picture the
  depth prepass already spares what is hidden its shading. It would also cost the CPU a
  rasterisation of the occluders per viewport.
- **Simpler buildings far away**: hiding every building and barrier changes the frame by less
  than 0.1 ms. A building is a few hundred triangles.

Of the 9.6 ms left at Spa, 5.9 are shadows: 3.7 the soft edges' sampling, 0.5 the ground
drawn into the shadow maps, the rest the trees'.

## Screen-space light

The window, and only the window, is lit by what its own picture shows
(`TrackWorld.window_lighting`): screen-space indirect light, at the engine's medium quality
and half resolution, as strong as the pack's `indirect_light` asks. It costs the window 0.3 ms
a frame on the GPU (at Spa's heaviest view the three viewports take 13.9 ms without it and
14.2 ms with it, frame cap lifted), and darkens what is under a roof, a stand or the vehicle.
The stereo cameras and the mirrors see the world's own lighting, without it: in their images
it drew thin outlines around trees against a hill.

Screen-space reflections are off everywhere: 0.4 ms over the three viewports, and nothing in
the packs is wet or polished enough to show them but the vehicle's paint and a few windows,
while grass verges seen at a grazing angle came out speckled.

## Upscaling the window

`--upscale=quality`, `balanced` or `performance` draws the window's 3D at 67%, 59% or 50% of
its width and height and has FSR 2 rebuild the full picture from the frames before
(`Upscaling`). At Spa's heaviest view the window then takes 5.0, 4.5 or 3.9 ms of GPU time a
frame instead of 7.4 ms. It is off unless asked: the picture is softer, and fine detail on the
moving vehicle (its lettering) breaks up, more at each level. Only the window's viewport is
set, so the stereo cameras draw every pixel as before: where no tree is in view their images
are the same byte for byte with any level, and elsewhere they differ as two frames of the
same view do, by 1/255 in a few hundred pixels of the trees' cards.

## The cockpit

What moves in the cockpit comes from the vehicle pack ([Pack format](./pack_format.md#vehicle-packs)):
which nodes of the model are the needles and the steering wheel, their axes and scales, and
which material is mirror glass. They show the vehicle's own state (its speed and steering), so
they read the same driven by OVCS, by the keys or by `--hold`; the rev counter shows the motor
speed that the wheels' speed implies through the pack's gear ratio.

Each mirror is a small view of the world from its glass, looking back. They are rendered only
in the cockpit view, lit as the world without tone mapping, glow or ambient occlusion, which
the window applies once to the whole frame; in the other views the glass is plain polished
metal. `--screenshot` reports their cost with the stereo cameras', as the other viewports.

## Surfaces

A track pack says which simulator surface draws each glTF material of its tiles
([Pack format](./pack_format.md#surfaces)); the shaders are the simulator's, the textures and
maps the pack's.

- The ground is up to ten tiled layers chosen per pixel by a surface map and coloured by the
  orthophoto: layers give the detail near the camera, the photo the colour, and the photo alone
  remains far away. A layer is read twice, at its size and enlarged and turned, so its tiling
  does not show; every layer's grain is brought to the same strength.
- The road is drawn on the ground, road mesh and terrain alike, from a track map (how far
  along the lap and right of the centreline a point is) and the road lines image (asphalt
  edges, kerbs, racing line per metre of lap), so lines stay crisp and continuous whatever the
  photo's resolution and the meshes' extent.
- The roads around the lap are drawn the same way from a roads map and their lines image, which
  also gives each road its layer, its colour lane by lane and its markings (lines at any
  offset, solid or dashed, crossings, stop lines). A parking lot is drawn from a lots map (the
  lot and the distance to its edge) and the pack's description of it: its layer, one colour
  and its rows of bays. Between a road's or a lot's edges the photo's pixels are not drawn.
- A roof is a roofing texture set tinted to the one colour the pack's builder read for it,
  never the photo's pixels.
- Steep faces keep only the photo's broad colour, take the slope layer and read textures on a
  vertical plane.
- In a shader, whatever reads screen-space gradients (`dFdx`, `fwidth`, a texture read without
  explicit gradients) is computed before any branch: inside one the gradients are undefined
  along the branch's border and leave a dotted line there.

## Ground truth

`--ground-truth` adds a camera at the left stereo camera's place whose cull mask lacks one
render layer, which no object is on. Shaders read the camera's layers: for that camera alone
the world's own shaders emit their class instead of their colour, and the materials that are
not the world's (a rule's `roof`, `facade`, `seats` and `plain`, the sign posts, the vehicle)
carry a label pass, a second material drawn over them whose triangles are empty for every
other camera. A label pass is drawn a hair nearer than its surface along each ray and writes
its depth: one only tested against the depth buffer, without writing it, lost a 2x2 quad
about one frame in 300 on RADV (RX 7800 XT), though its depth passed the test. A compositor
effect then reads that camera's depth buffer and labels. The label
passes are only added with `--ground-truth`, except on the sign posts and signal heads, a few
draws a tile.

## Packs

Nothing in the simulator names a track or a vehicle. Packs are data directories found at
runtime: see [Pack format](./pack_format.md).

The simulator bundles two packs in `simulator/default_packs/` (a `.gdignore` keeps Godot from
importing them): `default_track` and `default_car`, built by `tools/default_packs.py`: the
track from code, its trees and sky from Poly Haven's, CC0; the car from "Generic Sedan Car" by Márcio Meireles, CC BY 4.0, credited
in its pack. `main.gd` searches that directory last, and
`SimulatorOptions` selects them when `--track` or `--vehicle` is left out; nothing else in
the simulator knows them.
