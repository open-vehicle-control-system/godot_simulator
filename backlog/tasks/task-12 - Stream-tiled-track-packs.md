---
id: TASK-12
title: Make every track pack tiled and stream its tiles
status: To Do
assignee: []
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 14:04'
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
- [ ] #1 Mettet and Spa are tiled packs: no world.glb layout remains in the format or the simulator
- [ ] #2 Driving a full lap of Spa with --keyboard or the OVCS link shows no hitch, hole or missing collision across tile edges, frame time within budget
- [ ] #3 Tile load, drop and collision radii and the synchronous spawn load are tested headless with generated tiled packs
- [ ] #4 Spa and Mettet show their first frame, vehicle on the ground and drivable, within 3 s on this machine (today about 18 s for Spa), measured from process start
- [ ] #5 After start, tiles keep loading in the background with no frame over 33 ms while driving
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Start-up requirement (user): load only the minimum before the first frame: the spawn tile and its immediate neighbours, with collision, so the vehicle stands on real ground; everything else streams in after start on worker threads, nearest first, never blocking a frame. Profile where today's start time goes (glb parsing, collision building, trees, textures and mipmaps, shader compilation) before designing, and report the breakdown before and after.
<!-- SECTION:NOTES:END -->
