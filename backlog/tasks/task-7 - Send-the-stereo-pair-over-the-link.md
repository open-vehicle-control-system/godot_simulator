---
id: TASK-7
title: Send the stereo pair over the link
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 09:01'
labels: []
dependencies:
  - TASK-6
ordinal: 7000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A stereo camera of two parallel pinhole cameras on the vehicle pack's mount and optics; pairs are JPEG-encoded off the main thread and sent at the camera rate.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Left and right image packets arrive at the configured rate with one timestamp per pair
- [x] #2 The intrinsics follow from resolution and horizontal field of view; the pair is rectified
<!-- AC:END -->
