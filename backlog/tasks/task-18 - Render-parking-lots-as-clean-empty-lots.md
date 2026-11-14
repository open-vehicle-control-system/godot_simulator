---
id: TASK-18
title: 'Render parking lots as clean, empty lots'
status: In Progress
assignee: []
created_date: '2026-11-14 10:58'
updated_date: '2026-11-14 12:07'
labels: []
dependencies:
  - TASK-11
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Find lots from OSM (amenity=parking, parking aisles) confirmed by the orthophoto; infer the surface and a car-free median colour; infer the bay grid (orientation, bay width and depth, aisles) from the photo's line mask and draw regular bay lines and lot edges in the simulator. Rules: docs/track_creation.md, Parking lots and secondary roads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The bay grid fit is tested in Python on synthetic line masks
- [x] #2 A Mettet and a Spa car park render empty, with regular bay lines, before/after captures
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: lots from OSM amenity=parking, confirmed by the photo; per-edge outline fit; commonest-luminance colour; bay grid from the thin-paint mask (direction, comb over bay widths, rows by rhythm). Drawn by the terrain shader from a lots map (lot number + distance to edge) and lots.json. Rules and starting values: docs/track_creation.md. Captures: build/captures/25,26,28 (before), 32,33,35 (after).

Later: rows found one by one from 1.5 m of rhythmic paint; terrain levelled inside fitted outlines (smooth_terrain.levelled); yards (cluttered paved ground no map calls a lot) drawn car-free. Captures 39-45.
<!-- SECTION:NOTES:END -->
