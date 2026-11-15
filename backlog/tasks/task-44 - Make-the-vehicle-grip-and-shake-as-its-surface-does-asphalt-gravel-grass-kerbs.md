---
id: TASK-44
title: >-
  Make the vehicle grip and shake as its surface does: asphalt, gravel, grass,
  kerbs
status: To Do
assignee: []
created_date: '2026-11-15 17:48'
labels:
  - vehicle
  - physics
dependencies: []
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Each wheel's contact knows its surface (the track's surfaces: road, kerb, gravel run-off, grass, terrain), from the ground layer or the material under it. Per surface: friction and slip stiffness (grass and gravel far lower grip, more slip), rolling resistance (gravel and grass drag), and roughness: a road-profile disturbance under each wheel (a height noise of the surface's amplitude and wavelength) so the suspension and the IMU shake on gravel, grass and kerbs, as the VMS and the stereo pair would feel. Surface values in the track pack, defaults in the simulator; weather can lower them.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each wheel reports or uses the surface under it
- [ ] #2 Grip, rolling resistance and roughness differ by surface (tested: stopping distance and IMU vibration on asphalt vs gravel vs grass)
- [ ] #3 A track pack can set its surfaces' values; the pack format documents them
<!-- AC:END -->
