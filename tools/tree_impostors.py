"""Render the default track's tree impostors from Poly Haven's CC0 tree models.

    BLENDER_PYTHON=/path/to/python-with-bpy python3 tools/tree_impostors.py

As the real tracks' impostors are made (the experiment's make_tree_impostors.py): each variant
of fir_tree_01, pine_tree_01 and jacaranda_tree (Poly Haven, CC0) is rendered by Blender's
Cycles from VIEWS directions over half a turn, orthographic, on a transparent background, into
one atlas PNG per variant, RENDER_CARD_PX wide a view. The models (the 1K .blend files and their
textures, checked against Poly Haven's MD5s) are downloaded to build/polyhaven/models and the
atlases rendered to build/polyhaven/impostors, once; default_packs.py downsizes them into the
pack. BLENDER_PYTHON names a Python with Blender's `bpy` module (Blender 4.2).

Needs network access the first time, and Pillow.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import fetch_textures

REPOSITORY = Path(__file__).resolve().parent.parent
CACHE = REPOSITORY / "build" / "polyhaven"
MODELS = CACHE / "models"
ATLASES = CACHE / "impostors"
RENDERER = Path(__file__).resolve().parent / "render_tree_impostors.py"
VIEWS = 3
RENDER_CARD_PX = 512
# Each model's 1K .blend, as Poly Haven's API lists it, and the variants it holds.
MODEL_MD5 = {
    "fir_tree_01": "a08031ea8ffb49711b294e1c8213a909",
    "pine_tree_01": "e6d9e76cc8dfb58e23813c264f7736e6",
    "jacaranda_tree": "1b827c7c364c6ebb2cbbff0f02b52a15",
}
# Every variant, its model, kind and size in metres (a view's width and height), as rendered.
VARIANTS = {
    "fir_tree_01_a": ("fir_tree_01", "conifer", 7.33, 18.93),
    "fir_tree_01_b": ("fir_tree_01", "conifer", 6.61, 14.06),
    "fir_tree_01_c": ("fir_tree_01", "conifer", 6.94, 14.52),
    "pine_tree_01_a": ("pine_tree_01", "conifer", 9.01, 20.37),
    "pine_tree_01_b": ("pine_tree_01", "conifer", 8.39, 14.88),
    "pine_tree_01_c": ("pine_tree_01", "conifer", 8.76, 17.54),
    "jacaranda_tree": ("jacaranda_tree", "broadleaf", 24.83, 19.47),
}
CREDIT = (
    "Poly Haven (https://polyhaven.com): models fir_tree_01, pine_tree_01 and jacaranda_tree "
    "by Rico Cilliers and Rob Tuytel, drawn as impostors rendered from them, CC0"
)


def fetch_model(asset, models=MODELS):
    """Download a model's 1K .blend and the textures it names into models/<asset>, once."""
    listed = json.loads(fetch_textures.download(f"https://api.polyhaven.com/files/{asset}"))
    blend = listed["blend"]["1k"]["blend"]
    if blend["md5"] != MODEL_MD5[asset]:
        raise ValueError(
            f"{asset}: Poly Haven lists MD5 {blend['md5']}, expected {MODEL_MD5[asset]}"
        )
    files = {f"{asset}.blend": blend} | blend["include"]
    for relative, listing in files.items():
        fetch_textures.fetch_file(listing["url"], listing["md5"], models / asset / relative)


def atlas_path(variant, atlases=ATLASES):
    """Return where a variant's rendered atlas is."""
    return atlases / f"{variant}.png"


def render(models=MODELS, atlases=ATLASES):
    """Render every variant's atlas with Blender, checking its size is VARIANTS'."""
    python = os.environ.get("BLENDER_PYTHON")
    if not python:
        raise RuntimeError("BLENDER_PYTHON must name a Python with Blender's bpy module")
    atlases.mkdir(parents=True, exist_ok=True)
    for asset in MODEL_MD5:
        variants = [name for name, (model, *_) in VARIANTS.items() if model == asset]
        subprocess.run(
            [python, str(RENDERER), str(models / asset / f"{asset}.blend"), str(atlases)]
            + [f"{variant}_LOD0" for variant in variants]
            + [f"--views={VIEWS}", f"--card-px={RENDER_CARD_PX}"],
            check=True,
        )
    measured = json.loads((atlases / "sizes.json").read_text())
    for variant, (_, _, width_m, height_m) in VARIANTS.items():
        if measured[variant] != [width_m, height_m]:
            raise ValueError(
                f"{variant}: rendered {measured[variant]}, expected {width_m, height_m}"
            )


def ensure(models=MODELS, atlases=ATLASES):
    """Fetch and render whatever atlas is missing."""
    if all(atlas_path(variant, atlases).exists() for variant in VARIANTS):
        return
    for asset in MODEL_MD5:
        fetch_model(asset, models)
    render(models, atlases)


if __name__ == "__main__":
    if len(sys.argv) != 1:
        sys.exit(__doc__)
    ensure()
