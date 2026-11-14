---
id: TASK-28
title: Add screen-space indirect light and reflections
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 21:30'
labels: []
dependencies: []
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Evaluate SSIL, SSR (wet-looking surfaces, windows) and their cost across the three viewports; enable what pays for itself, configurable per track pack where it is a look choice.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Before/after captures at Spa and Mettet
- [x] #2 GPU cost per effect measured with the stereo pair on; only effects within budget are on by default
- [x] #3 The stereo cameras' images are as before
- [x] #4 A track pack sets the strength of the indirect light; pack_format.md says how
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured with the frame cap lifted (under it the GPU slows its clock), RX 7800 XT, 1080p window and the 1280 x 720 pair, GPU time of each viewport. Spa's heaviest view (ROS 880,363, yaw 123): window 7.10, left 3.37, right 3.37, total 13.84 ms.

SSIL on the three viewports, there: very low 14.40, low 14.32, medium 14.43, high 14.76 (all half size), medium full size 15.23 ms: +0.6 ms at medium, half of it the window. Elsewhere +0.6 (Spa pits 8.49 -> 9.07, Mettet 6.07 -> 6.63) to +0.8 ms (Spa forest 12.52 -> 13.30).
SSR: 32 or 64 steps half size 14.27 (+0.43), 64 steps full size 14.60 ms. Both, low SSIL and 32 steps: 14.67 ms. All within 16.7 ms.

What they draw. SSIL (radius 5 m, intensity 1): the seats under Spa's grandstand roof, the foot of walls, the underside of the vehicle and the cockpit get darker; open ground does not change. At intensity 3 the stand goes dark in bands. In the left stereo image it changes 0.2% (Mettet) to 5.9% (Spa pits) of the pixels by more than 4/255, the shade under the stand again, and draws outlines one pixel wide, up to 56/255, around trees and a house against a hill. SSR: nothing in the packs is wet or polished; it shows on the vehicle's paint and bonnet and barely on the facades' glass, and replaces the sky's sheen on grass verges seen at a grazing angle with a speckled reflection of the bank behind, in the window and in the left image (6.6% of its pixels by more than 8/255).

Decided: SSIL on, medium, half size, in the window only (the viewer's camera has its own Environment, TrackWorld.window_lighting; the world's, which the stereo cameras, the ground truth and the mirrors see, is as it was): +0.31 to 0.35 ms, 13.9 -> 14.2 ms at the heaviest view. The left image with and without it differs by 1/255 in 0.03% of its pixels at most, which is what two captures without it differ by. Its strength is the pack's look choice, track.indirect_light.strength (0 to 4, 1 by default, 0 for none); neither pack sets it. SSR off, and no pack field for it: no pack has a surface that would use one.

Captures 150 to 154 (window before/after: Spa pits, heaviest view, forest; Mettet chase and cockpit), 155 SSR at the pits, 156 SSR in the left image, 157 SSIL in the left image.
<!-- SECTION:NOTES:END -->
