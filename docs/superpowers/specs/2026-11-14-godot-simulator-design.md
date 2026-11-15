# OVCS Godot simulator: design

## Intent

A visual simulator for vehicles built on OVCS. The vehicle's own OVCS stack (VMS, simulated
hardware, ROS bridge) decides how the vehicle moves; this simulator shows it moving in a
realistic world and senses that world for it: pose, motion, IMU and a stereo camera pair.

Tracks and vehicles are content, released on their own schedule and under their own licences,
apart from the simulator.

The one exception is a pair of bundled defaults, so a clean clone runs with one command: a
small test circuit and a mid-size sedan, built by `tools/default_packs.py` and committed as
built in `simulator/default_packs/`. The track is generated from code alone, CC0; the car's
model is the one exception to generated, CC0 content: "Generic Sedan Car" by Márcio Meireles
(MMC Works), CC BY 4.0, credited with its modifications in the pack.

## Goals

- Show a vehicle driven by OVCS over the simulator link, in Godot 4.6.
- Report the vehicle's state and a rectified stereo pair over the link, and record pairs,
  poses and calibration to disk for offline vision work.
- Load tracks and vehicles from packs found at runtime; none ship with the simulator but the
  two defaults (CC0, but for the default car's credited CC BY 4.0 model).
- Follow the OVCS development process and code rules, adapted to GDScript and Python.

## Non-goals

- Driving input in normal use. Godot visualises; driving comes from OVCS (joystick messages,
  Nav2, a simulated radio). The exception is `--keyboard`: the arrow keys drive, so a track can
  be looked around without OVCS; it excludes `--link`.
- A vehicle dynamics model. The vehicle follows OVCS's commanded speed and steering (OVCS's
  `SimulatorCore.Vehicle` computes them); a world with its own dynamics is OVCS TASK-81.
- A code dependency on OVCS. The link's wire format is the only contract.

## Anti-goals

- Third-party track or vehicle data in the simulator repository, or a simulator release that
  carries a third-party licence because of its content.
- Hard-coded track or vehicle names in the simulator.
- A pack format that runs code: packs are data.

## Constraints

- Wire format: OVCS `SimulatorCore.Link.Protocol`, as of the `feat/simulator-godot` branch.
  TCP, each packet a 32-bit big-endian length, then a 16-bit big-endian header length, a JSON
  header and an optional binary body. `drive` (`speed_m_s`, `steering_rad`) comes in; `state`
  and `image` go out, in ROS conventions (REP-103: `base_link` x forward, y left, z up).
- The VMS measures the wheels against the wall clock: the simulation keeps real time and never
  waits on vsync.
- Track data comes from CC-BY 4.0 (Wallonia LiDAR and orthophotos) and ODbL (OpenStreetMap)
  sources, with CC0 textures; each track pack states its licence and attribution.
- The OVCS1 body model in the experiments is a third-party mod that may not be redistributed:
  a releasable OVCS1 pack needs its own model.

## Approaches

### Where content lives

1. **Packs as data directories loaded at runtime (chosen).** A pack is a directory with a
   `pack.json` manifest, glTF scenes and data files. The simulator parses glTF at runtime
   (`GLTFDocument`), as the experiments already do for every world. Any tool that writes glTF
   can build a pack, packs are inspectable in Blender, and they cannot carry code.
2. **Godot resource packs (`.pck`).** Imported once in the editor, they load faster and can
   bring their own materials, but they tie a pack to the Godot version that built it, need the
   editor to build and can carry scripts.
3. **Content inside the simulator project, excluded per release.** Simplest to start, but the
   licences mix in one tree and a vehicle maker cannot release a pack without a simulator
   release.

### How the vehicle moves

1. **Kinematic follower (chosen).** A bicycle model about the rear axle at the commanded speed
   and steering, kept on the ground by a ray. OVCS already owns the motion; this is what the
   link's `drive` message means today.
2. **Godot `VehicleBody3D` dynamics.** Needs actuations rather than a speed on the link: OVCS
   TASK-81 decides that first.

### Repository shape

