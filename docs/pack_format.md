---
title: Pack format
description: What a track or vehicle pack contains, so it can be built and released apart from the simulator.
---

A pack is a directory holding a `pack.json` manifest and the files it names. Packs are data:
glTF 2.0 binaries, images, JSON and arrays of numbers, never code. Each is released on its own, as an archive of
its directory, under the licence its manifest states.

## Finding packs

The simulator looks for packs directly under each `--packs` directory, then under `packs/`
next to its executable, then under `user://packs`, then among the packs it bundles
(`simulator/default_packs/`: `default_track` and `default_car`, selected when `--track` or
`--vehicle` is left out). A pack is selected by its `id`; two packs
with one id are both refused.

## Common fields (format 1)

```json
{
  "format": 1,
  "kind": "track",
  "id": "mettet",
  "name": "Circuit Jules Tacheny, Mettet",
  "version": "1.0.0",
  "licence": "CC-BY-4.0 AND ODbL-1.0",
  "attribution": ["OpenStreetMap contributors, ODbL 1.0"]
}
```

| Field | Meaning |
|---|---|
| `format` | `1` |
| `kind` | `track` or `vehicle` |
| `id` | lower-case letters, digits and underscores; what `--track` / `--vehicle` select |
| `name`, `version` | shown to the user; the version is the pack's own |
| `licence` | an SPDX expression, or `LicenseRef-…` for terms SPDX has no id for |
| `attribution` | the notices the licences require |

Positions, sizes and orientations are in ROS frames (REP-103): metres, x forward, y left, z up
for a vehicle; x, y, z up for a world.

## Vehicle packs

```json
"vehicle": {
  "model": "vehicle.glb",
  "front_axle_x_m": 1.122,
  "rear_axle_x_m": -1.319,
  "front_track_m": 1.415,
  "rear_track_m": 1.396,
  "wheel_radius_m": 0.296,
  "wheel_width_m": 0.2,
  "max_lateral_acceleration_m_s2": 7.8,
  "body": {"size_m": [3.85, 1.62, 1.05], "centre_m": [0.0, 0.0, 0.85]},
  "driver_eye_m": [-0.178, 0.381, 1.106],
  "driver_pitch_deg": -2.82,
  "stereo": {
    "mount_m": [0.635, 0.0, 1.161],
    "width_px": 1280, "height_px": 720, "hfov_deg": 90.0,
    "baseline_m": 0.12, "pitch_deg": 0.0, "rate_hz": 15.0
  },
  "instruments": {
    "speedometer": {
      "node": "Cockpit_Speed", "axis": [0.949, 0.005, -0.314],
      "km_h_to_deg": [[0, 0.0], [10, 14.5], [100, 135.6], [260, 273.8]]
    },
    "rev_counter": {
      "node": "Cockpit_Rpm", "axis": [0.949, 0.0, -0.314],
      "deg_per_rpm": 0.0495, "max_rpm": 6000, "motor_to_wheel_ratio": 8.19
    },
    "steering_wheel": {
      "node": "Cockpit_Steer", "axis": [-0.965, 0.0, 0.264], "ratio": 16.2, "lock_deg": 507.0
    }
  },
  "mirrors": {"material": "MIRRORS", "interior_hfov_deg": 45.0, "door_hfov_deg": 30.0}
}
```

- The origin is on the ground; axle positions are along x.
- `max_lateral_acceleration_m_s2` is the tyres' grip: the vehicle never corners harder than
  this; steered beyond it, it runs wide. Road tyres on dry asphalt hold about 0.8 g.
- `body` is a box: the placeholder drawn when there is no `model`.
- Lengths, the wheel radius, the stereo resolution, baseline and rate are positive, the field of
  view under 180°, and the front axle ahead of the rear one; a pack that breaks this is refused.
- `driver_pitch_deg` tilts the cockpit view up; negative looks down.
- `stereo.mount_m` is midway between the two cameras; positive `pitch_deg` tilts them down. See
  [Stereo camera](./stereo.md).
