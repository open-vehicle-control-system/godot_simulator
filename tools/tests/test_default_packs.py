# ruff: noqa: D102
"""Tests of the default track and vehicle packs, generated from code alone."""

import hashlib
import json
import math
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import buildings
import default_packs
import default_track
import default_vehicle
import smooth_terrain
import track_surfaces

SCRATCH = default_packs.REPOSITORY / "build" / "test_default_packs"


def file_hashes(directory):
    """Return {path relative to `directory`: SHA-256} of every file under it."""
    return {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


class BuiltPacks(unittest.TestCase):
    """The packs as the builder writes them, built twice, textures left uncompressed."""

    @classmethod
    def setUpClass(cls):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        cls.scratch = Path(tempfile.mkdtemp(dir=SCRATCH))
        cls.out = cls.scratch / "first"
        cls.jobs = default_packs.build(cls.out, cls.scratch / "work")
        cls.again = cls.scratch / "second"
        default_packs.build(cls.again, cls.scratch / "work_again")
        cls.track = cls.out / default_track.TRACK_ID
        cls.manifest = json.loads((cls.track / "pack.json").read_text())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.scratch)

    def test_two_builds_are_identical(self):
        self.assertEqual(file_hashes(self.out), file_hashes(self.again))

    def test_the_committed_packs_are_the_builders(self):
        committed = file_hashes(default_packs.OUT)
        built = file_hashes(self.out)
        for path, digest in built.items():
            self.assertEqual(committed.get(path), digest, path)
        compressed = {str(job[2].relative_to(self.out)) for job in self.jobs}
        self.assertEqual(set(committed) - set(built) - {".gdignore"}, compressed)

    def test_both_packs_are_cc0_with_a_licence(self):
        for pack_id in (default_track.TRACK_ID, default_vehicle.VEHICLE_ID):
            manifest = json.loads((self.out / pack_id / "pack.json").read_text())
            self.assertEqual(manifest["format"], 1)
            self.assertEqual(manifest["id"], pack_id)
            self.assertEqual(manifest["licence"], "CC0-1.0")
            self.assertTrue((self.out / pack_id / "LICENCE.txt").exists())

    def test_every_file_the_track_names_is_there(self):
        track = self.manifest["track"]
        compressed = {job[2] for job in self.jobs}
        named = [track["tiles"], track["far"]["scene"], track["far"]["photo"]]
        named.append(track["ground"]["road"]["lines"])
        named += [face["image"] for face in track["signs"]["faces"]]
        for path in named:
            self.assertTrue((self.track / path).exists(), path)
        sets = [layer["textures"] for layer in track["ground"]["layers"]]
        sets += [rule["textures"] for rule in track["surfaces"] if "textures" in rule]
        for textures in sets:
            for suffix in ("albedo", "normal", "rough"):
                self.assertIn(self.track / f"{textures}_{suffix}.dds", compressed)
        for impostor in track["trees"]["impostors"]:
            self.assertIn(self.track / impostor["atlas"], compressed)

    def test_the_ground_layers_share_one_size(self):
        sides = set()
        for layer in self.manifest["track"]["ground"]["layers"]:
            name = layer["textures"].split("/")[-1]
            for job in self.jobs:
                if job[1].name.startswith(f"{name}_"):
                    with Image.open(job[1]) as image:
                        sides.add(image.size)
        self.assertEqual(len(sides), 1)

    def test_every_building_is_a_closed_solid(self):
        faults = {}
        for tile in sorted((self.track / "tiles").glob("*.glb")):
            faults |= buildings.audit(tile)
        self.assertEqual(len(faults), len(default_track.BUILDINGS))
        self.assertEqual(set(faults.values()), {None})

    def test_the_track_map_puts_the_lap_on_its_centreline(self):
        sections = default_track.lap_sections()
        index = json.loads((self.track / "tiles.json").read_text())
        tile_m = index["tile_size_m"]
        for at in range(0, len(sections["s"]), 97):
            east, north = sections["x"][at], sections["y"][at]
            entry = next(
                entry
                for entry in index["tiles"]
                if 0 <= -north - entry["corner_m"][0] < tile_m
                and 0 <= east - entry["corner_m"][1] < tile_m
            )
            with Image.open(self.track / "tiles" / f"{entry['key']}.track.png") as image:
                pixels = np.asarray(image)
            row = int((-north - entry["corner_m"][0]) / track_surfaces.TRACK_MAP_M_PER_PX)
            column = int((east - entry["corner_m"][1]) / track_surfaces.TRACK_MAP_M_PER_PX)
            red, green, blue, alpha = (int(value) for value in pixels[row, column])
            along_m = ((red << 12) | (green << 4) | (blue >> 4)) * track_surfaces.ALONG_UNIT_M
            right_m = (((blue & 15) << 8 | alpha) - track_surfaces.RIGHT_ZERO) * 0.01
            length_m = default_track.lap_length_m(sections)
            off_m = (along_m - sections["s"][at] + length_m / 2.0) % length_m - length_m / 2.0
            self.assertLess(abs(off_m), 1.0)
            self.assertLess(abs(right_m), 0.6)

    def test_the_ground_is_the_roads_under_the_lap(self):
        index = json.loads((self.track / "tiles.json").read_text())
        step_m = index["ground_step_m"]
        sections = default_track.lap_sections()
        profile = default_track.road_profile_m(sections)
        side = round(index["tile_size_m"] / step_m) + 1
        for at in range(0, len(sections["s"]), 89):
            east, north = sections["x"][at], sections["y"][at]
            for entry in index["tiles"]:
                row = (-north - entry["corner_m"][0]) / step_m
                column = (east - entry["corner_m"][1]) / step_m
                if 0 <= row < side - 1 and 0 <= column < side - 1:
                    path = self.track / "tiles" / f"{entry['key']}.ground.f32"
                    heights = np.fromfile(path, "<f4").reshape(side, side)
                    height_m = smooth_terrain.sample_bilinear(
                        heights.astype(np.float64), np.array([row]), np.array([column])
                    )[0]
                    self.assertAlmostEqual(height_m, profile[at], delta=0.05)

    def test_no_tree_stands_on_the_lap_or_by_a_building(self):
        points = default_track.lap_points()
        trees = []
        for tile in (self.track / "tiles").glob("*.json"):
            standing = json.loads(tile.read_text())["trees"]
            trees += standing["conifer"] + standing["broadleaf"]
        self.assertGreater(len(trees), 300)
        for x, y, _, _ in trees:
            self.assertGreater(
                np.hypot(*(points - (y, -x)).T).min(), default_track.HALF_WIDTH_M + 8
            )

    def test_the_vehicle_model_has_a_body_and_a_wheel(self):
        model = self.out / default_vehicle.VEHICLE_ID / default_vehicle.MODEL
        gltf, _ = smooth_terrain.read_glb(model)
        self.assertEqual({node["name"] for node in gltf["nodes"]}, {"Body", "Wheel"})


