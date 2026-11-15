# CLAUDE.md

Guidance for Claude Code working in this repository. It follows the
[OVCS](https://github.com/open-vehicle-control-system/ovcs) development process and code rules,
adapted to GDScript and Python.

## Orient yourself first

- [README.md](./README.md): what this is and how to run it.
- [CODE_STYLING.md](./CODE_STYLING.md): conventions to match. Read it before non-trivial changes.
- [docs/README.md](./docs/README.md): index of the guides.
- [docs/architecture.md](./docs/architecture.md): the simulator, packs and the OVCS link.
- [docs/pack_format.md](./docs/pack_format.md): what a track or vehicle pack contains.
- [docs/simulator_link.md](./docs/simulator_link.md): the wire protocol OVCS speaks.
- [docs/track_creation.md](./docs/track_creation.md): the rules and steps for building a track (loaded by the `track-creator` skill).
- [docs/superpowers/specs/](./docs/superpowers/specs): agreed designs.
- [backlog/](./backlog): the work queue, managed with [Backlog.md](https://github.com/MrLesk/Backlog.md) (`backlog task list --plain`).

Prefer updating these docs over duplicating their content here.

## Workflow rules

- **Go straight to the point.** In replies, code comments and docs alike: say what matters, once, and stop.
- **Don't commit until the user validates.** Make the edits, run the checks, and stop. Wait for the user to confirm the change works on their end before running `git commit`.

## Development process

- **Work starts from a backlog task.** Pick one whose dependencies are done, set it `In Progress` with yourself as assignee, and write its acceptance criteria before the code. Work found on the way becomes a new task, not extra scope. A task is `Done` when its change merges.
- **Design before code** for anything that adds or changes behaviour: the problem, the options considered and the one chosen go in the task (or a spec under `docs/superpowers/specs/` for a project), agreed before implementation starts.
- **Plan large work as a sequence of small changes**, each a backlog task, each shippable on its own.
- **Test first.** A failing test that shows the missing behaviour comes before the code that adds it; see [Tests](./CODE_STYLING.md#tests).
- **Debug from the root cause.** Reproduce, find why, capture it in a failing test, then fix.
- **Evidence before claims.** Run the checks and read their output before stating that something works; say plainly what could not be verified.
- **Checks before review:** `mise run check` (format, lint, tests; see [README.md](./README.md#checks)).
- **Review by someone other than the author.** Verify each finding against the code before applying it.
- **Assistants** use the superpowers process skills (brainstorming, writing-plans, test-driven-development, systematic-debugging, verification-before-completion, requesting-code-review, receiving-code-review); the project enables the plugin in `.claude/settings.json`. Where a skill and this repository's guides disagree, the guides win.

## Git commit policy

- **One author identity per contributor**, from that contributor's git config.
- **No `Signed-off-by:`**, and no `Co-Authored-By:` or other co-authorship trailer: an AI is never a co-author.
- **Disclose AI assistance** with one trailer, following the [kernel.org convention](https://www.kernel.org/doc/html/latest/process/coding-assistants.html): `Assisted-by: Claude:<current-model-id>`.
- **Never link to or identify a session**: no transcript URLs, session ids or "see the conversation".
- **English** for everything written into the repository.
- Subject: imperative mood, at most 72 characters, no trailing period. One logical change per commit. A body only when the *why* is not obvious from the diff.
- **Messages describe the change, not the session**: no first person, no addressing the user, no process narration, no quoting the conversation. Measured numbers and the reasoning behind a decision are welcome.
- **A PR description is Markdown**: one line per paragraph, numbers in tables, identifiers in backticks.

## Code comments state present facts

- No history, no process narration, no session references.
- Comment only a non-obvious *why*, an invariant or a trap; one line where one line does.
- A better name beats a comment. A stale comment is deleted, not amended.
- No measurements or derived numbers next to a tunable value: they go in the commit message or a guide.

## Repository notes

- **The simulator ships no third-party content.** Its only bundled packs are the defaults, `default_track` and `default_car` in `simulator/default_packs/`, built by `tools/default_packs.py`, committed so a clean clone runs, and rebuilt (not edited) when their builder changes. They are CC0 (generated from code, the track's trees and sky from Poly Haven's CC0 models and HDRI, credited), with one exception: the default car's model is "Generic Sedan Car" by Márcio Meireles (MMC Works), CC BY 4.0, credited with its modifications in the pack (`pack.json`, `LICENCE.txt`, `ATTRIBUTION.md`) and in the README; its source is not committed (`tools/default_car_model.py` says where to put it). Apart from those two ids as `SimulatorOptions`' defaults, nothing under `simulator/` names a track or a vehicle; it takes what differs from the pack. Tests generate their own packs (`simulator/tests/pack_fixtures.gd`) or load the defaults.
- **Packs are data**, released on their own with their own licence: never code, never a simulator dependency. Generated pack payloads are not committed, but for the bundled defaults; `packs/<kind>/<id>/` holds the manifest, licence and build recipe.
- **Godot visualises.** Driving comes from OVCS over the link; keys only change the view, except under `--keyboard`, which drives with the arrow keys to look around a track without OVCS (never together with `--link`).
- **The link's wire format is OVCS's** (`SimulatorCore.Link.Protocol`); a change to it starts in OVCS.
- Godot 4.6. Run `./simulate.sh` (see [README.md](./README.md)).