- `stereo` may also say what makes its images those of cameras; each is off when absent, and
  a pair with none is a pinhole pair, drawn as before:

  ```json
  "distortion": {"k1": -0.17, "k2": 0.03, "p1": 0.0005, "p2": -0.0003, "k3": 0.0},
  "vignetting": 0.35,
  "noise": {"read": 0.004, "shot": 0.012},
  "exposure": {"target": 0.3, "speed_per_s": 2.0, "max_stops": 3.0},
  "motion_blur": {"shutter_s": 0.008}
  ```

  | Field | Meaning |
  |---|---|
  | `distortion` | the lens's distortion in OpenCV's model, its five coefficients all given; `width_px`, `height_px` and `hfov_deg` stay those of the image and of its pinhole (`fx`). Refused when the lens shows a point twice within the image, or sees more than twice as wide as the pinhole |
  | `vignetting` | the share of the light lost in the image's corners, above 0 and below 1; it grows with the square of the distance from the centre |
  | `noise` | the sensor's noise, in scene light before tone mapping: its deviation is `sqrt(read² + shot² × light)`, drawn anew for every pixel, channel, frame and camera |
  | `exposure` | the gain that brings the scene's mean light (the geometric mean of its luminance) to `target`, followed at `speed_per_s` and kept within `max_stops` either way of 1; each camera meters for itself |
  | `motion_blur` | `shutter_s`, how long a frame gathers light: what moves across the image is smeared over the way it came in that time |

  See [Stereo camera](./stereo.md#cameras-not-pinholes).
- `model` is optional. In it, glTF's own convention holds (+Y up, the front facing +Z), and the
  simulator reads three kinds of node: `Body`, drawn where it sits; `Wheel`, centred on its axle
  at the origin with its outer face towards +X, copied to each corner; and `Cockpit_*`, the
  cockpit's moving parts, drawn where they sit.
- `instruments` is optional, and so is each of its three parts; a vehicle without them has a
  still cockpit. Each names its `node`, one of the model's `Cockpit_*` whose origin is the
  pivot, and the `axis` it turns about by the right-hand rule as its reading rises (for the
  steering wheel, as the vehicle steers left), from where the model draws it at zero.
  - `speedometer`: `km_h_to_deg` is the dial, two or more `[km/h, needle degrees]` marks in
    rising order; the needle goes straight between marks and stops at the dial's ends.
  - `rev_counter` shows the motor's speed, the wheels' times `motor_to_wheel_ratio`, at
    `deg_per_rpm` up to `max_rpm`.
  - `steering_wheel` turns by the front wheels' angle times `ratio`, up to `lock_deg` either
    way.
- `mirrors` is optional: `material` is the glTF material of the `Body`'s mirror glass. Glass
  further than a quarter of the body's width from the centreline is a door mirror's, the rest
  the interior mirror's. Each mirror shows what a camera at its glass's centre sees looking
  straight back, `door_hfov_deg` or `interior_hfov_deg` wide, across the glass's width and
  height.
- Scales and ratios are positive, fields of view under 180° and axes not zero; a pack that
  names a node or material its model lacks is refused.

## Track packs

```json
"track": {
  "tiles": "tiles.json",
  "far": {"scene": "far.glb", "photo": "far.jpg"},
  "sky": "sky.hdr",
  "sun": {"azimuth_deg": 45.0, "elevation_deg": 40.0},
  "haze": {"visibility_m": 16000.0},
  "indirect_light": {"strength": 1.0},
  "spawn": {"position_m": [196.92, -127.35, 21.32], "yaw_deg": -71.0},
  "ground": {...},
  "surfaces": [...],
  "trees": {...},
  "signs": {...},
  "decals": {...}
}
```

- `tiles` lists the square tiles the world is cut into, each loaded on its own: see
  [Tiles](#tiles). Every track is tiled, whatever its size.
- `far` is optional: the whole area, coarse, drawn where a tile is not loaded. `scene` holds
  one mesh per tile, named `Far_<key>`, UV 0 across `photo`, an image graded as the
  ground's orthophotos are.
- `sky` is optional: an equirectangular panorama (HDR, PNG or JPEG) in the pack. Without it the
  sky is procedural.
- `sun` is optional: where the sun is, `azimuth_deg` counter-clockwise from x seen from above
  (as a yaw) and `elevation_deg` above the horizon. The sky is turned about the vertical so its
  brightest spot is at that azimuth. Without `sun` the light comes from the sky's brightest
  spot.
- `haze` is optional: `visibility_m` is how far one sees through the air, the distance at
  which a black object keeps 2% of its contrast against the sky. Without it the air is a
  clear day's, 20 km.
- `indirect_light` is optional, a choice of look: `strength` (0 to 4, 1 without the field) is
  how strongly the surfaces the window shows light and shade each other, which darkens what
  is under a roof, a stand or the vehicle; 0 does without, and saves the window 0.3 ms a
  frame. It changes the window only, never the stereo cameras' images.
- `spawn` is where the vehicle starts, yaw counter-clockwise from x seen from above.
- `ground`, `surfaces`, `trees`, `signs` and `decals` are optional: see [Surfaces](#surfaces),
  [Trees](#trees), [Signs and signals](#signs-and-signals) and [Decals](#decals).
  A material no surface covers is drawn as its glTF PBR definition.

### Tiles

```json
{
  "tile_size_m": 256.0,
  "ground_step_m": 0.5,
  "tiles": [
    {
      "key": "763368_626948",
      "corner_m": [-854.0, -282.0],
      "bounds_m": [[-854.0, -282.0, 49.1], [-598.0, -26.0, 98.7]],
      "maps": ["track", "roads", "lots"]
    }
  ]
}
```

- `tile_size_m` is the side of every tile and `ground_step_m` the spacing of the samples of
  its ground's heights, which divides the side.
- A tile's `key` names its files, all under `tiles/`. `corner_m` is its corner of lowest x
  and y; `bounds_m` the lowest and highest corners of the box holding everything in it, which
  may reach past its square (a wall whose centre is on the tile). `maps` lists the optional
  ground maps it has.

| File | Holds |
|---|---|
| `<key>.glb` | the tile's meshes, in glTF's convention (+Y up), in the world's frame |
| `<key>.ground.f32` | the height of the ground: little-endian 32-bit floats, `tile_size_m / ground_step_m + 1` rows of as many samples, from `corner_m` towards +x row by row and towards +y within a row, both edges included |
| `<key>.photo.jpg` | the orthophoto of the tile, for the `terrain` surface; the simulator builds its mipmaps as it reads it |
| `<key>.surface.png` | the surface map of the tile, for the `terrain` surface |
| `<key>.track.png`, `<key>.roads.png`, `<key>.lots.png` | the tile's track map, roads map and lots map, when `maps` lists them |
| `<key>.json` | what stands on the tile, for a track with `trees`, `signs` or `decals`: `trees`, `posts`, `plates`, `signals` and `decals` |

- A mesh belongs to one tile. The ground (what the `terrain` surface draws) is cut on the
  tiles' edges, neighbours sharing the corners along them, so it has no seam; any other mesh is
  whole in the tile holding its centre.
- The vehicle rests on the heights of `<key>.ground.f32`, which follow the drawn ground: the
  road where there is one, the terrain elsewhere. Beyond the ground's edge they carry its
  height on. Neighbours hold the same heights along their common edge. Every mesh the
  `terrain` surface does not draw collides as it is drawn.
- The simulator loads the tiles within 200 m of the spawn before its first frame, then keeps
  those within 900 m of the vehicle loaded, freeing a tile once it is 1100 m away. The tiles
  within 120 m of the vehicle collide.
- `<key>.json`: `trees` holds a list per kind, `conifer` and `broadleaf`, of trees as
  `[x, y, z, height_m]`; `posts`, `plates` and `signals` are lists as
  [Signs and signals](#signs-and-signals) describes, `decals` as [Decals](#decals) does.
  Positions are in the world's ROS frame.

### Surfaces

`surfaces` is a list of rules. Each names the meshes and glTF materials it covers and the
simulator surface that draws them; the first rule that covers a material on a mesh wins.

| Field | Meaning |
|---|---|
| `surface` | `terrain`, `roof`, `facade`, `plain` or `seats` |
| `meshes`, `materials` | globs (`*`, `?`) over mesh and glTF material names; `*` when left out |

A texture set is named by its path in the pack without suffix: `textures/brick` stands for
`textures/brick_albedo.dds`, `textures/brick_normal.dds` (OpenGL convention) and
`textures/brick_rough.dds`. The texture sets and the tree atlases are DDS files, block-compressed, with their mipmaps,
so loading one is reading it: BC1 for colour and roughness, BC3 for colour with alpha, and BC5 for
normals, which keeps x and y (the simulator rebuilds z). The ground's layers are all of one
size.

| Surface | Draws | Takes |
|---|---|---|
| `terrain` | the ground and what lies on it: the `ground`'s layers under the orthophoto, the lap's road with its lines, kerbs and rubber, the roads around it with their markings, and the parking lots with their bays | the tile's photo and maps, UV 0 across the tile |
| `roof` | a roofing texture set whose rows run along the eave, tinted to the roof's colour, with a dark trim along its edge | `textures`, `size_m`; UV 0 = (metres along the eave, metres up the slope); UV 1 = the distances in metres to two edges of the roof, each a plane over its triangle (the smaller is the distance to the roof's edge; 100 for none); vertex colour = the roof's albedo (linear RGB) |
| `facade` | a tiled wall with rows of windows a storey apart and a door, centred on the wall, and dirt at its foot | `textures`, `size_m` (the width the set covers), `windows` (`house`, `hall` or `office`), `tint` (RGB factors); UV 0 = (metres along the wall from its corner, 1 - metres above its ground floor) / 3, UV 1 = (the wall's top above its ground floor, the wall's length) in metres; a face with a length of 0 (a floor) gets no window |
| `plain` | a texture set projected in world space (walls, barriers) | `textures`, `size_m`, `tint` |
| `seats` | grandstand steps with rows of seats and stair aisles | `textures` (the concrete), `tint` (the seats); UV 0 = (metres along the stand, 1 - metres of depth), UV 1 = (row depth in metres, 1 - face kind: 0 tread, 1 riser, 2 plain) |

The photo and the maps are the tile's ([Tiles](#tiles)); each covers the tile, its first row
along the tile's edge of lowest x (north, for a world whose x points south) and its first
column along the edge of lowest y. UV 0 of the ground's meshes is (0, 0) there and (1, 1) at
the opposite corner. A tile without a track map, roads map or lots map has no road or lot on
it.

- A **surface map** is an 8-bit greyscale PNG: each pixel's value is the index of the `ground`
  layer there. Its resolution is free; 25 cm per pixel matches the orthophotos.
- A **road map** (`track_map` for the lap, `roads_map` for the roads around it) is an RGBA PNG,
  50 cm per pixel, giving the ground's place along a road. The distance along the road takes
  20 bits, 0.125 m per step: R, G and the high half of B. The distance right of the centreline
  takes 12 bits, 1 cm per step from 2048: the low half of B, and A; 4095 marks ground away from
  any road. In a `track_map` the distance along is the lap's. In a `roads_map` the roads lie
  end to end along one axis, a few metres apart, and each pixel belongs to one road: the road
  of highest rank between whose edges it lies, else the nearest edge within 1.5 m. The
  simulator blends a map's four texels around a point; by a tile's border it carries the
  coordinates on from the tile's last two texels, so a line crosses tiles without a step.
  Where the four texels are more than 8 m apart along the road, two roads or two stretches
  of one meet: the nearest texel's coordinates stand, and no road marking is painted.
- A **lots map** is an RGB PNG, 50 cm per pixel: R is the parking lot's number (from 1, its
  place in `ground.lots`; 0 outside any lot) and G the distance to that lot's edge, 2.5 cm per
  step from 128, below 128 inside the lot. The edge is where that distance crosses 128, so it
  is as sharp and straight as the lot's fitted outline, not as the map's pixels.

### Ground

```json
"ground": {
  "layers": [
    {"textures": "textures/grass004", "size_m": 2.5, "photo": 0.75},
    {"textures": "textures/asphalt_track", "size_m": 2.0, "photo": 1.0}
  ],
  "slope_layer": 0,
  "photo_grade": {"black": [0.009, 0.019, 0.036], "gain": [0.27, 0.27, 0.26], "gamma": 0.7, "saturation": 1.3},
  "road": {"lines": "road_lines.png", "lap_length_m": 2264.54, "layer": 1},
  "roads": {"lines": "roads_lines.png", "dashes_m": [[2.5, 10.0], [1.25, 1.25]], "line_width_m": 0.15},
  "lots": "lots.json"
}
```

- `layers`: one to ten texture sets, indexed by the surface maps, the roads and the lots.
  `size_m` is the width a set covers. `joints_m` is optional: the layer is laid in slabs that
  wide, whose joints are drawn on roads and lots. `photo` (0 to 1) is how far the layer takes the orthophoto's colour: at 1 the
  layer only gives the photo its grain (paved surfaces, whose markings and patches the photo
  shows), lower values keep more of the set's own colour (vegetation).
- `slope_layer`: the layer steep faces are drawn with; a photo taken from above shows next to
  nothing of them.
- `photo_grade` turns the orthophoto's sunlit, hazy colours into albedo, in linear light:
  `albedo = gain * max(photo - black, 0) ^ gamma`, then its saturation is scaled by
  `saturation`.
- `road` is optional and needed by a `track_map`: `lines` is the road lines image,
  `lap_length_m` the lap's length and `layer` the layer the asphalt between the road's edges
  is drawn with.
- `roads` is optional and needed by a `roads_map`: `lines` is the roads' lines image,
  `dashes_m` up to four dashed patterns as `[dash, gap]` in metres, and `line_width_m` the
  width of a painted line. See [Roads around the lap](#roads-around-the-lap).
- `lots` is optional: a JSON file listing up to 255 parking lots. See
  [Parking lots](#parking-lots).

The **road lines image** is an RGBA PNG, one column per metre of lap and three rows:

| Row | R | G | B | A |
|---|---|---|---|---|
| 0 | left asphalt edge, high byte | its low byte | right asphalt edge, high byte | its low byte |
| 1 | left kerb width, 1 cm per step, 0 without a kerb | right kerb width | racing line, 5 cm per step, 128 on the centreline, above to the right | rubber on the racing line |
| 2 | 255 where the left edge line is painted, 0 in its gaps | the same for the right edge line | | 255 |

An edge is 16 bits, 1 mm per step from the centreline: at 8 bits a line steps sideways by
centimetres every metre, which shows from a car's height. The simulator reads the two metres
around a point and blends them. It draws a white line 15 cm wide, 10 cm inside each edge,
red and white kerbs of 1.5 m stripes outside the edge, and rubber around the racing line. The
edges are a clean model of the road, not a trace of the photo: see
[Track creation](./track_creation.md).

### Roads around the lap

The **roads' lines image** is an RGBA PNG whose columns are metres along the roads' common
axis: a road that starts at `s` metres takes the columns from `s mod width` of band
`floor(s / width)`, and no road straddles two bands. A band is 24 rows:

| Row | R | G | B | A |
|---|---|---|---|---|
| 0 | the road's half width, high byte | its low byte | the road's layer | 255 |
| 1 | the marking across the road at that metre: 0 none, 1 stop line, 2 pedestrian crossing, 3 give-way line for the traffic along the road, 4 for the traffic against it | its left end | its right end | 255 |
| 2 to 7 | a line's offset, high byte | its low byte | that line's pattern | 255 |
| 8 to 23 | the road's colour (sRGB albedo) in 16 lanes from its left edge to its right | | | 255 |

The half width and the offsets are 16 bits, 1 mm per step: the half width from the centreline,
an offset right of it from 32768. The ends of a marking across the road are right of the
centreline, 5 cm per step from 128. A pattern is 0 where the
line is not painted, 255 for a solid line, 254 for a double solid line, or 1 + an index into
`dashes_m`; dashes are in phase
with the distance along the road. A road's first and last columns are repeated in the columns
around it.

Between a road's edges the simulator draws its layer in its colour, whatever the orthophoto
shows there, then its lines, crossings (stripes along the road, 50 cm wide and apart), stop
lines (50 cm, in the middle of their metre) and give-way lines (triangles 50 cm wide and 60 cm
long every 75 cm, pointing at the traffic that gives way), as worn white paint.

### Parking lots

```json
[
  {
    "layer": 6, "colour": [0.14, 0.14, 0.15],
    "origin_m": [-357.0, 607.4], "yaw_deg": 245.6, "bay_width_m": 2.52,
    "rows": [{"along_m": [-14.7, 18.1], "across_m": [-15.9, -10.7], "ends": [0, 1]}]
  }
]
```

- `layer` and `colour` (linear albedo) are what the lot is drawn with inside its edge in the
  lots map: the orthophoto's cars are not drawn.
- `origin_m` and `yaw_deg` place the lot's frame in the world (x, y; yaw counter-clockwise from
  x seen from above): its rows of bays run along the frame's first axis.
- A row has a divider every `bay_width_m` from `along_m[0]` to `along_m[1]`, each reaching from
  `across_m[0]` to `across_m[1]` (to the left of the first axis); `ends` tells whether a line
  along the row closes it at each of those. At most 16 rows; `bay_width_m` is 0 for a lot
  without bays. A yard (paved ground the photo shows cars or goods on, that no map calls a
  lot) is listed like a lot, without bays.

### Trees

```json
"trees": {
  "impostors": [
    {"atlas": "trees/fir.dds", "views": 3, "width_m": 7.8, "height_m": 18.9, "kind": "conifer"}
  ],
  "canopy": {"scene": "canopy.glb", "from_m": 600.0}
}
```

- The trees stand where the tiles list them ([Tiles](#tiles)); every trunk collides.
- An impostor's `atlas` is a DDS texture with alpha of the tree seen from `views` directions evenly spread
  over half a turn, side by side; `width_m` and `height_m` are one view's. Each tree is drawn
  with an impostor of its kind, scaled to its height. Its shadow is cast by the atlas's
  silhouette, where its alpha is over 0.45.
- `canopy` is optional, for a track with `far`: the woods as one coarse surface over the
  crowns, drawn where the trees are further than `from_m` from the camera, loaded tile or
  not. The trees shrink away over the last fifth of `from_m`; the canopy rises from the
  ground over the fifth before. Without `canopy` a tree is drawn wherever its tile is loaded.
  `scene` holds meshes named `Canopy_<key>`, each node at the middle of its mesh, with a
  linear vertex colour (the crowns'), UV 1 across `far.photo` and, as UV 0's first
  coordinate, how many metres the vertex stands above the canopy's hem, where it lies when
  near the camera: under the ground.

### Signs and signals

```json
"signs": {
  "faces": [
    {"id": "BE:C43[50]", "image": "signs/be_c43_50.png",
     "outline_m": [[0.35, 0.0], [0.346, 0.055], [0.333, 0.108]]}
  ],
  "signal": {"lens_diameter_m": 0.2, "cycle_s": [18.0, 3.0, 23.0]}
}
```

- A face is a kind of plate: `outline_m` is its convex outline in metres about the plate's
  centre, counter-clockwise seen from the front, x to the viewer's right and y up; `image`
  is what the front shows, across the outline's bounding box. The back is bare metal.
- `signal` describes every signal head: three lenses of `lens_diameter_m`, red on top, lit
  in turn for `cycle_s` seconds of green, amber and red.
- The tiles list what is placed ([Tiles](#tiles)), each tile in three lists, positions in the
  world's ROS frame, yaw counter-clockwise from x seen from above:

```json
{
  "posts": [{"position_m": [-198.9, 511.7, 38.3], "height_m": 2.11, "diameter_m": 0.076}],
  "plates": [{"face": "BE:B1", "position_m": [-198.8, 511.7, 40.1], "yaw_deg": 3.5, "source": "tagged"}],
  "signals": [{"position_m": [12.0, 4.1, 30.9], "yaw_deg": 90.0, "phase": 0.5, "source": "tagged"}]
}
```

- A post stands on `position_m`, `height_m` tall; every post collides.
- A plate's `position_m` is its centre and `yaw_deg` the way its front faces; `face` is the
  `id` of one of `faces`. A signal's `position_m` is the centre of its head; `phase` (0 to 1)
  is its place in the cycle, so the heads of crossing roads are not green together.
- `source` is `tagged` for what the map tags there and `derived` for what the builder
  derived from the data ([Track creation](./track_creation.md)); the simulator does not read
  it.

### Decals

```json
"decals": {
  "kinds": [{"id": "tyre_marks", "textures": "decals/tyre_marks"}],
  "draw_distance_m": 120.0
}
```

- A kind's `textures` names three PNGs by their path without suffix: `_albedo.png` (sRGB
  colour, its alpha how much of the ground it covers, 0 on every border), `_normal.png`
  (OpenGL convention) and `_orm.png` (occlusion, roughness, metallic). Columns run across the
  decal, rows along its length.
- A decal is drawn up to `draw_distance_m` from the camera, fading out over the last quarter.
- The tiles list where decals lie ([Tiles](#tiles)), in `decals`, positions in the world's
  ROS frame:

```json
{
  "decals": [{"kind": "tyre_marks", "position_m": [412.3, -88.1, 102.4], "yaw_deg": 35.2,
              "size_m": [11.5, 2.0], "opacity": 0.62}]
}
```

- `kind` is the `id` of one of `kinds`; `size_m` is the decal's length along `yaw_deg`
  (counter-clockwise from x seen from above) and its width; `opacity` (0 to 1) scales its
  alpha. A decal is projected straight down onto the ground (what the `terrain` surface
  draws), from a metre above `position_m` to a metre below, and onto nothing else: not the
  vehicle, a wall or a tree.
