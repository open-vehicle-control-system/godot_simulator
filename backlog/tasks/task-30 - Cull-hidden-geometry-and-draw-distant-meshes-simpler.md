---
id: TASK-30
title: Cull hidden geometry and draw distant meshes simpler
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 22:19'
labels: []
dependencies:
  - TASK-23
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Occlusion culling (occluders from terrain and buildings, built per tile) and level-of-detail meshes for buildings and terrain at distance, to cut the remaining terrain and shadow cost.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 GPU time at Spa's heaviest views measured before and after
- [x] #2 No popping or holes at LOD transitions in captures
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured with the frame cap lifted, RX 7800 XT, 1080p window and the 1280 x 720 pair, GPU time of the three viewports. Spa's heaviest view (ROS 880,363, yaw 123): 14.2 ms and 10.8 million primitives before; 13.2 ms and 7.3 million with coarser levels of the ground's meshes (made as a tile is read, drawn once their error is under a pixel, borders kept whole); 10.3 ms with the sun's angular size at 0.53 deg instead of 1.2; 9.6 ms with both. Mettet's estate (ROS -430,245, yaw 32): 5.0 to 4.4 ms. Not kept: occlusion culling with terrain and building occluders (0.0 to 0.1 ms: shadow maps are not occlusion culled) and simpler distant buildings (hiding all buildings changes nothing measurable). Captures 200 to 216 in build/captures; with and without the levels the same view differs by sub-pixel shifts along lines, no hole.
<!-- SECTION:NOTES:END -->
