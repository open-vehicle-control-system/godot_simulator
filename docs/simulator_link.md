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
| `drive` | OVCS → simulator | `speed_m_s`, `steering_rad` | none |
| `instruments` | OVCS → simulator | `motor_rpm` | none |
| `state` | simulator → OVCS | `time_s`, `odometer_m`, `position_m`, `orientation`, `linear_velocity_m_s`, `angular_velocity_rad_s`, `linear_acceleration_m_s2` | none |
| `image` | simulator → OVCS | `camera` (`left`, `right`), `time_s`, `format` (`jpeg`) | the image |

Units are SI and frames are ROS's: `position_m` and `orientation` (`[x, y, z, w]`) are the
vehicle's `base_link` in the world; velocities and `linear_acceleration_m_s2` are in
`base_link`, the acceleration being what an IMU reads (gravity's reaction included).
`steering_rad` is the front wheels' angle, positive to the left. `time_s` counts from the
simulator's start; both images of a pair carry the same one. `motor_rpm` is the traction
motor's speed as the vehicle's motor controller reports it, signed when the controller reports
a direction (positive driving forward); OVCS sends it after each drive when the vehicle's
simulated hardware has one (OVCS1's Leaf inverter does, the OVCS Mini sends none).

## Behaviour

- The simulator retries every second until connected, and again after losing the connection.
- It sends a `state` every physics step (60 Hz) and a stereo pair at the vehicle pack's
  `stereo.rate_hz`, encoded off the main thread; a pair due while the last one is encoding is
  skipped.
- A `drive` holds until the next. With no drive for 0.5 s, or no connection, the vehicle is
  commanded to stop, keeping its steering.
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
