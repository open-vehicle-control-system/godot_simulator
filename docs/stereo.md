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

`--stereo-record=DIR` records at `rate_hz`; with `--ground-truth`, each pair's ground truth too:

```text
DIR/
  calib.json      intrinsics (width, height, fx, fy, cx, cy), baseline_m, fields of view,
                  mount_m (ROS base_link) and pitch_down_deg; with ground truth, what its
                  maps hold and the segmentation classes
  poses.csv       frame,time_s,x_m,y_m,z_m,qx,qy,qz,qw,speed_m_s,steering_rad
  left/000000.png
  right/000000.png
  depth/000000.npy          with --ground-truth
  disparity/000000.npy      with --ground-truth
  segmentation/000000.png   with --ground-truth
```

A pose is the vehicle's `base_link` in the world, in ROS frames, in the frame the pair shows;
the cameras sit at `mount_m` on it. Images use the OpenCV camera frame: x right, y down,
z forward, the right camera `baseline_m` along x from the left one.

A frame is read back from the GPU a few frames after it is drawn and its files are written on
worker threads, so recording never makes a frame wait. A PNG of 1280 × 720 takes a quarter of
a second of one core to encode: when more than 32 files are being written, the frame due is
skipped rather than the simulation held back, and the recorder tells how many were when it
ends. Rows of `poses.csv` and files are numbered alike, without gaps.

## Ground truth

The ground truth is of the left image, pixel for pixel, from what the renderer drew:

| File | Holds |
|---|---|
| `depth/N.npy` | 32-bit floats, shape (height, width): metres along the left camera's optical axis (OpenCV's z, not the length of the ray), from the depth buffer; 0 where there is only sky |
| `disparity/N.npy` | 32-bit floats: `fx * baseline_m / depth` in pixels, the shift of the pixel's surface towards the left in the right image; 0 where there is only sky |
| `segmentation/N.png` | the class of each pixel, as its colour |

`numpy.load` reads a `.npy` file (so does `Nx.load_numpy!`); it is a 128-byte header, then
the floats, little-endian, row by row from the top.

| Id | Class | Colour (RGB) | What is drawn |
|---|---|---|---|
| 0 | `unlabelled` | 0, 0, 0 | a surface no rule of the track pack covers |
| 1 | `sky` | 70, 130, 180 | nothing |
| 2 | `road` | 128, 64, 128 | the `terrain` surface between the edges of the lap's road, of a road around it or of a parking lot |
| 3 | `lane_marking` | 157, 234, 50 | the `terrain` surface's paint: edge lines, road markings, bays |
| 4 | `kerb` | 244, 35, 232 | the `terrain` surface's kerbs |
| 5 | `terrain` | 152, 251, 152 | the rest of the `terrain` surface, and the far terrain |
| 6 | `vegetation` | 107, 142, 35 | the trees and the canopy |
| 7 | `building` | 70, 70, 70 | the `roof`, `facade` and `seats` surfaces |
| 8 | `structure` | 102, 102, 156 | the `plain` surface: walls, barriers |
| 9 | `sign` | 220, 220, 0 | road signs, their posts, signals |
| 10 | `vehicle` | 0, 0, 142 | the vehicle itself, where the camera sees it |

- A class comes from what draws the pixel: the surface of the pack's rule
  ([Pack format](./pack_format.md#surfaces)) or the kind of object, never a track's names.
  On the ground, the class is what covers most of the pixel.
- A third camera, at the left one's place, draws these: every surface shows it its class
  instead of its colour, and a compute pass turns its depth buffer and the classes into the
  three maps on the GPU. It draws only the frames that are recorded.
- What is seen through (glass) has no depth and no class of its own: the pixel carries those
  of what is behind it. A tree's cut-out is that of its image.
- `calib.json` lists the classes with their ids and colours.

Recording the pair holds 60 frames a second with or without the ground truth (Spa, 1280 × 720
pair at 15 Hz, Radeon RX 7800 XT): the GPU spends 12.5 ms a frame over all viewports without
it and between 11.7 and 14.9 ms with it, run to run, its worst frame 13 to 17 ms without and
13 to 20 ms with.
