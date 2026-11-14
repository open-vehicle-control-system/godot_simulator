---
id: TASK-29
title: Upscale the main window with FSR 2
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 21:44'
labels: []
dependencies: []
ordinal: 29000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Optional FSR 2 upscaling for the main window only (the stereo cameras stay native for vision), as an option, with quality and cost measured.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The stereo images are unchanged with upscaling on
- [x] #2 Main-window GPU time and image quality compared at each FSR quality level
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Option --upscale=quality|balanced|performance: the window's 3D drawn at 67, 59 or 50% of its width and height and upscaled by FSR 2 (view/upscaling.gd sets the root viewport only). Off unless asked.

Measured with the frame cap lifted, RX 7800 XT, 1080p window and the 1280 x 720 pair, Spa's heaviest view (ROS 880,363), GPU time of the window / of the three viewports: native 7.40 / 14.15 ms, quality 4.99 / 11.70, balanced 4.52 / 11.18, performance 3.91 / 10.55. FSR 2 at full size (anti-aliasing only) costs 0.6 ms more than native, FSR 1 and bilinear at 67% 4.57 and 4.52 ms: FSR 2's own pass is 0.5 ms.

Quality: standing still, the picture is softer at every level (29.4, 29.6 and 29.0 dB against native, most of it the ground's grain) and cloud edges comb at balanced and performance. Driving at 60 km/h the lettering on the vehicle breaks up at quality and more at performance; edges of the scenery hold. Captures 158 (crops, native and the three levels), 159 (driving: native, quality, performance), 160 (the window at quality).

The stereo images: the pair's viewports keep their size, bilinear mode and scale 1 (tested). Left image read from separate runs without the option and with each level, at a view with no tree (Spa spawn, yaw 121.5): the same file, byte for byte (sha256 052fbc0d97fa25f4...), eight captures. With trees in view the left image is not the same from one frame to the next without any upscaling: 230 to 290 pixels on the trees' cards differ by 1/255 (two native captures: 272 and 289; native against quality, balanced, performance: 261, 247, 230). Only the left image was hashed; the right is drawn the same way.

Found on the way: that flicker of the tree cards, in every viewport, cause not looked for (the impostor shader's alpha antialiasing or its backlight are candidates).
<!-- SECTION:NOTES:END -->
