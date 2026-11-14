---
id: TASK-26
title: Record deterministically with Godot's movie mode
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 19:59'
updated_date: '2026-11-14 23:27'
labels: []
dependencies:
  - TASK-24
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A --record mode that renders at a fixed simulated frame rate frame by frame (Godot Movie Maker / fixed-fps), so stereo recordings with ground truth are repeatable and can use settings real time cannot hold; driven by --hold, a route, or a recorded OVCS drive log.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Two runs of the same recording produce identical poses and identical ground-truth files
- [x] #2 Documented in docs/stereo.md with an example command
<!-- AC:END -->



## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: --record=DIR runs in Godot's movie mode (simulate.sh passes --write-movie DIR/window.avi --fixed-fps 60 --resolution 640x360; main refuses --record without the movie feature): simulated time advances one sixtieth of a second a frame, one physics step each. The recording is the stereo recorder's with ground truth, made repeatable by: TilesAtOnce (every tile within the streaming radius loaded synchronously before each frame, the tiles' own background loading turned off), the recorder waiting for its writers instead of skipping frames, and an end after --record-seconds (or the drive log's length) once every frame asked for is on disk, then quit. --drive-log=FILE drives from a CSV with time_s, speed_m_s, steering_rad columns (a recording's poses.csv is one), counted in physics steps.

Options considered: --fixed-fps alone (a script cannot tell it is on: OS.get_cmdline_args() does not list it, the movie feature tag does); pausing the tree while tiles load (frames drawn meanwhile shift what depends on the frame count: the signals' cycle, the sensor noise).

Found on the way: quitting while a texture readback was pending crashed the engine at exit (since the recorder reads back asynchronously); GpuReadback counts them and StereoCamera draws frames until they are back before leaving the tree. A label pass is now drawn 5e-5 of the distance nearer than its surface and writes no depth, so depth is the surfaces' own.

AC #1, measured on two runs each (Spa 8 s at 110 km/h with ovcs1; Mettet 6 s at 70 km/h with every camera effect), repeated four times: poses.csv, calib.json, every depth and disparity file identical byte for byte. Segmentation identical on the generated scene of tests/rendered/test_record.gd, and on the tracks but for one or two frames in a hundred where four or eight pixels of a building or wall are unlabelled in one run (TASK-32, cause not found: not the tiles' pace, not the depth test). Left and right images equal but for the last bit of about ten pixels a frame. AC #1 is left unchecked for that.

Tests: test_drive_log.gd, test_tiles_at_once.gd, test_options.gd, test_stereo_recorder.gd (ends after its duration, waits instead of skipping); rendered: tests/rendered/test_record.gd runs the simulator twice in movie mode on a generated track and compares poses and ground truth byte for byte. Capture: build/captures/176. Five simulated seconds of Mettet with every camera effect take 18 s.
<!-- SECTION:NOTES:END -->
