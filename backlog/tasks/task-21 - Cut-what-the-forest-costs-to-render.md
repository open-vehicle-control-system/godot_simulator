---
id: TASK-21
title: Cut what the forest costs to render
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 18:05'
updated_date: '2026-11-14 18:09'
labels: []
dependencies: []
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Spa's forest stretches keep the GPU at 16 to 17 ms a frame with the stereo pair on. Find what the trees cost, cut it, draw trees only within a distance with a far representation beyond it, and add a light distance haze, without touching what the stereo cameras see near the vehicle.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The GPU frame time in Spa's three densest forest stretches, stereo pair on, is measured before and after and drops by a quarter or more
- [x] #2 A lap of Spa at 180 km/h has no frame over 33 ms and a worst frame no longer than before
- [x] #3 Trees are drawn up to a distance the pack gives and do not pop where it ends
- [x] #4 Beyond it, loaded tile or far terrain, woods are still there and read as many crowns
- [x] #5 The haze comes from the pack; nothing within 100 m of the cameras loses more than 5% of its contrast
- [x] #6 The stereo camera's image of the road is unchanged
- [x] #7 docs/track_creation.md, pack_format.md and architecture.md describe draw distances, the canopy, tree shadows and haze
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured first (RX 7800 XT, 1080p window plus the 1280x720 stereo pair, frame cap lifted, standing in the three densest stretches, ROS x,y 526,341 / -191,406 / 658,-82): GPU 17.1 / 17.1 / 16.5 ms a frame; the same pack without its trees 10.3 / 7.6 / 8.1. So trees cost 7 to 9.5 ms, and not where expected: without their shadows 11.2 / 9.0 (shadows 6 to 8 ms), drawn only within 250 m of a tile's centre 15.6 / 15.4 (distance: 1.5 ms). Each viewport renders its own four shadow cascades, and cards cut out by a texture fill them slowly: the same cards opaque cost 0.5 to 1 ms. A shorter shadow distance (160 m) saved nothing (17.7 / 18.0: the cascades cover the same pixels), two cascades 1 to 2 ms, a 4096 shadow map 7 ms (10.1 / 9.4) at half the shadow sharpness for everything: left as it is, a setting to weigh on its own. Godot has no per-viewport shadow map size and cannot share shadow maps between the stereo cameras.

Done: (1) a tree's shadow is cast by the silhouette of its cards as plain triangles (rectangles over a 32-row grid of the atlas's alpha, read from a small mipmap), drawn only into the shadow maps; the cards cast none. (2) Trees and silhouettes are batched per impostor and 64 m cluster (32 m and 128 m were no better; 48 rows of silhouette cost 0.8 ms more, 16 rows 0.2 less). (3) trees.canopy.from_m is the trees' draw distance (Spa 600 m, Mettet 700 m): each tree shrinks to its foot over the last fifth; clusters beyond are culled. Drawing to 450 m instead of 900 m saved 0.5 ms and half the draw calls, 250 m nothing more. (4) canopy.glb, written by tools/track_tiles.py: the woods as a surface over the crowns every 8 m, a mesh per tile, whole track; it rises from under the ground over the fifth before the trees shrink; coloured as the impostors' crowns, shaded by the far photo and drawn round crowns, vertices 2.5 m up or down for a jagged outline. Dithering trees out showed as pepper noise on the canopy, a dithered canopy as a screen-door band: both replaced by shrinking and rising. (5) track.haze.visibility_m (both packs 16 km; 20 km without the field, as before): exponential fog in the sky's colour; at 16 km 97.6% of contrast is left at 100 m, 78% at 1 km. 12 km washed the hills at 1 km out. (6) --timing reports GPU time over all viewports, where the worst was, draw calls, objects and primitives.

After: 12.4 / 10.7 / 11.6 ms in the three stretches (-27%, -37%, -30%), first frame 1.28 s after start; draw calls 3185 -> 8447, primitives 14.8 -> 16.3 million at the first. Lap of Spa at 180 km/h over the link, stereo on, 60 frames a second: worst frame 27.2 -> 27.0 ms, none over 33 ms; worst GPU frame 17.5 -> 15.8 ms, worst 5 s mean 16.1 -> 12.6 ms (under the cap the GPU slows its clock, so means sit near 12.5 ms either way). Left stereo image at 526,341: its lower half differs by 0.1/255 on average.

Captures 110/111 forest straight, 112/113/116 wooded hills (113 first canopy, 116 with crowns), 114/115 left stereo image.

Still wrong: the canopy is a closed surface where the impostor woods are sparse, so seen from above the woods thicken at 600 m; a wood's edge is a wall 8 m high with crowns drawn on it; a lone tree or a hedgerow has no canopy and is gone beyond the draw distance; what is left of the frame (10 ms without any tree) is the terrain and its shadows in three viewports; signs and posts are still one batch per tile.
<!-- SECTION:NOTES:END -->
