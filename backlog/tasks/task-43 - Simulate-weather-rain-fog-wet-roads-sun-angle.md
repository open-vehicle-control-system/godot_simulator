---
id: TASK-43
title: 'Simulate weather: rain, fog, wet roads, sun angle'
status: To Do
assignee: []
created_date: '2026-11-15 17:48'
labels:
  - weather
  - rendering
dependencies: []
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Test OVCS's vision and the vehicle under different weather. A weather setting per run (--weather=..., and over the link later if OVCS wants to script it): clear, overcast, rain, fog, maybe snow; time of day / sun angle. Rendering: sky and sun, fog density, rain particles and drops on the stereo cameras' lens, wet road shading (darker, reflective, puddles). Physics: tyre friction falls on wet roads (and snow/ice), so it ties into per-surface grip. Ground truth stays exact under weather; recordings stay repeatable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A run can choose its weather and time of day
- [ ] #2 Rain and fog show in the window and the stereo pair, the lens catches drops
- [ ] #3 Wet roads look wet and grip less
- [ ] #4 --record stays identical run to run under any weather
<!-- AC:END -->
