# Code Styling

Conventions for contributing to this repository, adapted from
[OVCS's](https://github.com/open-vehicle-control-system/ovcs/blob/main/CODE_STYLING.md) to
GDScript and Python. Where a rule here and a language's own idiom disagree, the idiom wins and
the rule gets fixed. The process (a backlog task, a failing test first, evidence before a
claim) is in [CLAUDE.md](./CLAUDE.md#development-process).

## Layout principles

- **The simulator ships no third-party content.** `simulator/` works for any track and
  vehicle and takes what differs from the pack: geometry, optics, spawn pose, surfaces. Its
  only bundled packs are the defaults in `simulator/default_packs/`, built by
  `tools/default_packs.py`: CC0 (generated from code, the track's trees and sky from Poly Haven's
  CC0 assets), but for one exception, the default
  car's model ("Generic Sedan Car", CC BY 4.0, credited in its pack); otherwise a track or vehicle appears in the simulator only
  as a test pack, and their ids only as `SimulatorOptions`' defaults.
- **Packs are data.** A pack is a directory with a `pack.json` and the files it names; see
  [docs/pack_format.md](./docs/pack_format.md). Adding a pack never means editing the simulator.
- **Builders are tools.** The Python programs that generate packs from public data live in
  `tools/`; a pack's directory under `packs/` holds its manifest, licence and the commands
  that build it.

## Names, docs and comments

- **Names say what things do**, with the unit when there is one (`speed_m_s`, `timeout_s`,
  `wheel_radius_m`). When code needs a comment to be understood, first rename or extract.
- **No vague names** (`data`, `value`, `result`, `tmp`, `info`, `item`) and no single letters
  outside a short lambda or a maths formula's conventional symbols (`x`, `y`, `z`, `q`).
- **No abbreviations** beyond a domain's standard names (`imu`, `ros`, `ovcs`, `gltf`, `jpeg`)
  and units (`_m`, `_s`, `_rad`, `_deg`, `_hz`).
- **GDScript:** every script starts with `##` documentation saying what it is for; public
  functions get a `##` line under the signature. Private members start with `_`.
- **Python:** a module docstring and function docstrings, as OVCS's `@moduledoc` and `@doc`.
- **`#` comments** are for a non-obvious *why*, an invariant or a trap, at most three lines.
- **Constants are named**, with their unit: `const DRIVE_TIMEOUT_S := 0.5`.

## Design

- **A node is runtime state or a place in the scene.** Logic that only transforms values is a
  script with `static func`s (or a `RefCounted`) that a node calls, so it is tested without a
  scene tree.
- **Dependencies come in explicitly**, as arguments to `setup()` from the composition root
  (`main.gd`), never found by `get_node()` paths or autoload singletons.
- **No speculative generality.** No option, hook or setting without a current user.
- **Assertive code.** A pack field that must be there is read with `[]`, not `.get()` with a
  silent default; a malformed pack fails loading with a message naming the pack and field.
- **Untrusted input is data.** Packs and link packets are validated where they enter; they
  never select code to run.

## Functions

- **One thing, at one level of abstraction**, that its name states without "and".
- **No boolean flags that fork the body.** Two functions, or a match on a meaningful value.
- **Side effects show in the name.** A query does not also send or write.

## Errors

- **Expected failures are values**: a loader returns an error message or the loaded thing, not
  a half-built node. Bugs crash.
- **Handle and log an error once**, where something is done about it.

## Tests

- **Test first.** Write the test, watch it fail for the expected reason, then write the minimal
  code that passes.
- **Test behaviour through the public boundary**: packets in, packets out; a pack in, a scene out.
- **One behaviour per test, named after it**: `test_stops_when_drives_stop`.
- **Keep the values a test depends on in the test.**
- **No sleeping on the wall clock.** Step physics frames or inject time.
- **Table-driven tests** for many input/output cases.

Run them with `mise run test` (or `./simulator/tests/run_tests.sh`); see
[docs/testing.md](./docs/testing.md).

## Formatting and lint

- GDScript: `gdformat` and `gdlint` from gdtoolkit, configured in `gdlintrc`; tabs, as Godot.
- No multi-line lambdas in GDScript: gdtoolkit 4.5 rewrites them into code that does not parse,
  or duplicates lines around them on every run. A lambda stays on one line; anything longer is a
  named function, bound with `.bind()` when it needs arguments.
- Python: `ruff format` and `ruff check`, configured in `ruff.toml`.

## Commits

- One focused change per commit, under 400 changed lines where possible.
- Never commit generated pack payloads (but for the bundled defaults, rebuilt with
  `tools/default_packs.py`), Godot's `.godot/` cache or exported builds.
- Use `git mv` when moving files.
