# OVCS Godot simulator: design

## Intent

A simulator for vehicles built on OVCS. The vehicle's own OVCS stack (VMS, simulated hardware,
ROS bridge) decides what its actuators do; this simulator is the vehicle's one dynamics model:
it moves the vehicle by its actuators' efforts in a realistic world and senses that world for
it: pose, motion, wheels, IMU and a stereo camera pair.

Tracks and vehicles are content, released on their own schedule and under their own licences,
apart from the simulator.

The one exception is a pair of bundled defaults, so a clean clone runs with one command: a
small test circuit and a mid-size sedan, built by `tools/default_packs.py` and committed as
built in `simulator/default_packs/`. The track is generated from code, its trees and sky from Poly Haven's CC0 models and HDRI; the car's
model is the one exception to generated, CC0 content: "Generic Sedan Car" by Márcio Meireles
(MMC Works), CC BY 4.0, credited with its modifications in the pack.

## Goals

- Move a vehicle by the actuator efforts OVCS sends over the simulator link, in Godot 4.7:
  body, suspension, each wheel's spin, tyres and contact with the world, so what the VMS
  measures can differ from how the vehicle moves as it does on the road.
- Report the vehicle's state, its wheels and a rectified stereo pair over the link, and record
  pairs, poses and calibration to disk for offline vision work.
- Load tracks and vehicles from packs found at runtime; none ship with the simulator but the
  two defaults (CC0, but for the default car's credited CC BY 4.0 model).
- Follow the OVCS development process and code rules, adapted to GDScript and Python.

## Non-goals

- Driving input in normal use. Godot visualises; driving comes from OVCS (joystick messages,
  Nav2, a simulated radio). The exception is `--keyboard`: the arrow keys drive, so a track can
  be looked around without OVCS; it excludes `--link`.
- Lockstep with OVCS. OVCS's VMS runs on the wall clock, so the simulation keeps real time as
  a hardware-in-the-loop bench does; runs over the link repeat within tolerances, not bit for
  bit.
- A code dependency on OVCS. The link's wire format is the only contract.

## Anti-goals

- Third-party track or vehicle data in the simulator repository, or a simulator release that
  carries a third-party licence because of its content.
- Hard-coded track or vehicle names in the simulator.
- A pack format that runs code: packs are data.

## Constraints

- Wire format: OVCS `SimulatorCore.Link.Protocol`, its actuation contract OVCS's TASK-129.
  TCP, each packet a 32-bit big-endian length, then a 16-bit big-endian header length, a JSON
  header and an optional binary body. `actuation` (drive and brake torques, steering, the
  driveline's inertia) and `instruments` come in; `state` (with each wheel's angle, spin and
  contact) and `image` go out, in ROS conventions (REP-103: `base_link` x forward, y left,
  z up).
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

One side owns the vehicle's dynamics: two models integrating one vehicle drift apart, and
correcting one from the other makes it oscillate. It has to be a full model (body in 3D, each
wheel's spin, tyre forces, contact with the world), as CarMaker, ASM or CarSim are, since a
lifted wheel, wheels spinning on ice and a wall stopping the body while the VMS still commands
torque are what testing the VMS needs; only the side with the world's geometry and a physics
engine can produce them.

1. **A rigid body on four sprung wheels, driven by actuator efforts (chosen).** A Jolt rigid
   body; per wheel a suspension found by a ray, its spin through an open differential with the
   driveline's inertia, brakes that hold, a tyre with combined slip and relaxation. OVCS sends
   torques and steering; OVCS's `SimulatorCore.Vehicle` stays a flat-ground model for fast runs
   without the simulator.
2. **OVCS owns the dynamics, the simulator follows a pose.** One owner too, but OVCS's model
   has no world: no walls, slopes, lifted wheels or rollover.
3. **A kinematic follower of a commanded speed, with the simulator's own model.** Two models
   of one vehicle: what OVCS sent and what the simulator did disagree, and OVCS integrated its
   own odometry on top.
4. **Godot's `VehicleBody3D`.** Its wheels are rays with a simple friction model: no combined
   slip, no differential, no driveline inertia.

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
| `link/link_protocol.gd` | Pure: packet framing, encode `state` and `image`, decode `actuation` and `instruments`; Godot ↔ ROS frames |
| `link/simulator_link.gd` | The TCP client: reconnects, reads actuations, sends state every physics step and the images it is given |
| `vehicle/tyre.gd`, `vehicle/wheels.gd` | Pure: a tyre's force from its tread; the wheels' spin, brakes and differential |
| `vehicle/vehicle.gd` | The vehicle: a rigid body on four sprung wheels, moved by its actuation, parked without one |
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
- An `actuation` sets the drive and brake torques, the steering and the driveline's inertia.
  No actuation for 0.5 s: no drive torque, brakes and steering as last sent. No connection:
  the vehicle is parked.
- Unknown packets are dropped with a warning.

### Tests

GDScript tests run headless (`godot --headless --path simulator -s tests/run_tests.gd`), with
a runner in the repository rather than a third-party add-on. Pure parts are tested directly;
the link is tested end to end against a test server that speaks the OVCS side of the protocol,
with the test packs. Physics runs at 60 Hz; the runner steps frames as fast as the machine
goes.

## Left to the builder

- Porting the pack builders from the experiments (LiDAR/orthophoto/OSM circuits and the
  streamed town, the vehicle builder) into `tools/`, cleaned to these rules.
- The simulator surfaces' shaders (road markings and kerbs, splat terrain, facades,
  impostor trees), ported as track features reach the pack format.
- Cockpit instruments, mirrors.
