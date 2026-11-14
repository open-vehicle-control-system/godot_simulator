# OVCS Godot simulator

A visual simulator for vehicles built on [OVCS](https://github.com/open-vehicle-control-system/ovcs).
Your vehicle's own OVCS stack drives it over OVCS's simulator link; the simulator shows it in a
realistic world and reports what it senses: pose, motion, IMU and a rectified stereo pair.

Godot visualises: driving comes from OVCS (joystick messages, Nav2, a simulated radio). The one
exception is `--keyboard`, which drives with the arrow keys so a track can be looked around
without OVCS.
Tracks and vehicles are **packs**, loaded at runtime and released apart from the simulator,
each under its own licence. The simulator ships none.

## Run

You need Godot 4.6 (`mise install` puts it on the PATH, or set `GODOT` to its binary) and a
track pack and a vehicle pack.

```sh
./simulate.sh --track=mettet --vehicle=ovcs1 --packs=../my-packs --link=127.0.0.1:7400
```

| Option | Meaning |
|---|---|
| `--track=ID`, `--vehicle=ID` | the packs to load (required) |
| `--packs=DIR` | a directory of packs, searched before `packs/` next to the executable and `user://packs`; repeatable |
| `--link=HOST[:PORT]` | the OVCS simulator link (port 7400 by default); without it the vehicle stands still |
| `--keyboard` | drive with the arrow keys instead, to look around a track without OVCS |
| `--hold=KM_H,STEERING_DEG` | hold this speed and front wheel angle (positive left) instead, without OVCS: for a screenshot of a moving vehicle |
| `--camera=VIEW` | `chase`, `cockpit`, `bonnet`, `side` or `front` |
| `--stereo-record=DIR` | record stereo pairs, poses and calibration ([Stereo camera](./docs/stereo.md)) |
| `--show-stereo` | show the stereo pair at start |
| `--spawn=X,Y,Z,YAW_DEG` | start there instead of at the track's spawn, in the track's frame as `spawn` in its `pack.json` |
| `--eye=X,Y,Z` | look at the vehicle from this fixed point of the track's frame |
| `--screenshot=FILE` | save the window as a PNG once the world has rendered, print what the window and the other viewports (stereo cameras, mirrors) cost to render, quit |
| `--timing` | print when the first frame was drawn and, every five seconds, the worst frame time and how many frames ran over 33 ms |

Keys: C cycles the views, V shows the stereo pair, F11 toggles full screen, Esc quits. Under
`--keyboard` the arrow keys drive: Up accelerates, Down brakes then reverses, Left and Right steer.

## Checks

```sh
mise run check      # gdformat, gdlint, ruff, the headless tests and the tools' tests
mise run test       # the tests only; or ./simulator/tests/run_tests.sh [NAME_FILTER]
```

## Layout

| Path | What |
|---|---|
| `simulator/` | the Godot project ([Architecture](./docs/architecture.md)) |
| `packs/` | pack sources: manifest, licence and build recipe per pack ([Pack format](./docs/pack_format.md)) |
| `tools/` | Python programs that build packs |
| `docs/` | the guides ([index](./docs/README.md)) |
| `backlog/` | the work queue ([Backlog.md](https://github.com/MrLesk/Backlog.md)) |

Building a track: follow [docs/track_creation.md](./docs/track_creation.md), the rules and
steps for a person or any AI assistant. AI tools that read `AGENTS.md` are pointed to it; Claude
Code also loads it through the project's `track-creator` skill.

Contributing: read [CLAUDE.md](./CLAUDE.md) for the process and [CODE_STYLING.md](./CODE_STYLING.md)
for the code rules. Licence: MIT ([LICENCE.txt](./LICENCE.txt)); packs carry their own.
