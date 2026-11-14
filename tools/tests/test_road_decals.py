# ruff: noqa: D102
"""Tests of the road decals: braking marks, the photo's blots, tagged covers, the textures."""

import math
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import osm
import road_decals
import road_network
from PIL import Image


def oval(straight_m=400.0, radius_m=40.0, spacing_m=1.0):
    """Return the sections of a closed lap: two straights joined by two half circles, clockwise."""
    points = []
    for along in np.arange(0.0, straight_m, spacing_m):
        points.append((along, 0.0))
    for angle in np.arange(0.0, math.pi, spacing_m / radius_m):
        points.append(
            (straight_m + radius_m * math.sin(angle), -radius_m + radius_m * math.cos(angle))
        )
    for along in np.arange(straight_m, 0.0, -spacing_m):
        points.append((along, -2.0 * radius_m))
    for angle in np.arange(0.0, math.pi, spacing_m / radius_m):
        points.append((-radius_m * math.sin(angle), -radius_m - radius_m * math.cos(angle)))
    sections = road_network.sections_along(np.array(points))
    closing = np.hypot(*(np.array(points[0]) - np.array(points[-1])))
    assert closing < 2.0 * spacing_m
    return sections


class SpeedTest(unittest.TestCase):
    """Where a car brakes on a lap."""

    def setUp(self):
        self.sections = oval()
        curvature = road_decals.track_surfaces.lap_curvature(self.sections)
        self.speeds = road_decals.lap_speeds(curvature, 1.0)

    def test_a_corner_is_taken_as_fast_as_the_grip_allows(self):
        in_the_corner = self.speeds[420]

        self.assertAlmostEqual(
            in_the_corner, math.sqrt(road_decals.LATERAL_GRIP_M_S2 * 40.0), delta=1.5
        )

    def test_a_car_brakes_before_each_corner_and_not_after(self):
        zones = road_decals.braking_zones(self.speeds)

        self.assertEqual(len(zones), 2)
        first, last, drop = zones[0]
        # Braking ends where the corner tightens to its radius, the curvature read smoothed.
        self.assertLess(first, 380)
        self.assertGreater(last, 395)
        self.assertLess(last, 445)
        self.assertGreater(drop, road_decals.BRAKING_DROP_M_S)

    def test_a_gentle_slowing_is_no_braking_zone(self):
        speeds = np.concatenate([np.linspace(30.0, 25.0, 50), np.linspace(25.0, 30.0, 50)])

        self.assertEqual(road_decals.braking_zones(speeds), [])


class BrakingMarksTest(unittest.TestCase):
    """Tyre marks on the racing line where cars brake."""

    def setUp(self):
        self.sections = oval()
        count = len(self.sections["s"])
        self.zones = [(300, 395, 25.0)]
        self.clear = [np.full(count, 5.0), np.full(count, 5.0)]
        self.marks = road_decals.braking_marks(
            self.sections, self.zones, np.full(count, 1.0), self.clear
        )

    def test_marks_lie_on_the_racing_line_towards_the_end_of_the_zone(self):
        self.assertGreaterEqual(len(self.marks), 1)
        for mark in self.marks:
            self.assertEqual(mark.kind, "tyre_marks")
            self.assertGreater(mark.x, 300.0 + 0.3 * 95.0)
            self.assertLess(mark.x, 396.0)
            # The racing line is 1 m right of the centreline, which runs east along y = 0.
            self.assertAlmostEqual(mark.y, -1.0, delta=road_decals.MARK_SPREAD_M + 1e-6)

    def test_marks_run_along_the_road(self):
        for mark in self.marks:
            self.assertAlmostEqual(math.cos(mark.heading_rad), 1.0, places=3)

    def test_a_mark_moves_in_from_a_racing_line_near_the_edge(self):
        count = len(self.sections["s"])
        tight = [np.full(count, 5.0), np.full(count, 1.6)]

        marks = road_decals.braking_marks(self.sections, self.zones, np.full(count, 1.0), tight)

        self.assertGreaterEqual(len(marks), 1)
        for mark in marks:
            self.assertGreaterEqual(mark.y, -0.6 - 1e-6)

    def test_no_mark_reaches_beyond_the_clear_asphalt(self):
        count = len(self.sections["s"])
        narrow = [np.full(count, 0.9), np.full(count, 0.9)]

        marks = road_decals.braking_marks(self.sections, self.zones, np.full(count, 1.0), narrow)

        self.assertEqual(marks, [])


