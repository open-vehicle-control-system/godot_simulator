---
id: TASK-3
title: Load vehicle packs
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 08:55'
labels: []
dependencies:
  - TASK-1
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Find packs on the search path by id, validate pack.json, and build the vehicle from vehicle.glb (Body, Wheel, Cockpit_*) or a box and cylinders without one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A vehicle pack loads by id from a --packs directory
- [x] #2 A missing or malformed field fails loading with a message naming the pack and field
- [x] #3 Two packs with one id are an error
<!-- AC:END -->
