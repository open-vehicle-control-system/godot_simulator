---
id: TASK-14
title: Port the town builder to tools/
status: To Do
assignee: []
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 11:23'
labels: []
dependencies:
  - TASK-12
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Build tiled town packs (terrain, streets, bridges, LiDAR roofs and trees).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 packs/tracks/braine builds from its recipe
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Streets follow docs/track_creation.md like the circuit: fitted edges, faithful continuous markings, surfaces from the photo, parked cars removed, and traffic lights and signs placed by the TASK-20 builder step.
<!-- SECTION:NOTES:END -->
