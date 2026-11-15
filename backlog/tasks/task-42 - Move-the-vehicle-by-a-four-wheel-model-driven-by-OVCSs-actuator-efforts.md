---
id: TASK-42
title: Move the vehicle by a four-wheel model driven by OVCS's actuator efforts
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15 16:27'
updated_date: '2026-11-15 17:03'
labels:
  - vehicle
dependencies: []
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Godot becomes the vehicle's single, full dynamics model (agreed with OVCS for its TASK-129). A Jolt rigid body on four suspended wheels, each with its own spin, Pacejka tyres with combined slip and relaxation, an open differential with the driveline's inertia, brakes that hold at standstill; walls, wheel lift and rollover come from the physics. Under --link OVCS sends `actuation` (time_s, drive_torque_nm at the driven axle, brake_torque_nm total, steering_rad bicycle-equivalent, driveline_inertia_kg_m2), absolute, at 50 Hz; `drive` is gone. `state` adds each wheel's angle_rad (cumulative), omega_rad_s and in_contact. 0.5 s without actuation: zero drive torque, brakes as last sent; no connection: parking hold. Real time only, no lockstep. --keyboard drives through the pack's powertrain as torques; --hold and --drive-log through a speed controller. Replaces the dynamic bicycle model.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Under --link the vehicle moves only by the actuation OVCS sends: drive and brake torques, steering and driveline inertia (tested end to end)
- [x] #2 state reports each wheel's angle, angular speed and ground contact; docs/simulator_link.md describes actuation and the new state
- [x] #3 A wheel lifted or on low grip spins without moving the body; a wall stops the body while torque is applied; brakes hold the car on a slope (tested)
- [x] #4 --keyboard, --hold and --drive-log still drive; --record stays identical run to run
- [x] #5 The design, architecture and pack format docs describe the four-wheel model and its constants
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Design

Godot is the vehicle's single, full dynamics model (agreed with OVCS for its TASK-129, PR #386). `Vehicle` is a Jolt RigidBody3D (pack mass, CG, yaw inertia; pitch and roll from the body box; no engine damping) moved only by its `Actuation`.

- Suspension: a ray per wheel along the body's up axis; spring preloaded to the static load at the pack's ride height, 1.5 Hz, 35 % damping, bump stop 10x past a travel of 0.3 wheel radii; anti-roll bars bring each axle to its `front_roll_stiffness_share` of a 4 deg/g total.
- Wheels (pure, 0.5 ms substeps): open differential (equal torque, driveline inertia on the mean speed), brakes and rolling resistance that hold a wheel still up to their torque (exact 2x2 solve for a driven pair), wheel inertia 1 % of mass at the radius.
- Tyre (pure): tread deflection with relaxation (0.45 / 1.2 wheel radii), Pacejka over the combined slip scaled by stiffness (pack cornering stiffness; 18 x static load along), damped at standstill, deflection capped at 3x the peak's.
- Body box collides with obstacles and the ground; clearance 0.6 wheel radii.
- Link: `actuation` in (time_s, drive_torque_nm, brake_torque_nm, steering_rad, driveline_inertia_kg_m2); `state` adds `wheels` {front_left..rear_right: angle_rad, omega_rad_s, in_contact}; `drive` removed. 0.5 s without actuation: drive 0, brakes and steering kept; no connection: parked. Real time, no lockstep (OVCS's VMS runs on the wall clock).
- --keyboard: torques from the powertrain (automatic shifts up at 97 % of the rpm limit, on the driven wheels' speed); --hold and --drive-log: SpeedControl (PI, 3 m/s^2, no windup).
- Tests: the runner uses --fixed-fps 60 (263 tests in ~12 s) and frees each test's nodes.

## Measured

- Default car: 0-85 km/h in 10 s at full throttle; roll 1.84 deg at 0.48 g on flat ground (3.8 deg/g); dives ~1 deg braking at 0.6 g; understeer about 2.6 deg/g; physics ~0.5 ms a step.
- Rear-biased brakes without a valve in a 22 m/s corner: rear locks, the car spins.
- OVCS Mini (2.4 kg, 5 cm wheels): holds 3 m/s in a 1.8 m circle and stops; OVCS1 drives on Mettet.
- --record with --hold repeats exactly (rendered test).

## Known limits

- OVCS has no encoder for `actuation` yet: the decode test uses a header written to the contract.
- Suspension, relaxation, slip stiffness and wheel inertia are derived constants, not pack fields.
- SpeedControl knows no powertrain limit; the body box is one box.
<!-- SECTION:NOTES:END -->
