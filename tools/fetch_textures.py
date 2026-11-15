"""Download CC0 PBR texture sets from Poly Haven and ambientCG.

    python3 tools/fetch_textures.py OUT_DIR SOURCE:ASSET...

SOURCE is `polyhaven` or `ambientcg`, ASSET the set's id there (`polyhaven:asphalt_track`,
`ambientcg:Grass004`). Each set becomes OUT_DIR/<asset>_albedo.jpg, _normal.jpg (OpenGL
convention) and _rough.jpg at 2K, with OUT_DIR/<asset>.source.txt naming where it came from. A
set already in OUT_DIR is kept.
"""

import hashlib
import io
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

USER_AGENT = "pack-texture-fetcher"
MAPS = ("albedo", "normal", "rough")
POLYHAVEN_MAPS = {"albedo": "Diffuse", "normal": "nor_gl", "rough": "Rough"}
AMBIENTCG_MAPS = {"albedo": "Color", "normal": "NormalGL", "rough": "Roughness"}


def download(url):
    """Return the bytes at `url`."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def md5(path):
    """Return a file's MD5, as Poly Haven lists its files'."""
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_file(url, expected_md5, path):
    """Return `path` holding the file at `url`, downloaded unless it is there; checked by MD5."""
    if path.exists() and md5(path) == expected_md5:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(download(url))
    if md5(path) != expected_md5:
        raise ValueError(f"{path}: MD5 {md5(path)} from {url}, expected {expected_md5}")
    print(f"{path}: {url}")
    return path


def polyhaven_set(asset):
    """Return a Poly Haven set's maps as {map: jpeg bytes} and its page."""
    files = json.loads(download(f"https://api.polyhaven.com/files/{asset}"))
    maps = {name: download(files[key]["2k"]["jpg"]["url"]) for name, key in POLYHAVEN_MAPS.items()}
    return maps, f"https://polyhaven.com/a/{asset}"


def ambientcg_set(asset):
    """Return an ambientCG set's maps as {map: jpeg bytes} and its page."""
    archive = zipfile.ZipFile(
        io.BytesIO(download(f"https://ambientcg.com/get?file={asset}_2K-JPG.zip"))
    )
    maps = {
        name: archive.read(f"{asset}_2K-JPG_{suffix}.jpg")
        for name, suffix in AMBIENTCG_MAPS.items()
    }
    return maps, f"https://ambientcg.com/a/{asset}"


SOURCES = {"polyhaven": polyhaven_set, "ambientcg": ambientcg_set}


def set_name(asset):
    """Return the file prefix of a set: its id in lower case."""
    return asset.lower()


def fetch(out, source, asset):
    """Write one set into `out` unless it is there."""
    name = set_name(asset)
    if all((out / f"{name}_{kind}.jpg").exists() for kind in MAPS):
        return
    maps, page = SOURCES[source](asset)
    for kind, content in maps.items():
        (out / f"{name}_{kind}.jpg").write_bytes(content)
    (out / f"{name}.source.txt").write_text(f"{page} (CC0)\n")
    print(f"{out / name}: {page}")


def main(out, sets):
    """Fetch every `source:asset` of `sets` into `out`."""
    out.mkdir(parents=True, exist_ok=True)
    for named in sets:
        source, asset = named.split(":", 1)
        fetch(out, source, asset)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), sys.argv[2:])
