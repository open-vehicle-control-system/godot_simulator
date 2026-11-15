---
id: TASK-37
title: 'Use the Generic Sedan as the default car, credited'
status: To Do
assignee: []
created_date: '2026-11-15 09:35'
labels: []
dependencies:
  - TASK-36
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace default_car's placeholder box with "Generic Sedan Car" by Márcio Meireles (MMC Works), https://sketchfab.com/3d-models/generic-sedan-car-58c33766470d46e7b2aed542650494e5, CC BY 4.0. Source files (not committed) in build/sedan_src/ (small.glb 16.7 MB, full.glb 44.8 MB), copied from the user's Downloads. Map its named parts to the simulator's vehicle nodes (Body, Wheel pivots from the wheel objects, Cockpit_* from column-wheel and dashboard parts, the mirror material), set dimensions, driver eye and stereo mount from the model, recompress textures to DDS, keep the committed pack a few MB. Attribution in pack.json (licence CC-BY-4.0), an ATTRIBUTION.md beside the model, README credits; CLAUDE.md, CODE_STYLING.md and the design doc state the one exception to the generated-CC0 defaults.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 default_car shows the sedan, wheels turning and steering, cockpit view from the driver's seat, stereo pair unobstructed by the bonnet
- [ ] #2 The credit line, licence and modifications are in pack.json, ATTRIBUTION.md beside the model, and README.md
- [ ] #3 The committed pack stays small (target under 10 MB) and the builder regenerates it from the source model
- [ ] #4 Before/after captures: chase, side, cockpit, stereo pair
<!-- AC:END -->
