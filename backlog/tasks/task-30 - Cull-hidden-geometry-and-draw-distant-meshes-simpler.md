---
id: TASK-30
title: Cull hidden geometry and draw distant meshes simpler
status: To Do
assignee: []
created_date: '2026-11-14 19:59'
labels: []
dependencies:
  - TASK-23
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Occlusion culling (occluders from terrain and buildings, built per tile) and level-of-detail meshes for buildings and terrain at distance, to cut the remaining terrain and shadow cost.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 GPU time at Spa's heaviest views measured before and after
- [ ] #2 No popping or holes at LOD transitions in captures
<!-- AC:END -->
