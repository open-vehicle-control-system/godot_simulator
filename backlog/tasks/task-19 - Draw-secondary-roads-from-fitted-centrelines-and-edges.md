---
id: TASK-19
title: Draw secondary roads from fitted centrelines and edges
status: In Progress
assignee: []
created_date: '2026-11-14 10:58'
updated_date: '2026-11-14 12:07'
labels: []
dependencies:
  - TASK-11
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
For OSM highway ways around a track: fit centreline and smooth edges from the photo as for the track (tools/track_surfaces.py fit_edge), consistent width per stretch, gaps at junctions; edge and dashed centre lines where the photo shows them; surface layer from the photo. Needs the track map and road lines image generalised from one closed lap to several open roads. Rules: docs/track_creation.md, Parking lots and secondary roads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Open-road fitting is tested in Python
- [x] #2 A secondary road at Mettet and at Spa renders with clean edges and lines, before/after captures
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: OSM highway ways chained into roads, surveyed per metre: paved span, open-road edge fit (fit_open_edge), centre shift, width per stretch, lane colours; markings from paint masks in road coordinates (lines at any offset, Belgian dash standards, crossings, stop lines before junctions). Road map generalised to 20-bit along / 12-bit right for the lap and for many open roads; banded lines image. Takes a road network and an area, not a lap. Captures: build/captures/27,29 (before), 34,36 (after).

Later: double lines (paint over 60 cm wide). Not drawn: arrows, hatched areas, give-way teeth (not readable at 25 cm per pixel). Capture 46.
<!-- SECTION:NOTES:END -->
