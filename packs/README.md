# Packs

Pack sources: one directory per pack, `tracks/<id>/` or `vehicles/<id>/`, holding its
`pack.json`, its licence and the commands that build its files. Built files are not committed;
a pack is released as an archive of its built directory. The format is in
[docs/pack_format.md](../docs/pack_format.md).

Until the builders are ported to `tools/`, `tools/pack_experiment.py` packages the Godot
experiment's outputs for local use:

```sh
GODOT=godot python3 tools/pack_experiment.py ../carla build/packs
./simulate.sh --track=mettet --vehicle=ovcs1 --packs=build/packs
```
