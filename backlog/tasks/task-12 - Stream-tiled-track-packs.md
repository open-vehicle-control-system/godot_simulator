---
id: TASK-12
title: Make every track pack tiled and stream its tiles
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 17:45'
labels: []
dependencies:
  - TASK-20
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every track pack is tiled, circuits and towns alike: one pack format and one loading path, so a track of any size loads quickly and holds only what is near the vehicle.

Problem: a circuit pack is one world scene loaded whole with collision for every mesh (Spa: about 18 s to start, all of it in memory), while a town like Braine-l'Alleud cannot be loaded whole at all.

Design (agreed direction; the builder settles the values and records them in the task):
- Pack format: `track.tiles` replaces `track.world`: a tile index (tile size in metres, each tile's key, corner and bounds) and per tile a glb, its ground maps and its collision data; plus a coarse far terrain of the whole area for the horizon. The single-scene layout is removed, not kept beside it.
- Builders: the circuit builder writes tiles (a mesh belongs to the tile holding its centre; terrain, roads and lot/road maps cut on tile edges without seams); the town builder (TASK-14) writes the same. Tree, sign and pole instances and their collision are listed per tile.
- Simulator: tiles within a load radius of the vehicle are parsed on worker threads and attached on the main thread a few per frame; beyond a larger drop radius they are freed (hysteresis so a tile at the border does not thrash); collision only within a smaller radius; the far terrain hides where detailed tiles are. Before the vehicle is placed, the tiles around the spawn load synchronously with their collision, so the vehicle never stands on missing ground and OVCS sees no gap.
- The vehicle's ground ray and obstacle sweep only ever meet loaded collision: the collision radius stays well beyond the distance the vehicle covers while a tile loads at top speed.
- The experiment's town.gd streaming (worker-thread parse, attach one tile per frame, far terrain with a hole) is the starting point.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mettet and Spa are tiled packs: no world.glb layout remains in the format or the simulator
- [x] #2 Driving a full lap of Spa with --keyboard or the OVCS link shows no hitch, hole or missing collision across tile edges, frame time within budget
- [x] #3 Tile load, drop and collision radii and the synchronous spawn load are tested headless with generated tiled packs
- [x] #4 Spa and Mettet show their first frame, vehicle on the ground and drivable, within 3 s on this machine (today about 18 s for Spa), measured from process start
- [x] #5 After start, tiles keep loading in the background with no frame over 33 ms while driving
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Start-up requirement (user): load only the minimum before the first frame: the spawn tile and its immediate neighbours, with collision, so the vehicle stands on real ground; everything else streams in after start on worker threads, nearest first, never blocking a frame.

Before (process start to first frame, stereo pair on): Spa 13.1 s, Mettet 8.5 s. Spa: engine 0.40, world.glb parse 1.70, scene 0.24, collision from every mesh 5.10, surface materials 4.70 (ground layers 2.05, texture sets 1.7, per-tile maps 1.0), trees and signs 0.16, vehicle model and sky 0.75. Shader compilation was not a start cost.

After: Spa 1.25 to 1.27 s, Mettet 1.23 to 1.26 s (3 runs each). Spa: engine 0.40, shared textures 0.10, tree atlases and sign faces 0.05, far terrain 0.02, the 9 tiles within 200 m read side by side 0.17, their scenes and collision 0.2, vehicle model (0.7) and sky (0.2) read on worker threads meanwhile, viewer and first draw 0.15.

Values settled: tiles 256 m (four per orthophoto tile; Spa 108, Mettet 36); ground heights every 0.5 m; load within 900 m, free beyond 1100 m, collide within 120 m (kept to 180 m), start with those within 200 m; three tiles read at a time, one enters the scene per frame (2 ms on average, 5 ms at most on Spa); obstacle shapes of 3000 triangles, one made per frame; far terrain every 16 m with a 2 m per pixel photo and an 8 m rim.

Decisions: a worker thread only reads (files, glTF, images, JSON); meshes, textures, materials and shapes are made on the main thread, because the headless renderer's mesh storage is not thread-safe and server calls from a worker run on the main thread anyway. The ground collides as a height grid sampled from the drawn terrain and road (0.5 ms a tile), since triangles cost 0.6 us each on the main thread whichever thread asks; other meshes collide as triangles, their shapes made ahead in lots (a Mettet tile holds 22 700 obstacle triangles: 16 ms in one step before). Texture sets and tree atlases are DDS (BC1, BC5 normals with z rebuilt in the shaders, BC3 atlases) from Godot's encoder: a 2048 px map loads in 0.3 ms instead of 40 to 75 ms; Pillow's BC1 encoder made the grass 4% lighter with 10% less grain and showed blocks on saturated colour. A tile's photo is a JPEG cut from the world's own toned photo (the experiment's darkened copy, which the grade was tuned on), its mipmaps built on the worker.

Frames over 33 ms came from two causes, both fixed: the stereo sender read each pair back synchronously, waiting for the GPU to finish the last frame (104 of 8103 frames on Spa, worst 40 ms, where the forest keeps the GPU at 16.6 ms; 673 with the single-scene simulator), now read back asynchronously a few frames later with the time of the frame it shows; and a tile's obstacle shape was made in one step. Laps over the link, stereo pair on: Spa at 180 km/h 8118 frames, none over 33 ms, worst 26.7 ms; Mettet at 144 km/h 3309 frames, none over, worst 27 ms. The vehicle never stalled and rode at the same heights as before the tiles.

Not the same as before: the single-scene world's photo had no mipmaps, so the terrain surface's softened reads of it (vegetation over a metre, steep faces over a few) did nothing; with mipmaps they work as docs/track_creation.md asks, the grass is about 4% lighter and softer up close, and distant ground no longer speckles. Each tree's impostor, turn and tint are drawn from its tile's random stream, so single trees differ. Beyond the loaded tiles the far terrain has no trees. --stereo-record still reads pairs back synchronously.
<!-- SECTION:NOTES:END -->
