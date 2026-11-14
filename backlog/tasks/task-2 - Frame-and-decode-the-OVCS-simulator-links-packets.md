---
id: TASK-2
title: Frame and decode the OVCS simulator link's packets
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 08:53'
labels: []
dependencies:
  - TASK-1
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
link_protocol.gd, pure: the 32-bit length framing, encoding state and image packets and decoding drive, byte-compatible with OVCS SimulatorCore.Link.Protocol, and the Godot to ROS frame mapping.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Encoded state and image packets carry the fields OVCS decodes
- [x] #2 A drive packet decodes to speed and steering; a malformed one to an error naming why
- [x] #3 Packets split across reads or several in one read are framed correctly
<!-- AC:END -->