1. **One repository, separate release units (chosen).** `simulator/` (the Godot app, MIT),
   `packs/` (pack sources: each pack directory carries its own manifest and licence and is
   released as its own archive), `tools/` (the Python builders that generate packs from public
   data). Generated pack payloads are not committed, only what builds them, except the tiny
   test packs the simulator's tests load and the bundled defaults (`simulator/default_packs/`,
   small enough to sit in the repository).
2. **One repository per pack.** Cleanest licence boundary, but a format change then spans many
   repositories while the format is still young. A pack can move to its own repository later
   without changing the format.

## Design

### Simulator (`simulator/`)

| Part | Role |
|---|---|
| `main.gd` | Composition root: reads options, loads the track and vehicle packs, wires the link, the stereo camera and the views |
| `packs/` | Finds packs on the search path, validates `pack.json`, loads a track or a vehicle |
| `link/link_protocol.gd` | Pure: packet framing, encode `state` and `image`, decode `drive`; Godot ↔ ROS frames |
| `link/simulator_link.gd` | The TCP client: reconnects, reads drives, sends state every physics step and the images it is given |
| `vehicle/bicycle_model.gd` | Pure: the next rear-axle position, yaw and yaw rate from speed, steering and wheelbase |
| `vehicle/vehicle.gd` | The vehicle node: model from its pack, follows the drive, stops when drives stop, keeps an odometer |
| `sensors/stereo_camera.gd` | Two parallel pinhole cameras on the vehicle's mount: intrinsics, capture |
| `sensors/stereo_sender.gd` | Sends pairs over the link at the camera rate |
| `sensors/stereo_recorder.gd` | Writes pairs, poses and `calib.json` to a directory |
| `view/` | The views (chase, cockpit, bonnet, side, front) and the HUD |
| `tests/` | A headless test runner and the tests |

Options are command-line arguments after `--`: `--track=ID`, `--vehicle=ID` (the bundled
`default_track` and `default_car` when left out),
`--packs=DIR` (repeatable, added to the search path), `--link=HOST:PORT`, `--camera=VIEW`,
`--stereo-record=DIR`.

### Pack format (version 1)

```text
<pack>/
  pack.json      kind, id, name, version, licence, attribution, format version
  ...            what the kind needs, named in pack.json
```

- **Vehicle pack:** `vehicle.glb` (nodes `Body`, `Wheel`, optional `Cockpit_*`) and in
  `pack.json` the geometry the simulator needs (axles, track widths, wheel radius, body box),
  the driver's eye, and the stereo mount and optics. A pack without a model gets a box and
  cylinders.
- **Track pack:** a tile set (a tile index, one glb and one height grid per tile, a coarse
  far terrain), a spawn pose, optional route and environment
  (sky). Materials are plain glTF PBR; a material may name a simulator surface (road, terrain,
  facade) that the simulator renders with its own shader and the pack's textures.

The search path is the `--packs` directories, then `packs/` next to the executable, then
`user://packs`, then the bundled `res://default_packs`. A pack is looked up by its `id`; two packs with one id are an error.

### Link behaviour

- Connects to `--link`, retrying every second; a new connection replaces the old one.
- On every physics step: a `state` packet. At the stereo rate: one `image` per camera, JPEG,
  encoded off the main thread, skipped when the previous pair is still encoding.
- A `drive` sets the vehicle's commanded speed and steering. No drive for 0.5 s, or no
  connection: the vehicle is commanded to stop.
- Unknown packets are dropped with a warning.

### Tests

GDScript tests run headless (`godot --headless --path simulator -s tests/run_tests.gd`), with
a runner in the repository rather than a third-party add-on. Pure parts are tested directly;
the link is tested end to end against a test server that speaks the OVCS side of the protocol,
with the test packs.

## Left to the builder

- Porting the pack builders from the experiments (LiDAR/orthophoto/OSM circuits and the
  streamed town, the vehicle builder) into `tools/`, cleaned to these rules.
- The simulator surfaces' shaders (road markings and kerbs, splat terrain, facades,
  impostor trees), ported as track features reach the pack format.
- Cockpit instruments, mirrors.
