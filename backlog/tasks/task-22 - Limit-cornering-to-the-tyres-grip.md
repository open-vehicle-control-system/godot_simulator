---
id: TASK-22
title: Limit cornering to the tyres' grip
status: Done
assignee: []
created_date: '2026-11-14 19:17'
labels: []
dependencies: []
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The kinematic bicycle model turned as tight as the steering asked at any speed: at 180 km/h the keyboard's lock asked for about 8 g. The vehicle now never corners harder than the pack's max_lateral_acceleration_m_s2; steered beyond it, it runs wide, and its yaw rate and IMU show it, in keyboard and OVCS modes alike.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The vehicle never corners harder than its pack's lateral grip
- [x] #2 Steered beyond the grip, the wheels stay turned and the vehicle runs wide
- [x] #3 A vehicle pack without a positive grip is refused
<!-- AC:END -->
