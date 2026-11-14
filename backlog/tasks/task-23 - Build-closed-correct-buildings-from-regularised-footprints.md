---
id: TASK-23
title: 'Build closed, correct buildings from regularised footprints'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:38'
updated_date: '2026-11-14 20:30'
labels: []
dependencies: []
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Buildings are sometimes wrong in shape and not closed (openings between roofs and walls, at gable ends, where the ground slopes). Rebuild every building closed by construction: regularised footprint, walls extruded from it down below the lowest ground under it, roof generated from the same outline by a straight skeleton (flat, gable, hip, skillion, pyramidal), the shape and ridge chosen by fitting the LiDAR (or OSM roof:shape), facades with floors and windows along each wall.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every building mesh is watertight (each edge shared by exactly two triangles), checked by a builder test over both tracks, with a simpler fallback for any that fail
- [x] #2 Roof shape per building chosen by LiDAR fit or OSM tags; counts per shape reported
- [x] #3 Footprints are regularised (right angles snapped, jitter removed) without moving walls off the photo
- [x] #4 Before/after captures at Spa and Mettet, close and from above; frame time unchanged
- [x] #5 Facades lay windows out per wall, from its corner and ground floor, with doors at ground level
- [x] #6 The cause of the missing wall parts is established and guarded by the closed-solid check
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause of the openings: neither inward winding nor a dropped closing wall (the experiment's meshes had every wall facing outwards and one wall per footprint edge). roofs.py moved each roof onto a fitted plane while the walls kept their own LiDAR tops: gable ends were left open up to the ridge and slits ran under the eaves. 105 of 158 (Spa) and 163 of 203 (Mettet) buildings had open edges above the foot; none was closed at the foot.

Design: tools/footprints.py (clean, square within 0.4 m, ear clipping with courtyards), tools/straight_skeleton.py (wavefront events; a result is checked and refused when wrong), tools/building_shapes.py (roof shapes over one triangulation, LiDAR fit, shell = roof + a wall under every outline edge + floor, closed-solid check), tools/buildings.py (build from OSM areas, write into the world glb, audit CLI). roofs.py keeps roofing class and colour. tools/osm.py keeps multipolygon inner rings as holes.

Options considered: patching the old mesh (keeps the two sources of truth that caused the openings); a height function over the footprint for every shape (no true hips or valleys on L and T shapes); skeleton plus a shared-outline shell (chosen).

Measured (both tracks regenerated): closed solids 0/158 -> 158/158 (Spa), 0/203 -> 203/203 (Mettet); no fallback was needed. Roof shapes Spa: flat 75, gable 41, skillion 37, hip 5; Mettet: gable 119, flat 42, skillion 33, hip 9. Footprints squared: 100 of 158, 183 of 203, moved 0.06 m on average, 0.39 m at most. Skeleton succeeded on 360 of 361 footprints. Building triangles 38908 -> 4444 (Spa), 119985 -> 5440 (Mettet). GPU time at Spa's paddock, window + stereo and mirrors: 12.3 ms before, 12.2 ms after.

Format: roof UV 1 = distances to two roof edges (was vertex colour alpha); facade UV 1 y = the wall's length, UV 0 measured from the wall's corner and ground floor. Old packs need regenerating.

Not verified: no live drive into a wall (collision takes every non-ground triangle, a path this change does not touch). Still wrong: roofs under trees and footprints offset from the LiDAR fit poorly (misfit over 1 m on some halls); a long building stepping down a slope (Spa's old pits) gets one sloping roof; no roof:shape, height or courtyard exists in either extract, so those paths are covered by tests only; neighbours sharing a wall are squared apart by up to 0.4 m; roofs have no overhang.
<!-- SECTION:NOTES:END -->
