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

## Cameras, not pinholes

The vehicle pack may give the pair a lens and a sensor
([Pack format](./pack_format.md#vehicle-packs)): distortion, vignetting, noise, an exposure
that adapts, motion blur. Each is off when the pack does not name it. They are applied to the
two cameras' views only, never the window, in scene light before tone mapping, so the pair
sent over the link, shown by V and recorded is the cameras'.

- **Distortion** is OpenCV's model: a point a pinhole shows at `(x, y)` focal lengths from the
  optical axis is shown at `x' = x (1 + k1 r² + k2 r⁴ + k3 r⁶) + 2 p1 x y + p2 (r² + 2 x²)`,
  `y' = y (1 + k1 r² + k2 r⁴ + k3 r⁶) + p1 (r² + 2 y²) + 2 p2 x y`, at pixel
  `(fx x' + cx, fy y' + cy)`. `calib.json` gives `distortion_coefficients` as
  `[k1, k2, p1, p2, k3]`, OpenCV's order (zeros for a pinhole), with `fx`, `fy`, `cx`, `cy`
  as its camera matrix: `cv2.undistort` or `cv2.stereoRectify` take them as they are. Both
  cameras have the same lens.
- The view is drawn as a pinhole wide enough to hold all the lens sees (1.3 times the image
  for the lens above), resampled through the lens, and brought to the image's size.
- **The ground truth is that of the distorted left image**: depth, disparity and class at a
  pixel are those of the surface the lens shows there. Disparity stays
  `fx * baseline_m / depth`, the disparity between the rectified images.
- **Exposure**: a scene's mean light depends on the track's sky and sun; Spa's start straight
  on a clear day meters 0.3, so a `target` of 0.3 leaves it as a pinhole pair shows it.
- **Motion blur** follows what the renderer tells of every surface's motion across the
  image since the previous frame; the sky turns with the camera.
- Noise is drawn from the frame's number: two runs that draw the same frames have the same.

On Spa at 120 km/h (1280 × 720 pair, Radeon RX 7800 XT), the GPU spends 9.3 ms a frame over
all viewports with a pinhole pair; vignetting, noise and exposure add 0.1 ms each, motion
blur 0.2 ms, the distortion above 1.3 ms (both views are drawn 1.3 times wider and higher),
all five together 1.4 ms.

## Recording

`--stereo-record=DIR` records at `rate_hz`; with `--ground-truth`, each pair's ground truth too:

```text
DIR/
  calib.json      intrinsics (width, height, fx, fy, cx, cy), distortion_coefficients,
                  baseline_m, fields of view, mount_m (ROS base_link) and pitch_down_deg;
                  with ground truth, what its maps hold and the segmentation classes
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
a second of one core to encode, more with sensor noise: when all the processor's threads but
four are writing, the frame due is skipped rather than the simulation held back, and the
recorder tells how many were when it ends. Rows of `poses.csv` and files are numbered alike,
without gaps.

## Recording the same twice

`--record=DIR` records the pair and its ground truth so that two runs record the same, and
quits when done; `--ground-truth` beside it changes nothing:

```sh
./simulate.sh --track=spa --vehicle=ovcs1 --hold=100,2 --record=runs/spa_a --record-seconds=20
./simulate.sh --track=spa --vehicle=ovcs1 --drive-log=runs/lap/poses.csv --record=runs/spa_b
```

- `simulate.sh` starts Godot in its movie mode (`--write-movie DIR/window.avi --fixed-fps 60`):
  simulated time advances by one sixtieth of a second a frame, one physics step each,
  whatever the wall clock says. A frame may take as long as it needs, so a recording can use
  what real time cannot hold: a larger pair, sensor noise, a slow disk. `DIR/window.avi` is
  what the window showed, at 640 × 360.
- The vehicle is driven by `--hold`, or by `--drive-log=FILE`: a CSV whose header names
  `time_s`, `speed_m_s` and `steering_rad` among its columns, each row a drive held until
  the next one's time. The `poses.csv` of a recording is one, so a drive OVCS made over the
  link, recorded with `--stereo-record`, is replayed from its poses. It lasts
  `--record-seconds`, or as long as the drive log.
- Every tile within the streaming radius is loaded before a frame is drawn, instead of over
  the following frames, and no frame is skipped: writing holds the simulation back.
- Two runs write the same `poses.csv`, `calib.json`, depth, disparity and segmentation, byte
  for byte (60 simulated seconds of Spa and of Mettet). The left and right images are the
  same but for the last bit of a few pixels (ten or so of a 1280 × 720 frame, more in the
  first frames), which the renderer does not promise; sensor noise, exposure and motion
  blur are the same in both runs.
- Five simulated seconds of Mettet with a 1280 × 720 pair, its ground truth and every camera
  effect take 18 s (Radeon RX 7800 XT), the first second loading the tiles around the start.

## Ground truth

The ground truth is of the left image, pixel for pixel, lens distortion included, from what
the renderer drew:

| File | Holds |
|---|---|
| `depth/N.npy` | 32-bit floats, shape (height, width): metres along the left camera's optical axis (OpenCV's z, not the length of the ray), from the depth buffer; 0 where there is only sky |
| `disparity/N.npy` | 32-bit floats: `fx * baseline_m / depth` in pixels, the shift of the pixel's surface towards the left in the right image; 0 where there is only sky |
| `segmentation/N.png` | the class of each pixel, as its colour |

A surface whose class comes from a label pass (buildings, structures, signs, the vehicle)
has the depth of its label, drawn 5e-5 of the distance nearer: 2 mm at 40 m.

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
- What is seen through (glass: any material blended over what is behind it, the glTF `BLEND`
  alpha mode among them) has no depth and no class of its own: the pixel carries those of
  what is behind it. A cut-out (glTF `MASK`) is opaque where it is drawn; a tree's cut-out is
  that of its image.
- `calib.json` lists the classes with their ids and colours.

Recording the pair holds 60 frames a second with or without the ground truth (Spa, 1280 × 720
pair at 15 Hz, Radeon RX 7800 XT): the GPU spends 12.5 ms a frame over all viewports without
it and between 11.7 and 14.9 ms with it, run to run, its worst frame 13 to 17 ms without and
13 to 20 ms with.
