---
id: TASK-8
title: 'Record stereo pairs, poses and calibration'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 09:02'
labels: []
dependencies:
  - TASK-7
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
--stereo-record=DIR writes left/right PNGs, poses.csv and calib.json, for offline vision work.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A recording holds matching left and right frames, a pose per frame and calib.json with the intrinsics and baseline
<!-- AC:END -->
