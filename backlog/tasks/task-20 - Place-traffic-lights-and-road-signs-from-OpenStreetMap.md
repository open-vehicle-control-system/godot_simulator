---
id: TASK-20
title: Place traffic lights and road signs from OpenStreetMap
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 11:18'
updated_date: '2026-11-14 13:09'
labels: []
dependencies:
  - TASK-19
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Place the traffic lights, stop and give-way signs, crossings and tagged traffic signs (highway=traffic_signals, stop, give_way, crossing, traffic_sign=*, maxspeed) found in OSM around a track, at the roadside the way the region's conventions put them (Belgium for the Wallonia tracks: Vienna-convention sign designs, mounting heights, offsets from the carriageway, signal heads). Sign faces only from redistributable sources (public-domain designs or drawn by the builder); models simple and procedural. Rules: docs/track_creation.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OSM signal and sign nodes are mapped to the road side and facing direction, tested in Python
- [x] #2 Speed limit, stop, give-way and crossing signs the data implies are derived, and every placed sign says tagged or derived
- [x] #3 Signs and lights follow Belgian designs and placement, before/after captures at Mettet and Spa
- [x] #4 Every post and pole collides, in one physics body, tested in GDScript
- [x] #5 Every sign face's source and licence is in the pack's attribution
- [x] #6 No tree, sign or pole stands on the lap, a surveyed road, a lot or a yard, tested in Python
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Scope: every public road: the streets of town maps (Braine-l'Alleud, TASK-14) and the roads around circuits. A circuit itself and its service roads only get what OSM tags on them.

Built: tools/road_signs.py (tagged and derived signs, Belgian placement, markings made to agree), tools/sign_faces.py (faces drawn from shapes: B1, B5, B9, C1, C3, C43[n], D5, F49), tools/drivable.py (no tree, sign or pole on driven ground), osm.py reads tagged nodes, secondary_roads split into survey_area / lay / write so signs can adjust markings before the lines are written. Simulator: packs/signs_spec.gd, world/road_signs.gd (a MultiMesh per face, one of posts, one of signal heads), world/post_bodies.gd (one physics body), shaders sign and signal; track.signs in docs/pack_format.md; conventions and values in docs/track_creation.md.

Conventions (arrete ministeriel 11 Oct 1976, Wallonia's consolidated text, read on wallex.wallonie.be): right of the carriageway; plate's near side at least 0.5 m from the edge outside built-up areas (0.3 m inside); lower edge 2.2 m where people walk, 1 m on rural verges since 2020 (1.5 m used, as standing signs are); B1/B5 at their line; B1 with D5 at every roundabout entry; lens at least 0.18 m (0.2 m used). Plate sizes (0.7 m, square 0.6 m) are the common series: the rule's table is an image I could not read.

Public roads are surveyed out to 450 m from the lap (service roads 250 m): Mettet's four give-way nodes are 343 to 424 m out.

Results: Mettet 3 tagged B1 (the fourth has no free ground: its arm overlaps the next), 7 derived F49, 138 of 2845 trees dropped. Spa 0 tagged (its stop is on a cycleway and its crossing north of the terrain), derived 12 C43, 2 B1 + 2 D5, 32 F49; 582 of 38655 trees dropped. No traffic_signals in either extract: signals are covered by tests and a demo capture only.

Open: a give-way sign without a drawn line gets no give-way line (line drawing is being reworked elsewhere; kinds 3 and 4 and the shader's triangles exist). F49 follows every crossing the road builder draws, so a false crossing gives a false sign. Roundabout entries on short one-way slip roads are not surveyed and get no sign. Left-side C43 repeats are placed on every road, which the rule only asks for on one-ways.

Corrected after review, from the regulation's text (AM 11 Oct 1976, version in force 2014-2020 read as text; art. 1.3 as amended 30 June 2020): lower edge 1 m on rural verges, 2.2 m where people walk; plates 0.9 m triangles, 0.9 m octagon, 0.7 m discs outside built-up areas, 0.7 / 0.9 / 0.6 m inside, F49 0.6 m; C43 repeated on the left of one-ways only. Packs not regenerated with these values yet.
<!-- SECTION:NOTES:END -->
