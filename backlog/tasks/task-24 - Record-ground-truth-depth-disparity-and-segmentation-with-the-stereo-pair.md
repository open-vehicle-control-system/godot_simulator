---
id: TASK-24
title: 'Record ground-truth depth, disparity and segmentation with the stereo pair'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 20:34'
labels: []
dependencies: []
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
For OVCS vision work: alongside each recorded stereo pair, the exact depth and disparity maps (from the depth buffer, in the left camera's frame, metres and pixels) and a semantic segmentation image (road, lane marking, kerb, vehicle, vegetation, building, sign, sky, terrain) rendered with label materials; classes and colours documented; costs measured.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Recorded pairs carry depth (metres), disparity (pixels, matching fx*baseline/depth) and segmentation images, documented in docs/stereo.md
- [x] #2 Disparity agrees with the stereo geometry, tested on a generated scene with known distances
- [x] #3 Segmentation classes come from what is drawn (surface, mesh kind), not hard-coded track names
- [x] #4 Real-time frame budget measured with ground truth off and on
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: a third camera at the left camera's place whose cull mask lacks render layer 20. Shaders read CAMERA_VISIBLE_LAYERS: the world's own shaders (terrain, far, impostor, canopy, sign, signal) emit their class for that camera; materials that are not the world's (rule surfaces roof, facade, seats, plain; sign posts; the vehicle) get a label pass (next_pass, render priority 1) whose triangles are empty for every other camera. A compute compositor effect (after the transparent pass) turns that camera's depth buffer and labels into three GPU textures: depth (R32F metres along the optical axis), disparity (R32F, fx*baseline/depth) and segmentation (RGBA8 class colours), read back asynchronously with the pair.

Options considered: label passes always on (doubles the vertex work of buildings in every viewport: refused, they are added only with --ground-truth through TrackSpec.labelled); reading labels before the transparent pass (trees are drawn in it: unlabelled); 16-bit PNG disparity (Godot's save_png writes 8 bits) and EXR (not in export builds): float32 .npy chosen, read by numpy and Nx.

A label is class*16 next to a mark of 1024: glass drawn over it dims both alike, so the ratio still gives the class, and a pixel without mark is unlabelled.

The recorder now asks for the frame about to be drawn and reads it back asynchronously; files are written one task each at high priority (low priority tasks share 30% of the pool: 9 pairs a second at 1280x720); a frame due while 32 files are being written is skipped and counted.

Measured (Spa, ovcs1 1280x720 pair at 15 Hz, RX 7800 XT, --hold=60,0): 60 frames a second with recording alone and with ground truth, no frame over 33 ms; GPU 12.5 ms a frame without, 11.7 to 14.9 ms with (run to run, other work on the GPU), worst frame 13-17 ms without, 13-20 ms with. Disparity equals fx*baseline/depth within 1.3e-4 px on recorded frames.

Tests: tests/test_segmentation.gd, test_numpy_file.gd, test_stereo_recorder.gd, test_stereo.gd (headless); tests/rendered/test_ground_truth.gd (windowed: walls at 4 m and 20 m, glass, sky; the right image's edge is shifted by the ground truth disparity). Captures: build/captures/171-173.
<!-- SECTION:NOTES:END -->
