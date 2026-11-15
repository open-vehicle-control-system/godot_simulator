---
id: TASK-39
title: Describe a vehicle's powertrain and selected gear in its pack
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15 10:45'
updated_date: '2026-11-15 11:41'
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
- [x] #1 vehicle.powertrain is documented in pack_format.md, validated, and overridable with --set
- [x] #2 Keyboard acceleration and top speed follow the selected gear, power and grip (tested); OVCS1 in first gear tops out near the motor's rpm limit
- [x] #3 The rev counter reads motor rpm through the selected gear (tested)
- [x] #4 OVCS1 and default_car carry sourced values; the OVCS-side ratio caveat is documented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Design

`vehicle.powertrain` (PowertrainSpec): motor (max power, max torque, max rpm), every gear's ratio, final drive, `gear` (1-based, or `"automatic"`), driveline efficiency, rolling resistance coefficient, drag area. The driven axle stays `dynamics.driven_axle`. Required in every vehicle pack. The rev counter's `motor_to_wheel_ratio` is gone: it reads the motor through the gear in use (`Powertrain.motor_rpm`).

Keyboard driving (`Powertrain`, pure): full torque until power takes over, then power, nothing past the rpm limit; capped by the driven axle's grip at the load accelerating leaves on it (`DynamicBicycle.traction_limit_n`, same tyre model, so the friction circle is never asked for more than the axle holds going straight); minus drag (rho 1.2) and rolling resistance; the motor, gearbox and wheels add to the mass the motor moves (Gillespie eq. 2-11: 1.04 + 0.0025 N^2), not to what the tyres push when grip-limited. Coasting: drag and rolling only. Braking (8 m/s^2) and reverse (3 m/s^2, 4 m/s) unchanged. `"automatic"` picks the gear with the most full-throttle force at the speed, the highest on a tie: simple, stateless, the rev counter uses the same function.

## Values and sources

OVCS1
- Motor: Nissan Leaf AZE0 EM57, 80 kW, 254 Nm up to 3,008 rpm, 10,500 rpm max (Argonne National Laboratory 2013 Leaf test summary; Wikipedia "Nissan EM motor" also gives 10,500 rpm for the EM57; the 10,390 rpm in the task description is the earlier EM61's).
- Gearbox: Polo 9N 1.4 TDI (55 kW) 02R, code letters HGW (from 04.04), VW workshop manual "5-speed manual gearbox 02R: code letters, allocation, gearbox ratios": 3.300 / 1.944 / 1.308 / 0.971 / 0.756, final drive 3.389 (61:18). HGY has 3.647. OVCS1's own code letters (on the case) should confirm.
- DISCREPANCY: first gear x final drive = 11.18, not 8.1938. 8.1938 is the Leaf's own single reduction gear, which the cockpit (carla tools/build_car_ac.py LEAF_REDUCTION) and OVCS's `Ovcs1.Simulation` (`@reduction_ratio 8.1938`) use. With the Polo box in first, OVCS's simulation should use 11.18 (or the selected gear's overall ratio), or the cluster and the measured speed disagree.
- Drag area 0.67: Cd 0.32 (published for the 9N) x 2.1 m2 (estimate). Rolling resistance 0.011 (eco tyres; matches OVCS's 0.11 m/s^2 rolling deceleration). Efficiency 0.9 (Gillespie ch. 2).

OVCS1 estimates (nothing weighed; correct with `--set=vehicle.dynamics.*` or in tools/pack_experiment.py WEIGHED):
- Stock: 3-door Polo 9N3 1.4 TDI, 1089 kg kerb (EU, 75 kg driver and 90 % fuel included), about 62 % front.
- Removed: 1.4 TDI with ancillaries ~150 kg (front axle), exhaust ~15 kg (half each axle), fuel ~34 kg and tank/lines ~10 kg (mostly rear).
- Added: Leaf motor, inverter, mounts, cooling ~100 kg (front axle); cabling, charger, DC-DC ~20 kg (half each); battery: ASSUMED a Leaf 24 kWh pack's 48 modules (48 x 3.8 kg = 182 kg) in an enclosure, ~260 kg, centred over the rear axle.
- Without driver: 1014 kg (629 front / 386 rear) -> 805 kg after removals (460 / 345) -> +100 front, +20 split, +260 rear -> 1185 kg (570 / 615); driver 75 kg at x = -0.18 m (47 % front) -> 1260 kg, 605 kg front = 48 %. A 220 kg battery would give ~1220 kg and 50 %.
- Centre of gravity height 0.53 m: a stock Polo's; the engine out lowers it, the battery in the boot raises it: kept.
- Yaw inertia 1870 kg m2: 1.0 (not the typical 0.9) x mass x the two axle distances, the heavy motor and battery sitting over the axles.

default_car
- Engine: VW 2.0 l 8-valve petrol, 85 kW at 5,200 rpm, 170 Nm at 2,400 rpm (Wikipedia "List of Volkswagen Group petrol engines"); rev limit 6,200 rpm estimated.
- Gearbox: 02T, code letters GKM (2.0 l 85 kW), VW workshop manual "5-speed manual gearbox 02T: code letters, transmission ratios": 3.454 / 1.954 / 1.387 / 1.025 / 0.812, final drive 3.933 (59:15). A Bora 2.0's drivetrain.
- Gear "automatic": no single gear takes a petrol car from standstill to its top speed.
- Drag area 0.68 (Cd 0.31 x 2.2 m2, estimated), rolling 0.012.

OVCS Mini (estimates, unmeasured): 150 W, 0.1 Nm (the VMS's 20 A at an assumed 0.005 Nm/A), 15,000 rpm (an assumed 2,000 rpm/V at 7.4 V), one gear of 1 through 11.82 (Traxxas stock, OVCS composer), rolling 0.03, drag area 0.01 m2.

## Measured (KeyboardDrive at 60 Hz, full throttle on the flat)

| Vehicle | Top speed | 0-50 km/h | 0-100 km/h | Limited by |
|---|---|---|---|---|
| OVCS1, 1st | 104.8 km/h (10,500 rpm) | 4.0 s | 11.6 s | rpm |
| OVCS1, 3rd | 195.7 km/h (7,775 rpm) | 5.9 s | 12.6 s | power and drag |
| default_car, automatic | 197.9 km/h (5th, 4,873 rpm) | 4.8 s | 12.3 s | power and drag |
| OVCS Mini | 25 km/h (15,000 rpm) | | | rpm |

OVCS1's launch is grip-limited (3.56 m/s^2: 48 % front on eco tyres). The default car's 12.3 s is above the 10-11 s hoped for: 1350 kg, a flat 170 Nm and Gillespie's rotating mass in first (x1.5); not tuned without a source.

## Still unrealistic
- Flat torque from 0 rpm for a petrol engine (no torque curve, no idle, no clutch slip), no shift time; the automatic always picks the full-throttle gear, even cruising.
- Traction is the straight-line limit: cornering does not reduce what the driven axle passes on (DynamicBicycle's friction circle then shrinks its side force).
- No regenerative braking or engine braking on lift-off; braking and reverse fixed rates.
- OVCS1's mass, weight split, CG height, yaw inertia, frontal area and the Mini's motor are estimates.
<!-- SECTION:NOTES:END -->