def flat_photo(count=200, width=113):
    """Return a lap's darkness, saturation and inside mask with no blot on it."""
    return np.zeros((count, width)), np.zeros((count, width)), np.ones((count, width), bool)


class BlotsTest(unittest.TestCase):
    """Dark ground on the asphalt, read from the photo."""

    def setUp(self):
        self.sections = oval()
        self.laterals = np.arange(-14.0, 14.125, 0.25)

    def decals_of(self, darkness, saturation, inside, shadowed=lambda x, y: False):
        found = road_decals.blots(darkness, saturation, inside)
        racing_offset_m = np.full(len(self.sections["s"]), 5.0)
        return road_decals.photo_decals(
            found, self.sections, self.laterals, racing_offset_m, shadowed
        )

    def test_a_small_blot_is_an_oil_stain(self):
        darkness, saturation, inside = flat_photo()
        darkness[100:102, 56:61] = 0.05

        (stain,) = self.decals_of(darkness, saturation, inside)

        self.assertEqual(stain.kind, "oil_stain")
        self.assertAlmostEqual(stain.x, 100.5, delta=1.0)
        self.assertAlmostEqual(stain.y, -0.5, delta=0.3)

    def test_a_long_narrow_streak_is_tyre_marks_along_it(self):
        darkness, saturation, inside = flat_photo()
        darkness[50:70, 60:64] = 0.04

        marks = self.decals_of(darkness, saturation, inside)

        self.assertEqual({mark.kind for mark in marks}, {"tyre_marks"})
        self.assertAlmostEqual(sum(mark.length_m for mark in marks), 20.0, delta=1.0)

    def test_a_wide_square_blot_is_patched_asphalt(self):
        darkness, saturation, inside = flat_photo()
        darkness[100:103, 50:62] = 0.05

        (patch,) = self.decals_of(darkness, saturation, inside)

        self.assertEqual(patch.kind, "patch")
        self.assertAlmostEqual(patch.width_m, 3.0, delta=0.01)

    def test_shadows_cars_and_the_asphalts_limit_leave_no_decal(self):
        cases = {"too dark": 0.12, "coloured": 0.05, "at the limit": 0.05, "shadowed": 0.05}
        for case, contrast in cases.items():
            darkness, saturation, inside = flat_photo()
            darkness[100:102, 56:61] = contrast
            if case == "coloured":
                saturation[100:102, 56:61] = 0.4
            if case == "at the limit":
                inside[:, :57] = False
            shadowed = (lambda x, y: True) if case == "shadowed" else (lambda x, y: False)

            self.assertEqual(self.decals_of(darkness, saturation, inside, shadowed), [], case)

    def test_a_faint_blot_or_one_by_a_shadow_paint_or_the_racing_line_is_no_stain(self):
        darkness, saturation, inside = flat_photo()
        darkness[100:102, 56:61] = 0.05
        darkness[104:106, 20:90] = 0.15
        self.assertEqual(self.decals_of(darkness, saturation, inside), [])

        darkness, saturation, inside = flat_photo()
        darkness[100:102, 74:78] = 0.05  # 5 m right of the centreline: the racing line
        self.assertEqual(self.decals_of(darkness, saturation, inside), [])

        darkness, saturation, inside = flat_photo()
        darkness[100:102, 56:61] = 0.05
        darkness[100:102, 62:66] = -0.1  # paint beside it
        self.assertEqual(self.decals_of(darkness, saturation, inside), [])

        darkness, saturation, inside = flat_photo()
        darkness[100:102, 56:61] = 0.032  # too faint for a stain
        self.assertEqual(self.decals_of(darkness, saturation, inside), [])

    def test_a_blot_across_the_start_of_the_lap_is_one(self):
        darkness, saturation, inside = flat_photo()
        darkness[-1:, 56:60] = 0.05
        darkness[:1, 56:60] = 0.05

        self.assertEqual(len(road_decals.blots(darkness, saturation, inside)), 1)

    def test_decals_of_one_kind_keep_apart(self):
        decals = [
            road_decals.Decal("oil_stain", 0.0, 0.0, 0.0, 1.0, 1.0, 0.5),
            road_decals.Decal("oil_stain", 5.0, 0.0, 0.0, 1.0, 1.0, 0.9),
            road_decals.Decal("patch", 5.0, 0.0, 0.0, 2.0, 2.0, 0.5),
        ]

        kept = road_decals.sparse(decals, 10.0)

        self.assertEqual(
            [(decal.kind, decal.x) for decal in kept], [("patch", 5.0), ("oil_stain", 5.0)]
        )


