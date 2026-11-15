---
title: Testing
description: How the simulator's tests run and how to write one.
---

The tests are GDScript, run headless by a runner in the repository:

```sh
./simulator/tests/run_tests.sh            # every test
./simulator/tests/run_tests.sh drive      # tests whose name contains "drive"
```

A test script is `simulator/tests/test_*.gd`, extends `TestCase`, and its tests are methods
named `test_*`. It runs inside the scene tree, so a test may add nodes and
`await wait_physics_frames(count)`. The runner steps each frame by 1/60 s of simulated time as
fast as the machine goes (`--fixed-fps 60`): a minute of driving takes seconds. A test of
something that takes real time (encoding on a worker thread) paces itself. Assertions: `assert_true`, `assert_eq`, `assert_almost_eq`
(numbers or vectors), `fail`. The runner exits with 1 when a test fails or a script does not
load, and `run_tests.sh` also fails the run when Godot reports a `SCRIPT ERROR`: an error inside
a test aborts it without failing an assertion. After each test the runner frees the nodes it
added and a frame passes, so no body of one test stands in the next one's way.

Helpers:

- `PackFixtures` writes small generated packs (a flat track, a box-shaped vehicle, a glTF
  model) into a fresh directory, so no test depends on a real pack.
- The bundled default packs (`res://default_packs`) are real packs every checkout has:
  `test_default_packs.gd` starts the simulator without options on them and drives.
- `VehicleFixtures` stands a vehicle on flat ground, settled on its springs, and holds it at a
  speed (`hold`) or lets the test actuate it alone (`release`).
- `LinkTestServer` is OVCS's side of the link: it accepts the simulator, sends actuations and
  instruments, and collects what the simulator sends.

Headless Godot does not render, but it does compile shaders: `test_shaders.gd` loads every
`.gdshader` and fails on one that does not compile (it would draw its surface white). Tests
that need images pass a capture function returning generated images. What only a display shows (the views, the rendered pair) is checked by running
`./simulate.sh` with `--stereo-record`.

What must be rendered to be checked is in `simulator/tests/rendered/test_*.gd`, run in a
window, with a display and a GPU:

```sh
./simulator/tests/run_rendered_tests.sh   # ground truth, camera effects, identical frames and recordings
```

The pack builders in `tools/` are tested with Python's `unittest` (they need numpy and Pillow):

```sh
python3 -m unittest discover -s tools/tests
```
