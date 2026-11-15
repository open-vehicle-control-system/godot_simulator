---
id: TASK-39
title: Describe a vehicle's powertrain and selected gear in its pack
status: To Do
assignee: []
created_date: '2026-11-15 10:45'
labels: []
dependencies:
  - TASK-38
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Keyboard driving accelerates every vehicle at a flat 3 m/s^2 to 180 km/h, and the cockpit's rev counter uses a first-gear ratio hard-coded into OVCS1's instruments. Add vehicle.powertrain to the vehicle pack: motor (max power W, max torque Nm, max rpm), gearbox ratios (all gears) and final drive, the selected gear, driven axle (already in dynamics: one source of truth). Keyboard acceleration comes from torque x overall ratio / wheel radius, capped by power and the driven axle's grip, with drag and rolling resistance; top speed from the rpm limit or power; the rev counter from wheel speed through the selected gear. --set=vehicle.powertrain.gear=N selects another gear for a run. OVCS1: Nissan Leaf AZE0 motor (80 kW, 254 Nm, ~10,390 rpm), the stock Polo 9N3 gearbox (find its ratios and final drive; first gear x final drive should come to the 8.1938 the cockpit uses), first gear today, third considered; battery over the rear axle, so ~48% front is plausible: record the reasoning. Under OVCS, OVCS's simulated hardware has its own motor/wheel ratio (Ovcs1.Simulation in the OVCS repo): the selected gear must match it; document that.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 vehicle.powertrain is documented in pack_format.md, validated, and overridable with --set
- [ ] #2 Keyboard acceleration and top speed follow the selected gear, power and grip (tested); OVCS1 in first gear tops out near the motor's rpm limit
- [ ] #3 The rev counter reads motor rpm through the selected gear (tested)
- [ ] #4 OVCS1 and default_car carry sourced values; the OVCS-side ratio caveat is documented
<!-- AC:END -->
