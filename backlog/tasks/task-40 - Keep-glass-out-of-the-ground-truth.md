---
id: TASK-40
title: Keep glass out of the ground truth
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15 10:57'
updated_date: '2026-11-15 11:04'
labels: []
dependencies: []
priority: high
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With the default car, the recorded segmentation labels the road seen through the windscreen as vehicle, with near-zero depth and saturated disparity. The model's glass is glTF BLEND, which Godot's importer makes TRANSPARENCY_ALPHA_DEPTH_PRE_PASS; Segmentation.label_under only skips TRANSPARENCY_ALPHA, so the glass gets the vehicle label pass, which writes its depth (depth_draw_always) over what is behind.
Also: --record with --ground-truth quits at once without frames.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No label pass is attached to an alpha-blended material, whatever its transparency mode (ALPHA, ALPHA_DEPTH_PRE_PASS); opaque surfaces keep a label pass that writes depth
- [x] #2 A rendered test with a camera behind a near transparent pane gets the segmentation, depth and disparity of the surface behind it, and fails before the fix
- [x] #3 The default track recorded with the default car labels the road through the windscreen as road, with the road's depth
- [x] #4 --record with --ground-truth is handled with a clear outcome, documented in README.md and docs/stereo.md
- [x] #5 Lint and headless and rendered tests pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Treat every alpha-blended BaseMaterial3D (ALPHA and ALPHA_DEPTH_PRE_PASS) as seen through in Segmentation; test first (headless label_under, rendered pane behind the camera); explain or refuse --record with --ground-truth; re-record the default track and regenerate docs/images/ground_truth.jpg.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause confirmed: Godot's GLTFDocument imports BLEND as TRANSPARENCY_ALPHA_DEPTH_PRE_PASS (probed: Glass_-_Clear, Glass_ext, Glass_ext-tinted, Glass_-_Red, both honeycomb grilles), so label_under gave the glass the vehicle label pass, which writes depth. The depth pre-pass itself writes depth only where alpha >= 0.99, so the panes write none. Fix: Segmentation.BLENDED (ALPHA, ALPHA_DEPTH_PRE_PASS) are seen through; scissor/hash cut-outs keep their label. Rendered test before the fix: segmentation vehicle, depth 0.297 m, disparity 107.6 px through the windscreen; after: building, 4.0 m, 8.0 px.
--record with --ground-truth was refused by SimulatorOptions ("--ground-truth ... needs --stereo-record", printed on stderr, window.avi left by movie mode); now accepted as a no-op.
Default track frame 29, lower half: before vehicle 92.0 %, terrain 7.2 %, vegetation 0.8 %, depth median 0.16 m; after road 36.8 %, terrain 24.6 %, vehicle (bonnet) 36.7 %, lane_marking 1.1 %, vegetation 0.8 %, depth median 4.87 m, disparity max 128 px (was 1536).
<!-- SECTION:NOTES:END -->
