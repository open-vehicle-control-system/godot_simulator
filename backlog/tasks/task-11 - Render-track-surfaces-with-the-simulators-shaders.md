---
id: TASK-11
title: Render track surfaces with the simulator's shaders
status: In Progress
assignee: []
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 10:55'
labels: []
dependencies:
  - TASK-10
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Materials naming a simulator surface (road with markings and kerbs, splat terrain, facades, impostor trees) render with the simulator's shaders and the pack's textures.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 pack_format.md lists each surface and the textures and data it takes
- [ ] #2 Spa renders as in the experiment
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Surfaces: terrain (8 photo-coloured layers by surface map; road lines, kerbs and rubber from a track map and a road lines image, drawn on road mesh and terrain alike), roof, facade, plain, seats; tree impostors; sun and sky from the pack; ACES, fog, SSAO. Pack format: track.sun, track.ground (layers, slope_layer, photo_grade, road), track.surfaces, track.trees (docs/pack_format.md). Builders: tools/track_surfaces.py + ground_classes.py (orthophoto classification, fitted road edges, kerb segments, racing line), tools/smooth_terrain.py (welded, gap-filled, low-passed terrain), tools/fetch_textures.py (CC0 sets), wired into tools/pack_experiment.py. New options --spawn and --screenshot. Measured 5.5-7.3 ms GPU per frame at 1080p on an RX 7800 XT (Mettet and Spa). Open: 3D grass, better broadleaf impostors, OSM areas in the classification, photo-baked shadows and parked cars, kerb colours other than red and white. AC 2 awaits the user's review of build/captures.

Roofs: tools/roofs.py rebuilds each building's roof in the pack's world.glb (flat plane or gable where it fits, LiDAR shape otherwise), classifies its roofing from photo colour and shape, and stores one albedo per roof in vertex colours; the roof surface draws a roofing set along the eave, tinted. Forest floor only under closed canopy; rough grey ground is soil. New option --eye.
<!-- SECTION:NOTES:END -->