class ShadowTest(unittest.TestCase):
    """Where the photo's dark ground may be a shadow."""

    def test_ground_north_west_of_a_tree_is_in_its_shadow(self):
        shadowed = road_decals.shadowed_by([(0.0, 0.0, 10.0)], [])

        self.assertTrue(shadowed(-5.0, 5.0))
        self.assertFalse(shadowed(5.0, -5.0))
        self.assertFalse(shadowed(-20.0, 20.0))

    def test_ground_beside_a_building_may_be_in_its_shadow(self):
        square = np.array([(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)])
        shadowed = road_decals.shadowed_by(np.zeros((0, 3)), [square])

        self.assertTrue(shadowed(-5.0, 5.0))
        self.assertFalse(shadowed(-40.0, 5.0))


class CoverTest(unittest.TestCase):
    """Manholes and drains where the map tags them."""

    def setUp(self):
        sections = road_network.sections_along(np.stack([np.arange(101.0), np.zeros(101)], 1))
        count = len(sections["s"])
        self.road = road_decals.Carriageway(
            sections,
            np.full(count, 3.0),
            np.full(count, 3.0),
            [np.zeros(count), np.where(np.arange(count) < 50, 2.0, np.nan)],
        )

    def node(self, tags, x, y):
        return osm.Node("1", tags, np.array([x, y]))

    def test_a_tagged_manhole_on_a_road_is_a_cover_turned_along_it(self):
        (cover,) = road_decals.tagged_covers(
            [self.node({"man_made": "manhole"}, 70.0, -1.0)], [self.road]
        )

        self.assertEqual((cover.kind, cover.x, cover.y), ("manhole", 70.0, -1.0))
        self.assertAlmostEqual(cover.heading_rad, 0.0)

    def test_a_storm_drain_is_a_drain(self):
        (cover,) = road_decals.tagged_covers(
            [self.node({"manhole": "drain"}, 70.0, 2.8)], [self.road]
        )

        self.assertEqual(cover.kind, "drain")

    def test_a_cover_is_not_placed_off_the_road_or_on_its_paint(self):
        nodes = [
            self.node({"man_made": "manhole"}, 70.0, -8.0),
            self.node({"man_made": "manhole"}, 70.0, 0.2),
            self.node({"man_made": "manhole"}, 20.0, -2.0),
            self.node({"highway": "crossing"}, 70.0, -1.0),
        ]

        self.assertEqual(road_decals.tagged_covers(nodes, [self.road]), [])


class PackTest(unittest.TestCase):
    """Decals as the pack lists and draws them."""

    def test_a_decal_is_listed_in_the_packs_frame(self):
        decal = road_decals.Decal("patch", 10.0, 20.0, math.radians(90.0), 3.0, 2.0, 0.555)

        (listed,) = road_decals.described([decal], lambda x, y: x + y)

        # The pack's x is south and its y east: heading north is yaw 180.
        self.assertEqual(
            listed,
            {
                "kind": "patch",
                "position_m": [-20.0, 10.0, 30.0],
                "yaw_deg": -180.0,
                "size_m": [3.0, 2.0],
                "opacity": 0.56,
            },
        )

    def test_every_kind_is_drawn_without_a_visible_border(self):
        for kind in road_decals.KINDS:
            albedo, normal, orm = road_decals.draw(kind)
            pixels = np.asarray(albedo)

            self.assertEqual(albedo.size, road_decals.TEXTURE_PX[kind], kind)
            self.assertEqual(normal.size, albedo.size)
            self.assertEqual(orm.size, albedo.size)
            self.assertEqual(pixels[0, :, 3].max(), 0, kind)
            self.assertEqual(pixels[:, -1, 3].max(), 0, kind)
            self.assertGreater(pixels[..., 3].max(), 100, kind)

    def test_the_textures_of_the_kinds_placed_are_written(self):
        with tempfile.TemporaryDirectory() as directory:
            road_decals.write_textures(Path(directory) / "decals", ["oil_stain"])

            written = sorted(path.name for path in (Path(directory) / "decals").iterdir())
            with Image.open(Path(directory) / "decals" / "oil_stain_albedo.png") as albedo:
                mode = albedo.mode

        self.assertEqual(
            written, ["oil_stain_albedo.png", "oil_stain_normal.png", "oil_stain_orm.png"]
        )
        self.assertEqual(mode, "RGBA")
        self.assertEqual(
            road_decals.manifest(["oil_stain"], "decals"),
            {
                "kinds": [{"id": "oil_stain", "textures": "decals/oil_stain"}],
                "draw_distance_m": 120.0,
            },
        )


if __name__ == "__main__":
    unittest.main()
