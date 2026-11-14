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
| `vehicle/bicycle_model.gd` | The kinematic bicycle model. Pure |
| `vehicle/vehicle.gd` | The vehicle: follows the commanded speed and steering on the ground, keeps an odometer, reports its motion |
| `vehicle/instrument_scales.gd` | Needle and steering wheel angles from the pack's scales. Pure |
| `vehicle/instruments.gd` | Turns the cockpit's needles and steering wheel as the vehicle moves |
| `vehicle/mirrors.gd`, `vehicle/mirror.gdshader` | The mirrors: a view looking back per piece of mirror glass |
| `world/track_world.gd` | The track's world around its spawn, and its lighting and atmosphere |
| `packs/tiles_spec.gd` | A track's tiles, validated |
| `world/track_tiles.gd`, `world/tile_ring.gd` | The world, streamed: which tiles are loaded, collide and are freed as the vehicle moves |
| `world/tile_loader.gd`, `world/tile_content.gd` | A tile read from its files on a worker thread, then built into a scene on the main thread |
| `world/tile_collision.gd` | A tile's collision: its ground's heights, the meshes standing on it, trunks and posts |
| `world/far_terrain.gd` | The coarse terrain shown where a tile is not loaded |
| `packs/surface_rule.gd`, `packs/ground_spec.gd`, `packs/trees_spec.gd`, `packs/signs_spec.gd` | A track's surfaces, ground layers, trees and signs, validated |
| `world/surface_materials.gd`, `world/shaders/` | The simulator's surfaces: materials built from the pack's textures and maps |
| `world/forest.gd`, `world/tree_trunks.gd` | A tile's trees as impostors; their trunks as collision in one physics body |
| `world/road_signs.gd`, `world/post_bodies.gd` | A tile's road signs and signals: a batch per sign face, one of posts, one of signal heads; its posts as collision in one physics body |
| `world/instance_batch.gd` | Copies of one mesh, filled on any thread and drawn together |
| `world/sky_sun.gd` | Finds the sun in a panorama. Pure |
| `view/screenshot.gd` | Saves the window and reports what the window and the other viewports cost to render |
| `view/frame_times.gd` | Reports when the first frame was drawn and the worst frame times after it (`--timing`) |
| `link/link_protocol.gd` | The link's packets and the Godot ↔ ROS frames. Pure |
| `link/simulator_link.gd` | The link's TCP client |
| `sensors/stereo_camera.gd` | The stereo pair's cameras and intrinsics |
| `sensors/stereo_sender.gd`, `sensors/stereo_recorder.gd` | Pairs to the link, pairs to disk |
| `view/viewer.gd`, `view/view_poses.gd` | The views, the HUD and the keys |

Logic that only computes is in scripts of static functions, tested without a scene; nodes hold
runtime state. Dependencies come into each node's `setup()` from `main.gd`.

## Frames

Godot's vehicle frame is +X left, +Y up, +Z forward; ROS's `base_link` (REP-103) is x forward,
y left, z up. A ROS vector (x, y, z) is the Godot (z, x, y), a cyclic permutation, so
rotations map the same way. Packs and the link use ROS frames; only the simulator's inside uses
Godot's.

## The vehicle's motion

OVCS owns the motion: the vehicle moves at the speed and steering angle of the last drive, by a
bicycle model about the rear axle, and rests on the ground under its four wheels: a ray below
each wheel finds its contact, the body follows the plane through them (pitch and roll), and each
wheel rises or drops within a short suspension travel to touch its own contact. Its state
(velocity, IMU) is the origin's, which turns about the same point as the rear axle. With no
drive for half a second, or no link, it is commanded to stop. There is no tyre or suspension
model.

The vehicle does not pass through what it hits. Before every move its body box (raised off the
ground so kerbs and bumps never stop it) is swept along the move; if the track's collision is in
the way (walls, barriers, buildings, tree trunks, sign posts) it goes as far as is clear and stops there,
speed zero, odometer stopped, which is what OVCS then reads. A move away from what it touches is
always allowed, so it can back off or turn away.

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
- **The ground collides as a height grid** the builder samples from the drawn ground: making
  one costs half a millisecond, where triangles cost 0.6 µs each on the main thread whichever
  thread asks. Only what stands on the ground collides as triangles, in shapes of a few
  thousand made one a frame once the tile is in the scene, ahead of the vehicle's coming.

`--timing` prints when the first frame was drawn and, every five seconds, the worst frame and
how many ran over 33 ms.

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

## Packs

Nothing in the simulator names a track or a vehicle. Packs are data directories found at
runtime: see [Pack format](./pack_format.md).