class Lap(unittest.TestCase):
    """The default circuit's lap."""

    def test_is_closed_and_about_a_kilometre_and_a_half(self):
        sections = default_track.lap_sections()
        x, y = np.array(sections["x"]), np.array(sections["y"])
        steps = np.hypot(np.diff(np.append(x, x[0])), np.diff(np.append(y, y[0])))
        self.assertLess(steps.max(), 1.2)
        self.assertAlmostEqual(default_track.lap_length_m(sections), 1450.0, delta=100.0)

    def test_turns_once_round(self):
        curvature = track_surfaces.lap_curvature(default_track.lap_sections())
        self.assertAlmostEqual(-curvature.sum() * default_track.SECTION_M, math.tau, delta=0.05)

    def test_never_comes_near_itself(self):
        points = default_track.lap_points()[::4]
        count = len(points)
        apart = np.abs(np.arange(count)[:, None] - np.arange(count)[None, :])
        apart = np.minimum(apart, count - apart) * 4
        distances = np.hypot(*(points[:, None] - points[None, :]).transpose(2, 0, 1))
        self.assertGreater(distances[apart > 150].min(), 40.0)

    def test_corners_are_of_varied_radius(self):
        radii = sorted(part[2] for part in default_track.LAP if part[0] == "arc")
        self.assertLess(radii[0], 30.0)
        self.assertGreater(radii[-1], 100.0)

    def test_stays_on_flat_ground_away_from_the_rim(self):
        points = default_track.lap_points()
        to_edge = default_track.WORLD_M / 2.0 - np.abs(points).max()
        self.assertGreater(to_edge, default_track.RIM_WIDTH_M)


if __name__ == "__main__":
    unittest.main()
