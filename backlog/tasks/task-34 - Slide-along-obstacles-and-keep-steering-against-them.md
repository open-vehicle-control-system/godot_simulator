---
id: TASK-34
title: Slide along obstacles and keep steering against them
status: Done
assignee: []
created_date: '2026-11-14 22:14'
labels: []
dependencies: []
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Against a wall the vehicle stopped dead and its turn was cut short with its move, so steering could not turn it while it touched anything: at speed, where the grip limit makes it run wide into barriers, it stuck to them and could not be steered away. It now slides along what it hits, keeping the share of its speed that runs along it, and steering always turns it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A scrape slides along the wall and the vehicle steers away from it
- [x] #2 A glancing hit keeps most of its speed; a head-on hit stops
- [x] #3 The vehicle never passes through the obstacle
<!-- AC:END -->
