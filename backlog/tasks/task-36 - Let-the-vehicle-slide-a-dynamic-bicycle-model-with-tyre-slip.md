---
id: TASK-36
title: 'Let the vehicle slide: a dynamic bicycle model with tyre slip'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15 09:29'
updated_date: '2026-11-15 09:53'
labels: []
dependencies: []
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vehicle is kinematic: it always points where it goes, so taken fast a corner only makes it run wide; it never drifts, oversteers or spins. Replace the lateral and yaw motion with a dynamic bicycle model: mass and yaw inertia, front and rear axle side forces from slip angles saturating at the grip, weight transfer front/rear under longitudinal acceleration, the friction circle combining braking or traction with cornering. The speed along the heading still follows the command (OVCS's motion model or the keyboard), so the link's meaning is unchanged; lateral velocity, yaw rate and the IMU come from the model. Vehicle packs give mass, centre-of-gravity height and position, yaw inertia and axle cornering stiffness.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Slow, gentle turns follow the kinematic path within a few percent (tested)
- [x] #2 Trail-braking or lifting into a fast corner swings the tail out: sideslip grows and the yaw rate exceeds the path's (tested)
- [x] #3 Beyond the grip the vehicle slides and can spin; steering into the slide catches it (tested)
- [x] #4 The reported lateral velocity, yaw rate and IMU match the model's state; obstacles still stop or slide the vehicle
- [ ] #5 OVCS1 and the default car packs carry plausible values with sources; keyboard driving feels controllable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (chosen):
- Pure module vehicle/dynamic_bicycle.gd: planar single-track model about the centre of gravity. State: CG position, yaw, longitudinal speed u (commanded, held), lateral velocity v, yaw rate r. Per physics step: u ramps linearly from the last to the new command (a_x = du/dt); substeps of at most 4 ms and half the fastest lateral/yaw time constant (m*s/(Cf+Cr), Iz*s/(a^2 Cf+b^2 Cr)), explicit Euler.
- Equations: m(dv/dt + u r) = Ff cos(delta) + Fr; Iz dr/dt = a Ff cos(delta) - b Fr.
- Slip angle of each axle from its contact's velocity in the wheel frame, -atan2(lateral, |rolling|), so large sideslip and reversing stay defined.
- Tyre: simplified Pacejka F = D sin(C atan(B alpha)), C = 1.3 (peak, then about 0.93 D fully sliding), B from the cornering stiffness (slope B C D = stiffness).
- Axle loads: static split from the CG position plus m a_x h / L, each kept above 5 % of the weight. Cornering stiffness scales with the axle's load.
- Friction circle: the longitudinal force the tyres carry to hold the commanded speed, m (a_x - v r), takes its share of mu*Fz; side capacity sqrt((mu Fz)^2 - Fx^2), never below 10 % of mu Fz. Braking is shared by dynamic axle load (ideal/EBD distribution); traction is on the driven axle (pack field driven_axle: front, rear or all, shared by load).
- Peak grip mu = max_lateral_acceleration_m_s2 / g: one grip value, and steady cornering stays below it (sum of axle peaks = mu m g).
- Low speed: the dynamic state is blended with the kinematic one (grip-limited steering about the rear axle) by smoothstep over the CG's planar speed from 1 to 3 m/s: kinematic at parking speeds, no jitter at standstill.
- Speed along the heading follows the command (OVCS or the keyboard), so the link keeps its meaning; lateral velocity, yaw rate and the IMU (a_y = dv/dt + u r, plus the yaw acceleration's share at the origin) come from the model. Odometer: the move's component along the heading. Obstacles: speed_kept also scales the lateral velocity.
- Pack fields (required): mass_kg, centre_of_gravity_x_m, centre_of_gravity_height_m, yaw_inertia_kg_m2, front_cornering_stiffness_n_per_rad, rear_cornering_stiffness_n_per_rad, driven_axle; max_lateral_acceleration_m_s2 stays as the peak grip.
Options considered: tanh tyre (no peak: slides do not sustain), free longitudinal dynamics (wheel speed vs body speed; changes what the link's speed means, left out), fixed front brake bias (ideal split chosen: no extra pack field).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Parameters (pack fields; sources in tools/pack_experiment.py and tools/default_vehicle.py):
| vehicle | mass kg | front weight | CG height m | yaw inertia kg m2 | Cf / Cr N/rad | driven |
|---|---|---|---|---|---|---|
| ovcs1 (Polo 9N3 + Leaf motor) | 1230 | 48 % | 0.53 | 1900 | 80000 / 130000 | front |
| ovcs_mini (1:10 chassis) | 2.41 | 50 % | 0.045 | 0.065 | 180 / 260 | all |
| default_car | 1200 | 60 % | 0.55 | 1750 | 100000 / 95000 | front |
Mass, weight split and wheelbase of OVCS1 are the conversion's; CG height, inertia (about m*a*b) and stiffness (14 to 20 times axle load per radian, mild understeer) are textbook values for a small hatchback (Gillespie; Pacejka). The Mini's drivetrain is assumed four-wheel drive.

Decisions settled while implementing:
- The speed along the heading is held at the command within a step (zero-order hold); the speed change only sets the step's longitudinal acceleration (weight transfer, friction circle), clamped to +-grip because tyres cannot pass on more.
- Against an obstacle the reported speed loses the obstacle's share as before, but the model keeps the wheels' speed, so re-commanding the speed after a scrape is no traction jolt that would stop the vehicle steering away; the lateral velocity loses the same share.
- BicycleModel keeps only grip_limited_steering and heading: the kinematic limit DynamicBicycle blends into below 1-3 m/s.
- Keyboard: the speed-dependent steering lock shrinks to 40 % (was 15 %) at top speed, so a slide of about 17 degrees can be steered into at 25 m/s.

Evidence: default track, first corner (R45), default_car, drive log 17 m/s steady then braking 6 m/s2 for 1.2 s with the wheels straightened at 11.8 s: steady sideslip -0.8 deg at 0.355 rad/s; peak sideslip -31.6 deg, peak yaw rate 1.23 rad/s (kinematic for that steering and speed 0.34); recovered by 14.3 s. build/captures/260_default_car_braking_slide_top_view.png.

Not verified: driving it by hand with the keyboard (AC 5's feel).
<!-- SECTION:NOTES:END -->
