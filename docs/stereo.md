---
title: Stereo camera
description: The simulated stereo pair, sent over the link or recorded for offline vision work.
---

Every vehicle carries a rectified stereo pair: two parallel pinhole cameras with the same
intrinsics, a horizontal baseline apart, no toe-in, mounted and configured by the vehicle
pack's `stereo` fields ([Pack format](./pack_format.md#vehicle-packs)). Depth follows from
disparity `d` in pixels: `Z = fx * baseline_m / d`, with `fx = width_px / 2 / tan(hfov / 2)`
and the principal point at the image centre (`cx = (width_px - 1) / 2` with OpenCV's integer
pixel centres).

Linked to OVCS, the pair goes over the link as JPEG `image` packets at `rate_hz`
([The simulator link](./simulator_link.md)). V shows it along the bottom of the window.

## Recording

`--stereo-record=DIR` records at `rate_hz`:

```text
DIR/
  calib.json      intrinsics (width, height, fx, fy, cx, cy), baseline_m, fields of view,
                  mount_m (ROS base_link) and pitch_down_deg
  poses.csv       frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad
  left/000000.png
  right/000000.png
```

A pose is the vehicle's `base_link` in the world, in ROS frames, when the pair was captured;
the cameras sit at `mount_m` on it. Images use the OpenCV camera frame: x right, y down,
z forward, the right camera `baseline_m` along x from the left one.
