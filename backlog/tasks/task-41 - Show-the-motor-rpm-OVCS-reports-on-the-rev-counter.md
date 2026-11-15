---
id: TASK-41
title: Show the motor rpm OVCS reports on the rev counter
status: Done
assignee:
  - '@mlainez'
created_date: '2026-11-15 12:42'
updated_date: '2026-11-15 12:50'
labels:
  - link
dependencies: []
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The rev counter shows the motor speed the wheels imply through the pack's selected gear, which matches OVCS only as long as the pack and OVCS's simulated hardware agree on the ratio. OVCS now sends the motor's rpm as its motor controller reports it, in a new link message, instruments (header field motor_rpm, SimulatorCore.Link.Protocol in OVCS).

Design: LinkProtocol decodes instruments; SimulatorLink keeps the last motor_rpm with its arrival time and reports it while under 0.5 s old (INSTRUMENTS_TIMEOUT_S), 0 otherwise and without a connection; Instruments turns the rev counter to its magnitude, and rests it at 0 without a link (--keyboard, --hold). No computed fallback: a rev counter that sometimes shows OVCS's rpm and sometimes the simulator's own estimate would hide a vehicle that stopped reporting. The powertrain still drives the vehicle under --keyboard; Powertrain.motor_rpm, used only by the rev counter, goes. Unknown message types are still dropped with a warning.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 LinkProtocol decodes an instruments packet OVCS's encoder produced, and rejects one without a numeric motor_rpm
- [x] #2 SimulatorLink reports the last motor rpm while under 0.5 s old, and 0 before any, once stale and after a disconnection
- [x] #3 The rev counter shows the reported rpm's magnitude, and 0 without one however fast the vehicle goes
- [x] #4 docs/simulator_link.md, docs/architecture.md and docs/pack_format.md describe it
<!-- AC:END -->
