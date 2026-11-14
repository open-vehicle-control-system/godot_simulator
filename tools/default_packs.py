"""Build the packs the simulator bundles: the default track and the default vehicle.

    python3 tools/default_packs.py [OUT_DIR]

OUT_DIR is simulator/default_packs by default, where the built packs are committed; the
sources of their textures go to build/default_packs_work. Both packs are generated from code
alone (default_track.py, default_vehicle.py), from fixed seeds, and are CC0. The textures
are compressed into DDS by Godot's own encoders (compress_textures.gd, run with the Godot
named by the GODOT environment variable).

Needs numpy and Pillow, and Godot 4.6 to compress the textures.
"""

import json
import shutil
import sys
from pathlib import Path

import default_track
import default_vehicle
import pack_experiment

REPOSITORY = Path(__file__).resolve().parent.parent
OUT = REPOSITORY / "simulator" / "default_packs"
WORK = REPOSITORY / "build" / "default_packs_work"
LICENCE = (
    "This pack was generated from code by tools/default_packs.py and is dedicated to the\n"
    "public domain under CC0 1.0: https://creativecommons.org/publicdomain/zero/1.0/\n"
)


def write_manifest(directory, manifest):
    """Write a pack's pack.json and its licence."""
    (directory / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (directory / "LICENCE.txt").write_text(LICENCE)


def build(out, work):
    """Write both packs into `out`, emptied first; return the DDS compression jobs left to run."""
    for pack_id in (default_track.TRACK_ID, default_vehicle.VEHICLE_ID):
        if (out / pack_id).exists():
            shutil.rmtree(out / pack_id)
    vehicle = out / default_vehicle.VEHICLE_ID
    write_manifest(vehicle, default_vehicle.write(vehicle))
    track = out / default_track.TRACK_ID
    manifest, jobs = default_track.write(track, work / default_track.TRACK_ID)
    write_manifest(track, manifest)
    for _, _, compressed in jobs:
        compressed.parent.mkdir(parents=True, exist_ok=True)
    return jobs


def main(out):
    """Build both packs into `out`, textures compressed."""
    pack_experiment.compress_textures(build(out, WORK))
    print(f"{out}: {default_track.TRACK_ID}, {default_vehicle.VEHICLE_ID}")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit(__doc__)
    main(Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else OUT)
