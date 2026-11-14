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
`await wait_physics_frames(count)`. Assertions: `assert_true`, `assert_eq`, `assert_almost_eq`
(numbers or vectors), `fail`. The runner exits with 1 when a test fails or a script does not
load, and `run_tests.sh` also fails the run when Godot reports a `SCRIPT ERROR`: an error inside
a test aborts it without failing an assertion. A frame passes between two tests, so what one
queued to free is gone before the next starts.

Helpers:

- `PackFixtures` writes small generated packs (a flat track, a box-shaped vehicle, a glTF
  model) into a fresh directory, so no test depends on a real pack.
- `LinkTestServer` is OVCS's side of the link: it accepts the simulator, sends drives and
  collects what the simulator sends.

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
