---
id: TASK-10
title: Package the experiments' tracks and vehicles as local packs
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 09:09'
labels: []
dependencies:
  - TASK-3
  - TASK-4
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A tool that turns the Godot experiment's outputs (Spa, Mettet, OVCS Mini, OVCS1) into packs, for local use until the builders are ported. The OVCS1 body is a third-party mod: its pack is local only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Mettet and Spa load as track packs and OVCS Mini and OVCS1 as vehicle packs
- [x] #2 The OVCS1 pack's licence says it may not be redistributed
<!-- AC:END -->
