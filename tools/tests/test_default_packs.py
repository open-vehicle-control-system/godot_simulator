# ruff: noqa: D102
"""Tests of the default track and vehicle packs.

The vehicle's are checked only when its source model is in build/sedan_src (see
default_car_model.py); without it they are skipped with a message saying so.
"""

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
import default_car_model
import default_packs
import default_track
import default_vehicle
import hdr_sky
import smooth_terrain
import track_surfaces
import tree_impostors

SCRATCH = default_packs.REPOSITORY / "build" / "test_default_packs"
NO_CAR_SOURCE = (
    f"{default_car_model.SOURCE} is missing: download the source model there to check "
    f"{default_vehicle.VEHICLE_ID} ({default_car_model.SOURCE_URL})"
)
CAR_SOURCE_PRESENT = default_car_model.SOURCE.exists()


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

    def test_the_committed_track_is_the_builders(self):
        self.assert_committed_as_built(default_track.TRACK_ID)

    @unittest.skipUnless(CAR_SOURCE_PRESENT, NO_CAR_SOURCE)
    def test_the_committed_vehicle_is_the_builders(self):
        self.assert_committed_as_built(default_vehicle.VEHICLE_ID)

    def assert_committed_as_built(self, pack_id):
        committed = file_hashes(default_packs.OUT / pack_id)
        built = file_hashes(self.out / pack_id)
        for path, digest in built.items():
            self.assertEqual(committed.get(path), digest, path)
        compressed = {
            str(job[2].relative_to(self.out / pack_id))
            for job in self.jobs
            if job[2].is_relative_to(self.out / pack_id)
        }
        self.assertEqual(set(committed) - set(built), compressed)

    def test_the_track_has_its_centre_line_as_a_closed_route(self):
        route = json.loads((self.track / self.manifest["track"]["route"]).read_text())
        points = np.array(route["points_m"])
        steps = np.hypot(*np.diff(np.vstack([points, points[:1]])[:, :2], axis=0).T)
        self.assertTrue(route["closed"])
        self.assertAlmostEqual(
            steps.sum(), default_track.lap_length_m(default_track.lap_sections()), delta=2.0
        )
        self.assertLess(steps.max(), default_track.ROUTE_STEP_M * 1.5)
        spawn = self.manifest["track"]["spawn"]["position_m"]
        self.assertLess(np.hypot(*(points[:, :2] - spawn[:2]).T).min(), 1.5, "the spawn is on it")

    def test_the_track_is_cc0_with_a_licence(self):
        manifest = json.loads((self.track / "pack.json").read_text())
        self.assertEqual(manifest["format"], 1)
        self.assertEqual(manifest["id"], default_track.TRACK_ID)
        self.assertEqual(manifest["licence"], "CC0-1.0")
        self.assertIn("CC0", (self.track / "LICENCE.txt").read_text())

    @unittest.skipUnless(CAR_SOURCE_PRESENT, NO_CAR_SOURCE)
    def test_the_vehicle_credits_its_model_as_cc_by_asks(self):
        vehicle = self.out / default_vehicle.VEHICLE_ID
        manifest = json.loads((vehicle / "pack.json").read_text())
        self.assertEqual(manifest["licence"], "CC-BY-4.0")
        for text in (
            manifest["attribution"][0],
            (vehicle / "LICENCE.txt").read_text(),
            (vehicle / "ATTRIBUTION.md").read_text(),
        ):
            for credit in ("Generic Sedan Car", "Márcio Meireles", "MMC Works", "Modified"):
                self.assertIn(credit, text)
            self.assertIn(default_car_model.SOURCE_URL, text)
            self.assertIn("CC BY 4.0", text)

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

    def test_the_sky_is_poly_havens_at_2k_with_the_sun_where_its_is(self):
        track = self.manifest["track"]
        sky = hdr_sky.read(self.track / track["sky"])

        self.assertEqual(sky.shape[:2], (1024, 2048))
        self.assertAlmostEqual(
            track["sun"]["elevation_deg"], hdr_sky.sun_elevation_deg(sky), delta=0.05
        )
        self.assertIn(default_track.SKY_CREDIT, self.manifest["attribution"])

    def test_the_trees_are_poly_havens_impostors_credited(self):
        impostors = self.manifest["track"]["trees"]["impostors"]

        self.assertEqual(
            {impostor["atlas"] for impostor in impostors},
            {f"trees/{variant}.dds" for variant in tree_impostors.VARIANTS},
        )
        self.assertEqual({impostor["kind"] for impostor in impostors}, {"conifer", "broadleaf"})
        self.assertIn(tree_impostors.CREDIT, self.manifest["attribution"])

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

    @unittest.skipUnless(CAR_SOURCE_PRESENT, NO_CAR_SOURCE)
    def test_the_vehicle_model_has_a_body_a_wheel_and_a_steering_wheel(self):
        model = self.out / default_vehicle.VEHICLE_ID / default_vehicle.MODEL
        gltf, _ = smooth_terrain.read_glb(model)
        self.assertEqual(
            {node["name"] for node in gltf["nodes"]}, {"Body", "Wheel", "Cockpit_Steer"}
        )
        self.assertIn("Mirror", {material["name"] for material in gltf["materials"]})

    @unittest.skipUnless(CAR_SOURCE_PRESENT, NO_CAR_SOURCE)
    def test_the_wheel_is_centred_on_its_axle_as_the_manifest_measures(self):
        vehicle = self.out / default_vehicle.VEHICLE_ID
        manifest = json.loads((vehicle / "pack.json").read_text())["vehicle"]
        gltf, _ = smooth_terrain.read_glb(vehicle / default_vehicle.MODEL)
        wheel = next(mesh for mesh in gltf["meshes"] if mesh["name"] == "Wheel")
        accessors = [
            gltf["accessors"][part["attributes"]["POSITION"]] for part in wheel["primitives"]
        ]
        low = np.min([accessor["min"] for accessor in accessors], 0)
        high = np.max([accessor["max"] for accessor in accessors], 0)
        self.assertAlmostEqual((high[1] + low[1]) / 2.0, 0.0, delta=0.005)
        self.assertAlmostEqual((high[2] + low[2]) / 2.0, 0.0, delta=0.005)
        self.assertAlmostEqual(high[1], manifest["wheel_radius_m"], delta=0.005)
        rim = next(
            gltf["accessors"][part["attributes"]["POSITION"]]
            for part in wheel["primitives"]
            if gltf["materials"][part["material"]]["name"].startswith("MetalStainless")
        )
        self.assertGreater(rim["min"][0] + rim["max"][0], 0.0, "the rim faces out, towards +X")

    @unittest.skipUnless(CAR_SOURCE_PRESENT, NO_CAR_SOURCE)
    def test_the_vehicle_pack_is_small(self):
        vehicle = self.out / default_vehicle.VEHICLE_ID
        size = sum(path.stat().st_size for path in vehicle.rglob("*") if path.is_file())
        self.assertLess(size, 10_000_000)


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
