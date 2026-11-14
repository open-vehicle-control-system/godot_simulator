---
id: TASK-27
title: Use Jolt physics
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 21:14'
labels: []
dependencies: []
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Switch the project to Godot's built-in Jolt physics engine and verify the vehicle's ground rays, obstacle sweep, height-grid and trimesh collision, tree and post bodies behave as before, with timings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 All simulator tests pass on Jolt
- [x] #2 Physics query cost and a full Spa lap's worst frame measured before and after
- [x] #3 The vehicle stops against what stands on the ground as before, on Jolt as on Godot Physics, and never passes through what its body is already into
- [x] #4 No frame of a Spa lap waits for a collision shape to be built
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design. Options: (1) keep Godot Physics; (2) Jolt as it is; (3) Jolt with its differences fixed at their cause. Chosen: 3.

What differed on Jolt, and what was done:
- A ray starting exactly on a face hits it (Godot Physics misses it). It showed a test leaving its world to the next one: the runner now lets a frame pass between tests.
- cast_motion ignores a body the shape already overlaps, and a body is the whole tile (Godot Physics ignores only the shape overlapped). With the ground and the obstacles in one body, a crest reaching the body box opened every wall of the tile; and a body left a millimetre into a wall by the fit to the ground drove through it on the next step. Held drives from Spa's spawn (30 of them, 20 s each) showed both engines doing it, in different places. Now the ground is a body on its own layer (CollisionLayers.GROUND) that only the wheels' rays ask for, and the sweep first asks whether the box is already into an obstacle (get_rest_info): away from it the move is free, into it there is none. The same 30 drives then stop in the same frame (within one) at the same place (within 3 cm, once 0.8 m) on both engines, and stay there.
- Jolt builds a shape when a body in a space first uses it, not when its data is set: the lots made ahead were built in the frame the tile started colliding, with the height map: 14 ms a tile where Godot Physics took 1.4 ms. A height map costs Jolt 45 ns a sample (12 ms for 513 x 513). Now the ground is cut in patches of 128 squares a side (GroundPatch; 16 a tile on Spa), each a height map built in 1.1 ms, and every shape is built ahead, one a frame, by a query about it far from everything; those of the tiles loaded at start before the first frame. A tile then starts colliding in 0.15 ms (worst 0.32).
- In a debug build, CollisionShape3D.set_shape sets the shape's debug colour, which sends its data again and has Jolt rebuild it: the tile's shapes are held by physics-server bodies (ShapeBody), as tree trunks were.

Measured (Spa, RX 7800 XT, 1080p window and the 1280 x 720 pair; before = HEAD on Godot Physics, after = this change on Jolt):
- A ray: 2.4 -> 1.9 us. The body sweep: 110 -> 2.9 us. Per step, four rays and the sweep: 120 -> 12 us. Heights agree within 1 cm.
- Lap over the link, stereo on, a pure-pursuit driver at up to 180 km/h slowing to the grip limit in corners (7047 m in 229.5 s), two laps each, alternating, other agents' simulators running part of the time: 13842 frames each, none over 33 ms on either; worst frame 32.0 and 31.7 ms before, 31.3 and 32.5 ms after; physics step (--timing now reports it) 1.03 and 1.00 ms before, 0.58 and 0.82 ms after, its worst 4.2 and 5.9 ms before, 1.3 and 5.9 ms after. No stall, 1.1 m at most from the centreline.
- First frame: 1.28 s -> 1.42 s after the engine starts: Jolt builds the collision of the nine tiles around the spawn (0.13 s).
- Two earlier Jolt laps had 22 and 49 frames over 33 ms while the frame rate fell to 43 a second with the GPU at 8 to 10 ms: another simulator was rendering then; the laps above logged who else ran.

Not done: the wheels' rays still take an obstacle lower than 2 m (a barrier, a kerb mesh) for ground once the vehicle is over it; get_rest_info gives the deepest contact only, so a body into two obstacles is judged by one.
<!-- SECTION:NOTES:END -->
