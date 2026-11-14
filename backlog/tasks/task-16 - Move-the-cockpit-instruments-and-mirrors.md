---
id: TASK-16
title: Move the cockpit instruments and mirrors
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 13:38'
labels: []
dependencies:
  - TASK-9
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Speedometer, rev counter and steering wheel from the vehicle pack's Cockpit_* nodes and calibration, and working mirrors.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The cockpit gauges follow speed and the steering wheel the steering
- [x] #2 The speedometer and rev counter needles and the steering wheel turn by the vehicle pack's instruments: nodes, axes, dial, rpm scale and cap, gear ratio, steering ratio and lock
- [x] #3 The interior and door mirrors show what is behind, on the pack's mirror glass material, rendered only in the cockpit view
- [x] #4 A pack without instruments or mirrors loads with a still cockpit; one naming a node or material its model lacks, or values out of range, is refused by name
- [x] #5 Cockpit view at 1080p stays within the 60 fps GPU budget with the mirrors live
<!-- AC:END -->



## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Pack: vehicle.instruments (speedometer, rev_counter, steering_wheel) and vehicle.mirrors, read by InstrumentsSpec and MirrorsSpec. Pure angles in InstrumentScales; Instruments node turns the Cockpit_* parts from the vehicle's speed_m_s and steering_rad; Mirrors node gives each piece of glass a view looking back, live only when the Viewer's view sees mirrors. Considered true planar reflections from the driver's eye: not done, it depends on how a model's glass is aimed, which was not checked; the experiment's view looking back from the glass is what is brought back.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Instruments and mirrors come from the vehicle pack; tools/pack_experiment.py writes them from the experiment's ovcs1.json (steering wheel axis negated: pack axes are right-handed for a rising reading / steering left). --hold=KM_H,STEERING_DEG holds a speed and steering for screenshots of a moving vehicle. --screenshot now also reports the other viewports' GPU time. Measured at 1080p, cockpit view, Mettet, RX 7800 XT: 11.3 ms GPU per frame without mirrors (window 5.4 + stereo pair 5.9), 12.5 ms with (window 4.0 + stereo and three mirrors 8.5). Mirror views are lit without tone mapping, glow or SSAO and read as HDR so the window tone-maps them once. Not done: mirrors are a camera looking straight back from the glass, not a reflection from the driver's eye; gauges show the simulator's vehicle state, not what the VMS sends its cluster (the experiment's show_ovcs path needs link fields OVCS does not send).
<!-- SECTION:NOTES:END -->
