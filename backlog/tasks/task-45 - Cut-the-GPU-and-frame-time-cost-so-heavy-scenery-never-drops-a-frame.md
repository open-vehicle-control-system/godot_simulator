---
id: TASK-45
title: Cut the GPU and frame-time cost so heavy scenery never drops a frame
status: To Do
assignee: []
created_date: '2026-11-15 17:50'
labels:
  - performance
  - rendering
dependencies: []
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Measured on Spa (local pack), default car at 120 km/h, RX 7800 XT, --timing: GPU 12.0-12.4 ms a frame of the 16.7 ms budget; worst frames 17-23 ms every 5 s (missed 60 Hz deadlines, felt as lag) while the GPU's worst is 13-14 ms, so the spikes are likely main-thread work (tile builds, uploads); 2,300-5,100 draw calls and 4.4-6.3 M primitives a frame. Mettet screenshot: window 5.1 ms GPU, the 5 other viewports (stereo pair, mirrors) 4.5 ms.

Candidates, to profile before choosing (RenderDoc / Godot's GPU profiler):
- Other viewports: draw the mirrors only in views that show them and at lower resolution/rate; the stereo pair only at its rate (15 Hz) and only when sent or recorded, not every frame.
- Shadows: 8192 directional map with soft filter quality 3; fewer/shorter cascades, lower resolution, cheaper filter; static geometry shadows cached.
- Draw calls: merge each tile's static meshes per material, more MultiMesh, visibility ranges / HLOD for far tiles.
- Primitives: stronger LODs and an earlier switch to impostors and far terrain.
- Screen-space effects: SSIL and MSAA cost vs quality; FSR (--upscale) as default where it holds.
- Frame spikes: spread tile building and GPU uploads over frames; find which part the 17-23 ms frames spend.
The stereo pair's images and ground truth must not change (rendered tests), and --record stays identical.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A profile names what the GPU and the main thread spend a frame on, on Spa
- [ ] #2 On Spa at speed: no frame over 16.7 ms in a lap, GPU time under 10 ms
- [ ] #3 The stereo pair, its ground truth and --record are unchanged (rendered tests pass)
<!-- AC:END -->
