---
id: TASK-5
title: Follow the drive OVCS commands
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 08:57'
labels: []
dependencies:
  - TASK-4
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vehicle moves kinematically at the commanded speed and steering (bicycle model about the rear axle, kept on the ground by a ray) and keeps an odometer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 At a constant speed and steering the vehicle traces the bicycle model circle
- [x] #2 The odometer counts the signed distance rolled
<!-- AC:END -->
