---
id: TASK-6
title: Connect to the OVCS simulator link
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 08:58'
labels: []
dependencies:
  - TASK-2
  - TASK-5
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
simulator_link.gd: the TCP client that reconnects, applies drives, and sends state every physics step.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Against a test server speaking the OVCS side, a drive moves the vehicle and state packets report it in ROS frames
- [x] #2 With no drive for 0.5 s, or no connection, the vehicle is commanded to stop
- [x] #3 The client reconnects after losing the connection
<!-- AC:END -->
