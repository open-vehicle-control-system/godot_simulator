---
id: TASK-46
title: Drive a track's centre line at a set speed (--follow-route)
status: To Do
assignee: []
created_date: '2026-11-15 18:20'
labels:
  - vehicle
  - tools
dependencies: []
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
--hold keeps a fixed steering, so on a circuit the vehicle leaves the track. A track pack gains an optional route: the track's centre line as a polyline in its frame (ROS), closed for a circuit, written by the builders from OpenStreetMap's raceway (Spa, Mettet) or the generated track (default_track). --follow-route=KM_H drives it with a pure-pursuit steering (look-ahead growing with speed) and SpeedControl, lowering the speed where the line's curvature asks for more than the tyres hold. Gives repeatable benchmark laps (TASK-45's measurements at the same places every time), screenshots and recordings on the track, and a reference path for OVCS checks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A track pack may carry a route; the pack format documents it; the builders write one for Spa, Mettet and the default track
- [ ] #2 --follow-route=KM_H laps the track staying within a metre of the centre line at moderate speed (tested on the default track)
- [ ] #3 --timing over a --follow-route lap reports per-corner frame times
<!-- AC:END -->
