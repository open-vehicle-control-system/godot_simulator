---
title: The simulator link
description: The TCP protocol OVCS drives the simulator over.
---

OVCS's `SimulatorCore.Link` listens on TCP (port 7400 unless the vehicle sets another); the
simulator connects to it with `--link=HOST:PORT`. The wire format is OVCS's
`SimulatorCore.Link.Protocol`: a change to it starts in OVCS.

## Packets

Each packet is a 32-bit big-endian length, then that many bytes: a 16-bit big-endian header
length, a JSON header, and the message's binary body, if any. A packet over 16 MiB is a broken
stream.

| `type` | Direction | Header fields | Body |
|---|---|---|---|
| `actuation` | OVCS → simulator | `time_s`, `drive_torque_nm`, `brake_torque_nm`, `steering_rad`, `driveline_inertia_kg_m2` | none |
| `instruments` | OVCS → simulator | `motor_rpm` | none |
| `state` | simulator → OVCS | `time_s`, `odometer_m`, `position_m`, `orientation`, `linear_velocity_m_s`, `angular_velocity_rad_s`, `linear_acceleration_m_s2`, `wheels` | none |
| `image` | simulator → OVCS | `camera` (`left`, `right`), `time_s`, `format` (`jpeg`) | the image |

Units are SI and frames are ROS's: `position_m` and `orientation` (`[x, y, z, w]`) are the
vehicle's `base_link` in the world; velocities and `linear_acceleration_m_s2` are in
`base_link`, the acceleration being what an IMU reads (gravity's reaction included).
The simulator is the vehicle's one dynamics model; OVCS sends the efforts of its actuators,
OVCS's TASK-129:

- `drive_torque_nm`: the drive torque at the wheels of the driven axle, both wheels together
  (the motor's torque times the reduction), signed, positive driving forward. An open
  differential gives each wheel half.
- `brake_torque_nm`: the brakes' total torque at the wheels, 0 or more. The vehicle pack's brake
  bias splits it between the axles; it opposes each wheel's spin and holds a wheel still up to
  its torque.
- `steering_rad`: the front wheels' bicycle-equivalent angle, positive to the left (the angle
  the simulated steering column reached); the simulator turns each front wheel by Ackermann's
  geometry from the pack's wheelbase and track.
- `driveline_inertia_kg_m2`: the motor's and gearbox's inertia at the driven axle, the rotor's
  times the overall ratio squared: it changes with the gear.
- `time_s`: OVCS's monotonic clock since the link connected.

`wheels` holds, per wheel (`front_left`, `front_right`, `rear_left`, `rear_right`), `angle_rad`
(turned since the start, signed, positive rolling forward), `omega_rad_s` (its spin, positive
rolling forward) and `in_contact` (true while it touches the ground). OVCS's simulated parts
turn them into the CAN frames the VMS reads: wheel speeds, the motor's rpm, pulse counters.
`state`'s `time_s` counts the simulator's physics time from its start; both images of a pair
carry the same one. `motor_rpm` is the traction
motor's speed as the vehicle's motor controller reports it, signed when the controller reports
a direction (positive driving forward); OVCS sends it after each actuation when the vehicle's
simulated hardware has one (OVCS1's Leaf inverter does, the OVCS Mini sends none).

## Behaviour

- The simulator retries every second until connected, and again after losing the connection.
- It sends a `state` every physics step (60 Hz) and a stereo pair at the vehicle pack's
  `stereo.rate_hz`, encoded off the main thread; a pair due while the last one is encoding is
  skipped.
- Every message is absolute: an `actuation` holds until the next, and a restarted simulator
  drives from the first it receives. With no actuation for 0.5 s the drive torque drops to 0,
  the brakes and steering staying as last sent. With no connection the vehicle is parked:
  braked harder than its tyres hold, keeping its steering.
- The simulation keeps real time, as a hardware-in-the-loop bench does: OVCS's VMS runs on the
  wall clock. Runs are not stepped in lockstep with OVCS, so two runs over the link differ a
  little; checks on them hold within tolerances.
- The rev counter shows the last `motor_rpm`, either way round, while it is under 0.5 s old;
  older, or with no connection, it shows 0.
- A packet it cannot read, a message type it does not know among them, is dropped with a
  warning: an older or newer OVCS keeps working with the messages both know.
- Sending never blocks the simulator. While more than 2 MiB are waiting for OVCS to read them,
  images are dropped and states still sent; beyond 32 MiB the simulator disconnects.
- Images carry the time and state of the frame they show, one physics step before the
  capture: Godot steps physics before drawing.
- A pair is read back from the GPU a few frames after it is asked for, so asking never makes
  a frame wait for the GPU; it still carries the time of the frame it shows.
- The simulator never waits on vsync and runs at 60 frames per second: OVCS measures wheel
  speed against the wall clock.
