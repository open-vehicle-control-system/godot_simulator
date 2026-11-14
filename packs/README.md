# Packs

Pack sources: one directory per pack, `tracks/<id>/` or `vehicles/<id>/`, holding its
`pack.json`, its licence and the commands that build its files. Built files are not committed;
a pack is released as an archive of its built directory. The format is in
[docs/pack_format.md](../docs/pack_format.md).

The two packs the simulator bundles, `default_track` and `default_car`, are the exception:
generated from code alone by `tools/default_packs.py` (no external data, CC0), they are
committed as built in `simulator/default_packs/`, so a clean clone runs, and rebuilt there:

```sh
GODOT=godot python3 tools/default_packs.py
```

Until the builders are ported to `tools/`, `tools/pack_experiment.py` packages the Godot
experiment's outputs for local use:

```sh
GODOT=godot python3 tools/pack_experiment.py ../carla build/packs
./simulate.sh --track=mettet --vehicle=ovcs1 --packs=build/packs
```
