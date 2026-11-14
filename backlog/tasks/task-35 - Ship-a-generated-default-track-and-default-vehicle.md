---
id: TASK-35
title: Ship a generated default track and default vehicle
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 23:01'
updated_date: '2026-11-14 23:24'
labels: []
dependencies: []
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The simulator does nothing without --track and --vehicle, and every real pack is built from local data (and OVCS1 cannot be redistributed). Add a default track (a small test circuit, ~1.5 km on gently rolling ground, asphalt with edge lines and kerbs, grass, run-off, a few buildings, trees and signs, in the normal tiled pack format) and a default vehicle (a generic compact car of plausible geometry with a stereo pair), both generated from code by a builder in tools/ with no external data, CC0. ./simulate.sh without --track/--vehicle uses them, generating them on first run when missing; nothing binary is committed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A clean clone runs ./simulate.sh with no options and drives the default track with the default vehicle (--keyboard)
- [x] #2 Both packs are generated from code alone, deterministically, licensed CC0, and pass the pack validation
- [x] #3 The default track uses the same builders, format and shaders as the real tracks (tiles, surfaces, lines, kerbs, buildings, trees, signs)
- [x] #4 Headless tests can use the default packs; CLAUDE.md and the design doc state the bundled-defaults exception
<!-- AC:END -->
