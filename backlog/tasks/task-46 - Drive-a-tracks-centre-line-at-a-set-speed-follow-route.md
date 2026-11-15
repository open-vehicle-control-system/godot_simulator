---
id: TASK-46
title: Drive a track's centre line at a set speed (--follow-route)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15 18:20'
updated_date: '2026-11-15 19:16'
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
- [x] #1 A track pack may carry a route; the pack format documents it; the builders write one for Spa, Mettet and the default track
- [x] #2 --follow-route=KM_H laps the track staying within a metre of the centre line at moderate speed (tested on the default track)
- [x] #3 --timing over a --follow-route lap reports per-corner frame times
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
track.route names route.json (points_m in the track's frame, closed); Route (pure) measures length, nearest point (searched near the last one), curvature over +-6 m. --follow-route=KM_H: RouteDriver steers by pure pursuit from the rear axle to the line 0.6 s ahead (5 m at least, 0.8 s cut corners by 1.08 m) and slows so corners within braking distance take 60 % of the grip, braking at 2.5 m/s^2; SpeedControl drives. Builders write route.json: default_track (728 points, 1,454 m), pack_experiment from the experiment's track.json (Spa 4,048 points, 6,996 m; Mettet 1,318, 2,264 m). On the default track at 60 km/h the rear axle stays within 1 m of the line (test). --timing reports where along the route the GPU's worst frame came (km) instead of a corner name: the pack names no corners.
<!-- SECTION:NOTES:END -->
